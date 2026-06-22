defmodule HermesWeb.SessionChannel do
  @moduledoc """
  Phoenix Channel boundary for a single conversation session.

  Ports the handler semantics of `tui_gateway/server.py:898` from the
  Python TUI gateway's JSON-RPC methods to Phoenix Channel events over a
  localhost WebSocket:

    * `session:create`   → start a new supervised session
    * `session:resume`   → (Milestone A) subscribe to an existing session topic
    * `send_prompt`      → append a user message and start an async turn
    * `approval:respond` → (deferred) respond to a tool approval request
    * `slash:exec`       → (deferred) execute a slash command

  The channel is intentionally thin.  All conversation state and turn logic
  lives in `Hermes.Sessions.SessionServer` and `Hermes.Sessions.TurnLoop`.
  Events produced during a turn are broadcast on the session's PubSub topic
  (`session:<id>`); this channel subscribes on join and forwards them to the
  WebSocket client.
  """

  use HermesWeb, :channel

  alias Hermes.Sessions.SessionServer

  @impl true
  def join("session:new", _payload, socket) do
    {:ok, socket}
  end

  def join("session:" <> session_id, _payload, socket) when session_id != "" do
    Phoenix.PubSub.subscribe(Hermes.PubSub, "session:#{session_id}")
    {:ok, assign(socket, :session_id, session_id)}
  end

  def join("session:" <> _empty, _payload, _socket) do
    {:error, %{reason: "invalid session_id"}}
  end

  @impl true
  def handle_in("session:create", params, socket) do
    opts =
      [
        model: params["model"],
        provider: provider_from_params(params["provider"]),
        api_mode: params["api_mode"],
        max_iterations: parse_max_iterations(params["max_iterations"])
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Hermes.Sessions.start_session(opts) do
      {:ok, pid, session_id} ->
        # Move the channel's PubSub subscription to the real session topic.
        Phoenix.PubSub.unsubscribe(Hermes.PubSub, topic(socket))
        Phoenix.PubSub.subscribe(Hermes.PubSub, "session:#{session_id}")

        socket =
          socket
          |> assign(:session_id, session_id)
          |> assign(:session_pid, pid)

        {:reply, {:ok, %{session_id: session_id, pid: inspect(pid)}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("session:resume", %{"session_id" => session_id}, socket) do
    Phoenix.PubSub.unsubscribe(Hermes.PubSub, topic(socket))
    Phoenix.PubSub.subscribe(Hermes.PubSub, "session:#{session_id}")
    {:ok, assign(socket, :session_id, session_id)}
  end

  def handle_in("send_prompt", %{"message" => message}, socket) do
    session_id = socket.assigns.session_id

    case SessionServer.run_turn_async(session_id, message) do
      :ok ->
        {:reply, {:ok, %{status: "started"}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "session not found"}}, socket}
    end
  end

  def handle_in("send_prompt", _params, socket) do
    {:reply, {:error, %{reason: "missing message"}}, socket}
  end

  def handle_in("approval:respond", _payload, socket) do
    {:reply, {:error, %{reason: "not implemented"}}, socket}
  end

  def handle_in("slash:exec", _payload, socket) do
    {:reply, {:error, %{reason: "not implemented"}}, socket}
  end

  # ----------------------------------------------------------------------------
  # PubSub → WebSocket forwarding
  # ----------------------------------------------------------------------------

  @impl true
  def handle_info({:stream_delta, text}, socket) do
    push(socket, "stream:delta", %{text: text})
    {:noreply, socket}
  end

  def handle_info({:tool_start, payload}, socket) do
    push(socket, "tool:start", payload)
    {:noreply, socket}
  end

  def handle_info({:tool_result, payload}, socket) do
    push(socket, "tool:result", payload)
    {:noreply, socket}
  end

  def handle_info({:turn_complete, payload}, socket) do
    push(socket, "turn:complete", payload)
    {:noreply, socket}
  end

  def handle_info({:turn_error, payload}, socket) do
    push(socket, "turn:error", payload)
    {:noreply, socket}
  end

  def handle_info({:session_status, payload}, socket) do
    push(socket, "session:status", payload)
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp topic(socket) do
    socket.topic
  end

  defp provider_from_params("anthropic"), do: Hermes.Providers.Anthropic
  defp provider_from_params("mock"), do: Hermes.Providers.Mock
  defp provider_from_params(_), do: Hermes.Providers.Anthropic

  defp parse_max_iterations(nil), do: nil
  defp parse_max_iterations(n) when is_integer(n), do: n

  defp parse_max_iterations(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
