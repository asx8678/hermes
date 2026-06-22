defmodule Hermes.Catalog do
  @moduledoc """
  The model & provider catalog — the backing store for the `/providers` and
  `/model` managers.

  Two layers are merged:

    * **Built-ins** — defined in code (`builtin_providers/0`, `builtin_models/0`).
      Always present, so provider/model resolution works on a fresh database and
      in tests without any seeding.
    * **Custom rows** — stored in the `providers` / `models` tables. Users add
      these via `/providers add` and `/model add`. A custom row whose name
      matches a built-in overrides it.

  Resolution (`resolve_provider/1`, `resolve_model/2`) prefers a DB row, then
  falls back to the built-in. Listing merges both.

  A provider's transport `kind` selects the module:

      "openai"    -> Hermes.Providers.OpenAI      (any OpenAI-compatible endpoint)
      "anthropic" -> Hermes.Providers.Anthropic
      "mock"      -> Hermes.Providers.Mock
  """

  import Ecto.Query, only: [from: 2]

  alias Hermes.Catalog.Model
  alias Hermes.Catalog.Provider
  alias Hermes.Repo

  @type provider_map :: %{
          name: String.t(),
          label: String.t(),
          kind: String.t(),
          base_url: String.t() | nil,
          api_key_env: String.t() | nil,
          has_stored_key: boolean(),
          is_default: boolean(),
          builtin: boolean()
        }

  @type resolved_provider :: %{
          name: String.t(),
          kind: String.t(),
          module: module(),
          base_url: String.t() | nil,
          api_key: String.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Built-in catalog (code-defined; always available)
  # ---------------------------------------------------------------------------

  @builtin_providers [
    %{
      name: "makora",
      label: "Makora",
      kind: "openai",
      base_url: "https://inference.makora.com/v1",
      api_key_env: "MAKORA_OPTIMIZE_TOKEN",
      is_default: 1
    },
    %{
      name: "openai",
      label: "OpenAI",
      kind: "openai",
      base_url: "https://api.openai.com/v1",
      api_key_env: "OPENAI_API_KEY",
      is_default: 0
    },
    %{
      name: "anthropic",
      label: "Anthropic",
      kind: "anthropic",
      base_url: nil,
      api_key_env: "ANTHROPIC_API_KEY",
      is_default: 0
    },
    %{
      name: "mock",
      label: "Mock (offline)",
      kind: "mock",
      base_url: nil,
      api_key_env: nil,
      is_default: 0
    }
  ]

  # Context-window / max-output figures are reasonable defaults and are fully
  # user-editable via `/model add` (which upserts an override row).
  @builtin_models [
    %{
      provider_name: "makora",
      model_id: "moonshotai/Kimi-K2.7-Code",
      label: "Kimi K2.7 Code",
      context_window: 262_144,
      max_output_tokens: 16_384,
      supports_tools: 1,
      supports_reasoning: 0,
      is_default: 1
    },
    %{
      provider_name: "makora",
      model_id: "zai-org/GLM-5.2-FP8",
      label: "GLM-5.2",
      context_window: 131_072,
      max_output_tokens: 16_384,
      supports_tools: 1,
      supports_reasoning: 1,
      is_default: 0
    },
    %{
      provider_name: "openai",
      model_id: "gpt-4o",
      label: "GPT-4o",
      context_window: 128_000,
      max_output_tokens: 16_384,
      supports_tools: 1,
      supports_reasoning: 0,
      is_default: 1
    },
    %{
      provider_name: "anthropic",
      model_id: "claude-sonnet-4-20250514",
      label: "Claude Sonnet 4",
      context_window: 200_000,
      max_output_tokens: 64_000,
      supports_tools: 1,
      supports_reasoning: 1,
      is_default: 1
    },
    %{
      provider_name: "mock",
      model_id: "mock",
      label: "Mock",
      context_window: 8_192,
      max_output_tokens: 4_096,
      supports_tools: 1,
      supports_reasoning: 0,
      is_default: 1
    }
  ]

  @spec builtin_providers() :: [map()]
  def builtin_providers, do: @builtin_providers

  @spec builtin_models() :: [map()]
  def builtin_models, do: @builtin_models

  @spec module_for_kind(String.t()) :: module()
  def module_for_kind("anthropic"), do: Hermes.Providers.Anthropic
  def module_for_kind("mock"), do: Hermes.Providers.Mock
  def module_for_kind(_), do: Hermes.Providers.OpenAI

  # ---------------------------------------------------------------------------
  # Providers
  # ---------------------------------------------------------------------------

  @doc """
  Lists all providers (built-ins merged with custom/override rows), sorted by
  name. Each entry is a display-friendly `provider_map/0`.
  """
  @spec list_providers() :: [provider_map()]
  def list_providers do
    db = Map.new(safe_all(Provider), &{&1.name, provider_row_to_map(&1)})
    builtins = Map.new(@builtin_providers, &{&1.name, builtin_provider_to_map(&1)})

    builtins
    |> Map.merge(db, fn _name, _builtin, custom -> %{custom | builtin: true} end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Resolves a provider name to the concrete `module`, `base_url`, and `api_key`
  the runtime needs. DB row wins over built-in. Returns `nil` if unknown.
  """
  @spec resolve_provider(String.t() | atom() | nil) :: resolved_provider() | nil
  def resolve_provider(nil), do: nil
  def resolve_provider(name) when is_atom(name), do: resolve_provider(Atom.to_string(name))

  def resolve_provider(name) when is_binary(name) do
    name = name |> String.trim() |> String.downcase()

    raw =
      case safe_get(Provider, name) do
        %Provider{} = p ->
          %{kind: p.kind, base_url: p.base_url, api_key: p.api_key, api_key_env: p.api_key_env}

        nil ->
          Enum.find(@builtin_providers, &(&1.name == name))
      end

    case raw do
      nil ->
        nil

      p ->
        %{
          name: name,
          kind: p.kind,
          module: module_for_kind(p.kind),
          base_url: Map.get(p, :base_url),
          api_key: resolve_api_key(p)
        }
    end
  end

  @doc """
  Inserts or updates a custom provider. `attrs` may use string or atom keys and
  must include `name` and `kind`.
  """
  @spec upsert_provider(map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def upsert_provider(attrs) do
    attrs = stringify_keys(attrs)
    name = attrs["name"] |> to_string() |> String.trim() |> String.downcase()
    existing = safe_get(Provider, name) || %Provider{}

    existing
    |> Provider.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Deletes a custom provider row (and its custom models). Built-in providers
  cannot be removed — deleting a built-in name only drops any override.
  """
  @spec delete_provider(String.t()) :: :ok
  def delete_provider(name) when is_binary(name) do
    name = name |> String.trim() |> String.downcase()

    case safe_get(Provider, name) do
      %Provider{} = p ->
        Repo.delete(p)
        Repo.delete_all(from m in Model, where: m.provider_name == ^name)
        :ok

      nil ->
        :ok
    end
  end

  @doc "Returns the default provider name."
  @spec default_provider() :: String.t()
  def default_provider do
    case Enum.find(list_providers(), & &1.is_default) do
      %{name: name} -> name
      nil -> "makora"
    end
  end

  # ---------------------------------------------------------------------------
  # Models
  # ---------------------------------------------------------------------------

  @doc """
  Lists models, optionally filtered by `provider_name`. Built-ins merged with
  custom/override rows. Each entry is a display-friendly map.
  """
  @spec list_models(String.t() | nil) :: [map()]
  def list_models(provider_name \\ nil) do
    db = Map.new(safe_all(Model), &{{&1.provider_name, &1.model_id}, model_row_to_map(&1)})

    builtins =
      Map.new(@builtin_models, &{{&1.provider_name, &1.model_id}, builtin_model_to_map(&1)})

    builtins
    |> Map.merge(db, fn _k, _builtin, custom -> %{custom | builtin: true} end)
    |> Map.values()
    |> maybe_filter_provider(provider_name)
    |> Enum.sort_by(&{&1.provider_name, &1.model_id})
  end

  @doc """
  Resolves model metadata for `{provider_name, model_id}`. DB row wins over
  built-in. Returns `nil` if unknown (callers should treat the model id as a
  free-form passthrough with no metadata).
  """
  @spec resolve_model(String.t() | nil, String.t()) :: map() | nil
  def resolve_model(provider_name, model_id)
      when is_binary(provider_name) and is_binary(model_id) do
    case safe_get_by(Model, provider_name: provider_name, model_id: model_id) do
      %Model{} = m ->
        model_row_to_map(m)

      nil ->
        Enum.find_value(@builtin_models, fn b ->
          (b.provider_name == provider_name and b.model_id == model_id) && builtin_model_to_map(b)
        end)
    end
  end

  def resolve_model(_provider, _model), do: nil

  @doc "Inserts or updates a custom model. Requires `provider_name` and `model_id`."
  @spec upsert_model(map()) :: {:ok, Model.t()} | {:error, Ecto.Changeset.t()}
  def upsert_model(attrs) do
    attrs = stringify_keys(attrs)

    existing =
      safe_get_by(Model, provider_name: attrs["provider_name"], model_id: attrs["model_id"]) ||
        %Model{}

    existing
    |> Model.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Deletes a custom model row."
  @spec delete_model(String.t(), String.t()) :: :ok
  def delete_model(provider_name, model_id) do
    case safe_get_by(Model, provider_name: provider_name, model_id: model_id) do
      %Model{} = m -> Repo.delete(m) && :ok
      nil -> :ok
    end
  end

  @doc "Returns the default model id for a provider, if any."
  @spec default_model(String.t()) :: String.t() | nil
  def default_model(provider_name) when is_binary(provider_name) do
    models = list_models(provider_name)

    case Enum.find(models, & &1.is_default) || List.first(models) do
      %{model_id: id} -> id
      _ -> nil
    end
  end

  @doc """
  Returns the context window for `{provider_name, model_id}`, or `nil` if the
  model is unknown to the catalog.
  """
  @spec context_window(String.t() | nil, String.t()) :: pos_integer() | nil
  def context_window(provider_name, model_id) do
    case resolve_model(to_string(provider_name), model_id) do
      %{context_window: cw} -> cw
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_filter_provider(models, nil), do: models

  defp maybe_filter_provider(models, provider),
    do: Enum.filter(models, &(&1.provider_name == provider))

  defp resolve_api_key(%{api_key: key}) when is_binary(key) and key != "", do: key

  defp resolve_api_key(%{api_key_env: env}) when is_binary(env) and env != "",
    do: System.get_env(env)

  defp resolve_api_key(_), do: nil

  defp builtin_provider_to_map(b) do
    %{
      name: b.name,
      label: b.label,
      kind: b.kind,
      base_url: b.base_url,
      api_key_env: b.api_key_env,
      has_stored_key: false,
      is_default: b.is_default == 1,
      builtin: true
    }
  end

  defp provider_row_to_map(%Provider{} = p) do
    %{
      name: p.name,
      label: p.label || p.name,
      kind: p.kind,
      base_url: p.base_url,
      api_key_env: p.api_key_env,
      has_stored_key: is_binary(p.api_key) and p.api_key != "",
      is_default: p.is_default == 1,
      builtin: false
    }
  end

  defp builtin_model_to_map(b) do
    %{
      provider_name: b.provider_name,
      model_id: b.model_id,
      label: b.label,
      context_window: b.context_window,
      max_output_tokens: b.max_output_tokens,
      supports_tools: b.supports_tools == 1,
      supports_reasoning: b.supports_reasoning == 1,
      is_default: b.is_default == 1,
      builtin: true
    }
  end

  defp model_row_to_map(%Model{} = m) do
    %{
      provider_name: m.provider_name,
      model_id: m.model_id,
      label: m.label || m.model_id,
      context_window: m.context_window,
      max_output_tokens: m.max_output_tokens,
      supports_tools: m.supports_tools == 1,
      supports_reasoning: m.supports_reasoning == 1,
      is_default: m.is_default == 1,
      builtin: false
    }
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # The catalog must never crash a caller (channel/session) if the DB is
  # momentarily unavailable — fall back to built-ins only.
  defp safe_all(schema) do
    Repo.all(schema)
  rescue
    _ -> []
  end

  defp safe_get(schema, id) do
    Repo.get(schema, id)
  rescue
    _ -> nil
  end

  defp safe_get_by(schema, clauses) do
    Repo.get_by(schema, clauses)
  rescue
    _ -> nil
  end
end
