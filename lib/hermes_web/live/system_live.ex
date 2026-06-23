defmodule HermesWeb.SystemLive do
  @moduledoc """
  LiveView for displaying BEAM system stats with optional polling.
  """

  use HermesWeb, :live_view

  @tick_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:paused, false)
      |> assign(:start_time, System.monotonic_time(:millisecond))
      |> refresh_stats()

    if connected?(socket) and not socket.assigns.paused do
      schedule_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("pause", _params, socket) do
    {:noreply, assign(socket, :paused, true)}
  end

  def handle_event("resume", _params, socket) do
    socket = assign(socket, :paused, false)
    if connected?(socket), do: schedule_tick()
    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    socket = refresh_stats(socket)

    if connected?(socket) and not socket.assigns.paused do
      schedule_tick()
    end

    {:noreply, socket}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval)
  end

  defp refresh_stats(socket) do
    memory = :erlang.memory()
    processes = Process.list()
    process_count = length(processes)

    total_reductions =
      processes
      |> Enum.map(fn pid ->
        case Process.info(pid, :reductions) do
          {:reductions, n} -> n
          _ -> 0
        end
      end)
      |> Enum.sum()

    uptime_ms = System.monotonic_time(:millisecond) - socket.assigns.start_time

    stats = %{
      memory_total_kb: div(Keyword.get(memory, :total, 0), 1024),
      memory_processes_kb: div(Keyword.get(memory, :processes_used, 0), 1024),
      memory_binary_kb: div(Keyword.get(memory, :binary, 0), 1024),
      memory_ets_kb: div(Keyword.get(memory, :ets, 0), 1024),
      process_count: process_count,
      scheduler_count: System.schedulers_online(),
      uptime_ms: uptime_ms,
      reductions: total_reductions
    }

    assign(socket, :stats, stats)
  end
end
