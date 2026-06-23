defmodule HermesWeb.WebhooksLive do
  @moduledoc """
  Webhook configuration overview.

  `Hermes.Gateway.Webhook` does not expose a public list API, so this view
  reads the `:gateway` application config and the router's `forward "/webhooks"`
  route to display which connector names are configured to receive webhooks.
  """

  use HermesWeb, :live_view

  @webhook_path "/webhooks"

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, webhooks: load_webhooks())}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, webhooks: load_webhooks())}
  end

  def handle_event("copy_url", %{"url" => url}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Webhook URL copied: #{url}")
     |> assign(webhooks: load_webhooks())}
  end

  defp load_webhooks do
    gateway_config = Application.get_env(:hermes, :gateway, [])

    registered_names =
      Hermes.Gateway.Registry.list_connectors()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    configured =
      Keyword.get(gateway_config, :webhooks, [])
      |> Enum.map(fn
        name when is_atom(name) -> to_string(name)
        name when is_binary(name) -> name
      end)

    configured =
      if configured == [] do
        Enum.map(registered_names, &to_string/1)
      else
        configured
      end

    Enum.map(configured, fn name ->
      atom =
        try do
          String.to_existing_atom(name)
        rescue
          ArgumentError -> nil
        end

      %{
        name: name,
        url: "#{@webhook_path}/#{name}",
        registered: atom != nil and MapSet.member?(registered_names, atom)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end
end
