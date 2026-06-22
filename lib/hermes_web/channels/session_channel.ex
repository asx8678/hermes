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
        # Pass the provider NAME through; the session resolves it (module,
        # base_url, api_key) via Hermes.Catalog, which knows built-ins + customs.
        provider: params["provider"],
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

  # --- Model / provider manager (/model, /providers) ------------------------

  def handle_in("session:config", params, socket) do
    case socket.assigns[:session_id] do
      nil ->
        {:reply, {:error, %{reason: "no active session"}}, socket}

      session_id ->
        case SessionServer.set_config(session_id, params) do
          {:ok, config} -> {:reply, {:ok, config}, socket}
          {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
        end
    end
  end

  def handle_in("session:list", _params, socket) do
    push(socket, "sessions:listed", %{sessions: Hermes.Sessions.list_all()})
    {:reply, {:ok, %{}}, socket}
  end

  def handle_in("providers:list", _params, socket) do
    push_providers(socket)
    {:reply, {:ok, %{}}, socket}
  end

  def handle_in("providers:add", params, socket) do
    case Hermes.Catalog.upsert_provider(params) do
      {:ok, _provider} ->
        push_providers(socket)
        {:reply, {:ok, %{name: params["name"]}}, socket}

      {:error, changeset} ->
        {:reply, {:error, %{reason: changeset_errors(changeset)}}, socket}
    end
  end

  def handle_in("providers:remove", %{"name" => name}, socket) do
    Hermes.Catalog.delete_provider(name)
    push_providers(socket)
    {:reply, {:ok, %{}}, socket}
  end

  def handle_in("models:list", params, socket) do
    push_models(socket, params["provider"])
    {:reply, {:ok, %{}}, socket}
  end

  def handle_in("models:add", params, socket) do
    case Hermes.Catalog.upsert_model(params) do
      {:ok, _model} ->
        push_models(socket, params["provider_name"])
        {:reply, {:ok, %{}}, socket}

      {:error, changeset} ->
        {:reply, {:error, %{reason: changeset_errors(changeset)}}, socket}
    end
  end

  def handle_in("models:remove", %{"provider_name" => provider, "model_id" => model_id}, socket) do
    Hermes.Catalog.delete_model(provider, model_id)
    push_models(socket, provider)
    {:reply, {:ok, %{}}, socket}
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

  def handle_info({:session_config, payload}, socket) do
    push(socket, "session:config", payload)
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

  defp push_providers(socket) do
    push(socket, "providers:listed", %{providers: Hermes.Catalog.list_providers()})
  end

  defp push_models(socket, provider) do
    push(socket, "models:listed", %{
      provider: provider,
      models: Hermes.Catalog.list_models(provider)
    })
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errs} -> "#{field} #{Enum.join(errs, ", ")}" end)
  end

  defp parse_max_iterations(nil), do: nil
  defp parse_max_iterations(n) when is_integer(n), do: n

  defp parse_max_iterations(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
