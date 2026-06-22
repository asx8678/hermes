defmodule HermesWeb.SessionLive.Index do
  @moduledoc """
  Minimal sessions/status dashboard.

  Per DECISIONS.md #liveview, the dashboard intentionally covers only active
  sessions and their current status. It is a peer to the Rust TUI on the same
  `Hermes.PubSub` topic (`"sessions"`).
  """

  use HermesWeb, :live_view

  alias Hermes.Sessions

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermes.PubSub, "sessions")
    end

    {:ok, assign(socket, :sessions, list_sessions())}
  end

  @impl true
  def handle_info({:session_started, session}, socket) do
    {:noreply, update(socket, :sessions, fn sessions -> [session | sessions] end)}
  end

  def handle_info({:session_status, session_id, status}, socket) do
    {:noreply,
     update(socket, :sessions, fn sessions ->
       Enum.map(sessions, fn s ->
         if s.id == session_id, do: %{s | status: status}, else: s
       end)
     end)}
  end

  def handle_info({:session_stopped, session_id}, socket) do
    {:noreply,
     update(socket, :sessions, fn sessions ->
       Enum.reject(sessions, fn s -> s.id == session_id end)
     end)}
  end

  defp list_sessions do
    Sessions.list_sessions()
  end
end
