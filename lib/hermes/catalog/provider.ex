defmodule Hermes.Catalog.Provider do
  @moduledoc """
  Ecto schema for a custom or overridden provider in the model/provider
  catalog.

  A provider names an LLM backend and the transport `kind` used to talk to it
  (`"openai"`, `"anthropic"`, or `"mock"`). For OpenAI-compatible endpoints,
  `base_url` points at the API root (e.g. a custom or self-hosted endpoint) and
  the credential is resolved at call time from either the stored `api_key` or
  the named `api_key_env` environment variable.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds ~w(openai anthropic mock)

  @primary_key {:name, :string, autogenerate: false}
  schema "providers" do
    field :label, :string
    field :kind, :string, default: "openai"
    field :base_url, :string
    field :api_key, :string
    field :api_key_env, :string
    field :is_default, :integer, default: 0

    timestamps()
  end

  @castable [:name, :label, :kind, :base_url, :api_key, :api_key_env, :is_default]

  @doc """
  Builds a changeset for a provider.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @castable)
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name, :kind])
    |> validate_inclusion(:kind, @kinds)
  end

  @doc "Returns the list of valid transport kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  defp normalize_name(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp normalize_name(other), do: other
end
