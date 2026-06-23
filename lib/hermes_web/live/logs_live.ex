defmodule HermesWeb.LogsLive do
  @moduledoc """
  LiveView that captures recent telemetry events into a circular buffer.
  """

  use HermesWeb, :live_view

  @max_entries 100
  @telemetry_events [
    [:phoenix, :endpoint, :stop],
    [:phoenix, :router_dispatch, :stop],
    [:hermes, :session, :turn],
    [:hermes, :tool, :invoke],
    [:hermes, :curator, :background_review, :completed],
    [:hermes, :curator, :consolidation, :completed],
    [:hermes, :skill, :view],
    [:hermes, :skill, :use]
  ]
  @handler_id __MODULE__

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :telemetry.attach_many(
        @handler_id,
        @telemetry_events,
        &__MODULE__.handle_telemetry_event/4,
        %{pid: self()}
      )
    end

    socket =
      socket
      |> assign(:logs, [])
      |> assign(:paused, false)
      |> assign(:filter, "")

    {:ok, socket}
  end

  @impl true
  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, :logs, [])}
  end

  def handle_event("pause", _params, socket) do
    {:noreply, assign(socket, :paused, true)}
  end

  def handle_event("resume", _params, socket) do
    {:noreply, assign(socket, :paused, false)}
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  def handle_event("filter", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:telemetry_log, entry}, socket) do
    if socket.assigns.paused do
      {:noreply, socket}
    else
      logs =
        [entry | socket.assigns.logs]
        |> Enum.take(@max_entries)

      {:noreply, assign(socket, :logs, logs)}
    end
  end

  @impl true
  def terminate(_reason, _socket) do
    :telemetry.detach(@handler_id)
  end

  def handle_telemetry_event(event_name, measurements, metadata, %{pid: pid}) do
    entry = %{
      level: "info",
      event: Enum.join(Enum.map(event_name, &to_string/1), "."),
      message: inspect(measurements),
      metadata: inspect(metadata),
      timestamp: DateTime.utc_now()
    }

    send(pid, {:telemetry_log, entry})
  end

  def filtered_logs(logs, ""), do: logs

  def filtered_logs(logs, filter) do
    Enum.filter(logs, fn log ->
      String.contains?(log.event, filter) or
        String.contains?(log.message, filter) or
        String.contains?(log.metadata, filter)
    end)
  end
end
