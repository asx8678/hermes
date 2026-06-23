defmodule HermesWeb.ModelsLive do
  @moduledoc """
  LiveView for managing providers and models.
  """

  use HermesWeb, :live_view

  alias Hermes.Catalog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermes.PubSub, "catalog:providers")
      Phoenix.PubSub.subscribe(Hermes.PubSub, "catalog:models")
    end

    socket =
      socket
      |> assign(:providers, [])
      |> assign(:models, [])
      |> assign(:selected_provider, nil)
      |> assign(:error, nil)
      |> refresh_catalog()

    {:ok, socket}
  end

  @impl true
  def handle_event("select_provider", %{"name" => name}, socket) do
    {:noreply, assign(socket, :selected_provider, name)}
  end

  def handle_event("select_provider", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("add_provider", params, socket) do
    attrs = %{
      name: params["name"],
      label: params["label"] || params["name"],
      kind: params["kind"] || "openai",
      base_url: params["base_url"],
      api_key_env: params["api_key_env"]
    }

    case Catalog.upsert_provider(attrs) do
      {:ok, _provider} ->
        broadcast_providers()

        {:noreply,
         socket
         |> refresh_catalog()
         |> assign(:error, nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, :error, "add provider failed: #{format_errors(changeset)}")}
    end
  end

  def handle_event("remove_provider", %{"name" => name}, socket) do
    :ok = Catalog.delete_provider(name)
    broadcast_providers()

    {:noreply,
     socket
     |> assign(:selected_provider, nil)
     |> refresh_catalog()
     |> assign(:error, nil)}
  end

  def handle_event("add_model", params, socket) do
    attrs = %{
      provider_name: params["provider_name"],
      model_id: params["model_id"],
      label: params["label"] || params["model_id"],
      context_window: parse_int(params["context_window"], 128_000),
      max_output_tokens: parse_int(params["max_output_tokens"], 16_384),
      supports_tools: parse_bool(params["supports_tools"]),
      supports_reasoning: parse_bool(params["supports_reasoning"]),
      is_default: parse_bool(params["is_default"])
    }

    case Catalog.upsert_model(attrs) do
      {:ok, _model} ->
        broadcast_models()

        {:noreply,
         socket
         |> refresh_catalog()
         |> assign(:error, nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, :error, "add model failed: #{format_errors(changeset)}")}
    end
  end

  def handle_event("remove_model", %{"provider" => provider, "model" => model}, socket) do
    :ok = Catalog.delete_model(provider, model)
    broadcast_models()

    {:noreply,
     socket
     |> refresh_catalog()
     |> assign(:error, nil)}
  end

  @impl true
  def handle_info(%{event: "providers_updated"}, socket) do
    {:noreply, refresh_catalog(socket)}
  end

  def handle_info(%{event: "models_updated"}, socket) do
    {:noreply, refresh_catalog(socket)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp refresh_catalog(socket) do
    providers = Catalog.list_providers()
    models = Catalog.list_models(socket.assigns.selected_provider)

    assign(socket, :providers, providers)
    |> assign(:models, models)
  end

  defp broadcast_providers do
    Phoenix.PubSub.broadcast(Hermes.PubSub, "catalog:providers", %{event: "providers_updated"})
  end

  defp broadcast_models do
    Phoenix.PubSub.broadcast(Hermes.PubSub, "catalog:models", %{event: "models_updated"})
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default

  defp parse_bool(nil), do: false
  defp parse_bool("true"), do: true
  defp parse_bool("on"), do: true
  defp parse_bool(true), do: true
  defp parse_bool(_), do: false

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        "#{opts[String.to_existing_atom(key)]}"
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
