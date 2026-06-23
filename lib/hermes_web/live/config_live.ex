defmodule HermesWeb.ConfigLive do
  @moduledoc """
  Application configuration viewer and editor.

  Reads endpoint, gateway, and catalog defaults, and allows the operator to
  update the running provider, model, and gateway settings via
  `Application.put_env/3`.
  """

  use HermesWeb, :live_view

  alias Hermes.Catalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(config: build_config())
     |> assign(providers: Catalog.list_providers(), models: Catalog.list_models())}
  end

  @impl true
  def handle_event("update_provider", %{"config" => %{"provider" => provider}}, socket) do
    :ok = Application.put_env(:hermes, :default_provider, provider)
    {:noreply, assign(socket, config: build_config())}
  end

  def handle_event("update_model", %{"config" => %{"model" => model}}, socket) do
    :ok = Application.put_env(:hermes, :default_model, model)
    {:noreply, assign(socket, config: build_config())}
  end

  def handle_event(
        "update_gateway",
        %{
          "config" => %{
            "streaming_throttle_ms" => throttle,
            "approval_required" => approval
          }
        },
        socket
      ) do
    gateway_config = Application.get_env(:hermes, :gateway, [])

    new_config =
      gateway_config
      |> Keyword.put(:streaming_throttle_ms, String.to_integer(throttle))
      |> Keyword.put(:approval_required, parse_list(approval))

    :ok = Application.put_env(:hermes, :gateway, new_config)
    {:noreply, assign(socket, config: build_config())}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, config: build_config())}
  end

  defp build_config do
    endpoint_config = Application.get_env(:hermes, HermesWeb.Endpoint, [])
    gateway_config = Application.get_env(:hermes, :gateway, [])
    provider = Application.get_env(:hermes, :default_provider, Catalog.default_provider())
    model = Application.get_env(:hermes, :default_model, Catalog.default_model(provider))

    %{
      endpoint: endpoint_config,
      gateway: gateway_config,
      provider: provider,
      model: model,
      host: get_in(endpoint_config, [:url, :host]) || "localhost",
      port: get_in(endpoint_config, [:http, :port]) || 4000,
      streaming_throttle_ms: Keyword.get(gateway_config, :streaming_throttle_ms, 500),
      approval_required: Keyword.get(gateway_config, :approval_required, [])
    }
  end

  defp parse_list(text) when is_binary(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_atom/1)
  end

  defp parse_list(list) when is_list(list), do: list
  defp parse_list(_), do: []
end
