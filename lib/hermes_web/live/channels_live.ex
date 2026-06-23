defmodule HermesWeb.ChannelsLive do
  @moduledoc """
  Gateway connector status page.

  Lists all registered connectors from `Hermes.Gateway.Registry`, shows whether
  each is currently running, and exposes start/stop controls.
  """

  use HermesWeb, :live_view

  alias Hermes.Gateway.Registry

  @pubsub_topic "gateway"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermes.PubSub, @pubsub_topic)
    end

    {:ok, assign(socket, connectors: list_connectors())}
  end

  @impl true
  def handle_event("start", %{"name" => name}, socket) do
    atom_name = String.to_existing_atom(name)
    config = Application.get_env(:hermes, :gateway, [])

    case Registry.start_connector(atom_name, Map.new(config)) do
      {:ok, _pid} ->
        {:noreply, assign(socket, connectors: list_connectors())}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to start #{name}: #{inspect(reason)}")
         |> assign(connectors: list_connectors())}
    end
  end

  def handle_event("stop", %{"name" => name}, socket) do
    atom_name = String.to_existing_atom(name)

    case Registry.stop_connector(atom_name) do
      :ok ->
        {:noreply, assign(socket, connectors: list_connectors())}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to stop #{name}: #{inspect(reason)}")
         |> assign(connectors: list_connectors())}
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, connectors: list_connectors())}
  end

  @impl true
  def handle_info(%{event: "registry_changed"}, socket) do
    {:noreply, assign(socket, connectors: list_connectors())}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp list_connectors do
    Registry.list_connectors()
    |> Enum.map(fn entry ->
      %{
        name: entry.name,
        label: entry.label,
        module: entry.module,
        status: if(Registry.whereis(entry.name), do: :running, else: :stopped)
      }
    end)
    |> Enum.sort_by(& &1.label)
  end
end
