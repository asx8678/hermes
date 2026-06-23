defmodule HermesWeb.MCPLive do
  @moduledoc """
  LiveView for displaying configured MCP servers and clients.

  MCP is not yet implemented in the Elixir rewrite, so this view shows
  configured entries from the application environment and marks them as
  unconnected.
  """

  use HermesWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:servers, [])
      |> assign(:clients, [])
      |> refresh_mcp()

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, refresh_mcp(socket)}
  end

  def handle_event("toggle_servers", _params, socket) do
    {:noreply, assign(socket, :show_servers, not socket.assigns.show_servers)}
  end

  def handle_event("toggle_clients", _params, socket) do
    {:noreply, assign(socket, :show_clients, not socket.assigns.show_clients)}
  end

  defp refresh_mcp(socket) do
    servers =
      Application.get_env(:hermes, :mcp_servers, [])
      |> Enum.map(&normalize_endpoint/1)

    clients =
      Application.get_env(:hermes, :mcp_clients, [])
      |> Enum.map(&normalize_endpoint/1)

    assign(socket,
      servers: servers,
      clients: clients,
      show_servers: true,
      show_clients: true
    )
  end

  defp normalize_endpoint(%{name: name} = endpoint) when is_binary(name) do
    Map.merge(%{status: "configured", url: nil, transport: nil}, endpoint)
  end

  defp normalize_endpoint(%{name: name} = endpoint) when is_atom(name) do
    endpoint
    |> Map.put(:name, Atom.to_string(name))
    |> normalize_endpoint()
  end

  defp normalize_endpoint({name, opts}) do
    normalize_endpoint(%{
      name: to_string(name),
      transport: Keyword.get(opts, :transport),
      url: Keyword.get(opts, :url),
      status: "configured"
    })
  end

  defp normalize_endpoint(name) when is_binary(name) do
    %{name: name, status: "configured", url: nil, transport: nil}
  end

  defp normalize_endpoint(name) when is_atom(name) do
    %{name: Atom.to_string(name), status: "configured", url: nil, transport: nil}
  end

  defp normalize_endpoint(other) do
    %{name: inspect(other), status: "configured", url: nil, transport: nil}
  end
end
