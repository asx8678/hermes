defmodule HermesWeb.SessionLive.Index do
  @moduledoc """
  Sessions/status dashboard.

  Per DECISIONS.md #liveview, the dashboard is a peer to the Rust TUI on the same
  `Hermes.PubSub` topic (`"sessions"`). It lists active sessions and links to a
  detail view where a conversation can be continued.
  """

  use HermesWeb, :live_view

  alias Hermes.Sessions
  alias Hermes.Sessions.SessionServer

  @impl true
  def mount(_params, _session, socket) do
    sessions = list_sessions()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermes.PubSub, "sessions")
      subscribe_to_sessions(sessions)
    end

    {:ok, assign(socket, :sessions, sessions)}
  end

  @impl true
  def handle_event("new_session", _params, socket) do
    case Sessions.start_session(source: "dashboard") do
      {:ok, _pid, session_id} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Hermes.PubSub, "session:#{session_id}")
        end

        {:noreply, assign(socket, :sessions, list_sessions())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start session: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:session_started, session}, socket) do
    session = Map.merge(%{provider: nil}, session)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermes.PubSub, "session:#{session.id}")
    end

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

  def handle_info({:session_config, %{session_id: session_id, model: model, provider: provider}}, socket) do
    {:noreply,
     update(socket, :sessions, fn sessions ->
       Enum.map(sessions, fn s ->
         if s.id == session_id, do: %{s | model: model, provider: provider}, else: s
       end)
     end)}
  end

  def handle_info({:turn_complete, %{session_id: session_id}}, socket) do
    {:noreply, refresh_session(socket, session_id)}
  end

  def handle_info({:turn_error, %{session_id: session_id}}, socket) do
    {:noreply, refresh_session(socket, session_id)}
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

  defp subscribe_to_sessions(sessions) do
    Enum.each(sessions, fn session ->
      Phoenix.PubSub.subscribe(Hermes.PubSub, "session:#{session.id}")
    end)
  end

  defp refresh_session(socket, session_id) do
    update(socket, :sessions, fn sessions ->
      case live_session(session_id) do
        nil ->
          Enum.map(sessions, fn s ->
            if s.id == session_id, do: %{s | status: :idle}, else: s
          end)

        fresh ->
          case Enum.find_index(sessions, &(&1.id == session_id)) do
            nil -> [fresh | sessions]
            idx -> List.replace_at(sessions, idx, fresh)
          end
      end
    end)
  end

  defp live_session(session_id) do
    case SessionServer.whereis(session_id) do
      nil ->
        nil

      pid ->
        state = SessionServer.get_state(pid)

        %{
          id: state.session_id,
          model: state.model,
          provider: state.provider,
          status: state.status,
          message_count: length(state.messages)
        }
    end
  end
end
