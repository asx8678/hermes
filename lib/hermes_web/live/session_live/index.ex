defmodule HermesWeb.SessionLive.Index do
  @moduledoc """
  Sessions/status dashboard.

  Per DECISIONS.md #liveview, the dashboard is a peer to the Rust TUI on the same
  `Hermes.PubSub` topic (`"sessions"`). It lists active sessions and links to a
  detail view where a conversation can be continued.

  Each session row now carries richer metadata: message count, token usage,
  estimated cost, and start time. Live sessions are enriched from the running
  `SessionServer`; persisted-only sessions fall back to the stored row with
  safe defaults.
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
    session =
      Map.merge(
        %{provider: nil, token_count: 0, estimated_cost_usd: 0.0, started_at: nil},
        session
      )

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

  def handle_info(
        {:session_config, %{session_id: session_id, model: model, provider: provider}},
        socket
      ) do
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

  # NOTE: `:session_tokens` and `:session_cost` events are not currently emitted
  # by SessionServer, but these hooks are documented here for forward-compatible
  # enrichment when the turn loop reports usage/cost metrics.
  def handle_info({:session_tokens, session_id, token_count}, socket) do
    {:noreply,
     update(socket, :sessions, fn sessions ->
       Enum.map(sessions, fn s ->
         if s.id == session_id, do: %{s | token_count: token_count}, else: s
       end)
     end)}
  end

  def handle_info({:session_cost, session_id, cost}, socket) do
    {:noreply,
     update(socket, :sessions, fn sessions ->
       Enum.map(sessions, fn s ->
         if s.id == session_id, do: %{s | estimated_cost_usd: cost}, else: s
       end)
     end)}
  end

  defp list_sessions do
    Sessions.list_sessions()
    |> Enum.map(&enrich_session/1)
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
          message_count: length(state.messages),
          token_count: nil_fallback(Map.get(state, :token_count), 0),
          estimated_cost_usd: nil_fallback(Map.get(state, :estimated_cost_usd), 0.0),
          started_at: Map.get(state, :started_at, nil)
        }
    end
  end

  defp enrich_session(session) do
    live = live_session(session.id)

    case live do
      nil ->
        session
        |> Map.put_new(:status, :idle)
        |> Map.put_new(:provider, nil)
        |> Map.put_new(:token_count, nil_fallback(session.token_count, 0))
        |> Map.put_new(:estimated_cost_usd, nil_fallback(session.estimated_cost_usd, 0.0))

      _ ->
        Map.merge(
          session,
          %{
            status: live.status,
            provider: live.provider,
            token_count: live.token_count,
            estimated_cost_usd: live.estimated_cost_usd,
            started_at: live.started_at || Map.get(session, :started_at)
          }
        )
    end
  end

  defp nil_fallback(nil, default), do: default
  defp nil_fallback(value, _default), do: value

  defp format_started_at(nil), do: "—"

  defp format_started_at(timestamp) when is_number(timestamp) do
    DateTime.from_unix!(trunc(timestamp * 1000), :millisecond)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  defp format_started_at(value), do: to_string(value)
end
