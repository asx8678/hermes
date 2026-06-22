defmodule Hermes.Gateway.Streaming do
  @moduledoc """
  Per-connector streaming strategy middleware.

  Ports the send-strategy surface from
  `../hermes-agent/gateway/platforms/base.py:2163-2247` (draft/edit support
  hooks) and `../hermes-agent/gateway/stream_consumer.py:79-1651` (progressive
  edit consumer). The module decides, per connector, whether outbound text
  should be streamed as live edits (`:edit`), native drafts (`:draft`), or
  buffered and sent only at turn completion (`:off`).

  State is kept per `{connector, session_id, chat_id}` so multiple sessions
  can stream concurrently without interference.

  Strategy table (mirrors Python adapter capabilities and project decisions):

    * `:edit`  – Telegram, Discord, Slack, Feishu
    * `:draft` – experimental / native-draft platforms
    * `:off`   – WhatsApp, Signal, Email
  """

  use GenServer

  alias Hermes.Gateway.Registry, as: GatewayRegistry

  @type strategy :: :edit | :draft | :off
  @default_throttle_ms 500

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns the streaming strategy for a connector.

  Strategy is looked up by connector name. Platforms that cannot edit messages
  in-place default to `:off` so the final answer is delivered as a single
  message at turn completion.
  """
  @spec strategy_for(connector :: atom()) :: strategy()
  def strategy_for(:telegram), do: :edit
  def strategy_for(:discord), do: :edit
  def strategy_for(:slack), do: :edit
  def strategy_for(:feishu), do: :edit
  def strategy_for(:whatsapp), do: :off
  def strategy_for(:signal), do: :off
  def strategy_for(:email), do: :off
  def strategy_for(_other), do: :off

  @doc """
  Returns true when enough time has elapsed since the last edit to send another
  delta, according to the configured throttle.
  """
  @spec should_send_delta?(strategy(), elapsed_ms :: non_neg_integer()) :: boolean()
  def should_send_delta?(_strategy, elapsed_ms) do
    elapsed_ms >= throttle_ms()
  end

  @doc """
  Starts the streaming manager.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Delivers a piece of outbound text using the connector's streaming strategy.

  * `:edit` – sends the first chunk as a new message, then progressively edits
    the same message with accumulated text (throttled).
  * `:draft` – sends or updates a draft preview.
  * `:off`  – silently accumulates text; nothing is sent until `finish/3` is
    called.

  The connector must be registered in `Hermes.Gateway.Registry`. Edits are
  attempted via the optional `{:edit_message, ...}` GenServer message; adapters
  that do not implement it will receive a fresh `{:send_message, ...}` instead.
  """
  @spec send_streaming(atom(), String.t(), String.t(), strategy(), term()) ::
          :ok | {:error, term()}
  def send_streaming(connector, session_id, text, strategy, chat_id) do
    GenServer.call(__MODULE__, {:send_streaming, connector, session_id, text, strategy, chat_id})
  end

  @doc """
  Finalises streaming for a session.

  For `:off` the buffered text is sent as a single message. For `:edit`/`:draft`
  any pending buffered text is flushed as a final edit. Session state is removed.
  """
  @spec finish(atom(), String.t(), term()) :: :ok | {:error, term()}
  def finish(connector, session_id, chat_id) do
    GenServer.call(__MODULE__, {:finish, connector, session_id, chat_id})
  end

  @doc """
  Returns the current streaming state for a session, or `nil`.

  Exposed for tests and diagnostics.
  """
  @spec session_state(atom(), String.t(), term()) :: map() | nil
  def session_state(connector, session_id, chat_id) do
    GenServer.call(__MODULE__, {:session_state, connector, session_id, chat_id})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:send_streaming, connector, session_id, text, strategy, chat_id}, _from, state) do
    key = {connector, session_id, chat_id}
    session = Map.get(state.sessions, key, fresh_session(strategy))
    new_session = accumulate(session, text)

    {reply, updated_state} =
      case strategy do
        :off ->
          {:ok, put_session(state, key, new_session)}

        :draft ->
          # Drafts are delivered through the same edit path as `:edit` in this
          # iteration. A future platform with native draft support can swap the
          # delivery primitive here.
          deliver_edit(connector, session_id, chat_id, new_session, state, key)

        :edit ->
          deliver_edit(connector, session_id, chat_id, new_session, state, key)
      end

    {:reply, reply, updated_state}
  end

  @impl true
  def handle_call({:finish, connector, session_id, chat_id}, _from, state) do
    key = {connector, session_id, chat_id}

    case Map.pop(state.sessions, key) do
      {nil, _state} ->
        {:reply, :ok, state}

      {session, new_state} ->
        result = flush_finish(connector, session_id, chat_id, session)
        {:reply, result, %{state | sessions: new_state}}
    end
  end

  @impl true
  def handle_call({:session_state, connector, session_id, chat_id}, _from, state) do
    {:reply, Map.get(state.sessions, {connector, session_id, chat_id}), state}
  end

  # ---------------------------------------------------------------------------
  # Delivery helpers
  # ---------------------------------------------------------------------------

  defp fresh_session(strategy) do
    %{
      strategy: strategy,
      text: "",
      buffer: "",
      message_id: nil,
      last_edit_time: nil,
      sent_initial: false
    }
  end

  defp accumulate(session, delta) do
    %{session | text: session.text <> delta, buffer: session.buffer <> delta}
  end

  defp put_session(state, key, session) do
    %{state | sessions: Map.put(state.sessions, key, session)}
  end

  defp deliver_edit(connector, session_id, chat_id, session, state, key) do
    now = System.monotonic_time(:millisecond)
    elapsed = if session.last_edit_time, do: now - session.last_edit_time, else: throttle_ms()

    cond do
      not session.sent_initial ->
        case send_to_connector(connector, session_id, session.text, chat_id) do
          {:ok, message_id} ->
            updated_session = %{
              session
              | sent_initial: true,
                message_id: message_id,
                last_edit_time: now,
                buffer: ""
            }

            {:ok, put_session(state, key, updated_session)}

          error ->
            {error, state}
        end

      should_send_delta?(:edit, elapsed) and session.message_id != nil and session.buffer != "" ->
        case edit_in_connector(connector, session_id, session.message_id, session.text, chat_id) do
          {:ok, _message_id} ->
            updated_session = %{session | last_edit_time: now, buffer: ""}
            {:ok, put_session(state, key, updated_session)}

          {:error, _reason} ->
            # Degrade to a fresh send if editing is unsupported or failed.
            case send_to_connector(connector, session_id, session.text, chat_id) do
              {:ok, message_id} ->
                updated_session = %{
                  session
                  | message_id: message_id,
                    last_edit_time: now,
                    buffer: ""
                }

                {:ok, put_session(state, key, updated_session)}

              error ->
                {error, state}
            end
        end

      true ->
        # Throttled – keep accumulating.
        {:ok, put_session(state, key, session)}
    end
  end

  defp flush_finish(_connector, _session_id, _chat_id, %{strategy: :off, text: ""}) do
    :ok
  end

  defp flush_finish(connector, session_id, chat_id, %{strategy: :off, text: text}) do
    case send_to_connector(connector, session_id, text, chat_id) do
      {:ok, _message_id} -> :ok
      error -> error
    end
  end

  defp flush_finish(connector, session_id, chat_id, %{
         strategy: strategy,
         buffer: buffer,
         message_id: message_id,
         text: text
       })
       when strategy in [:edit, :draft] do
    cond do
      buffer == "" or is_nil(message_id) ->
        :ok

      true ->
        case edit_in_connector(connector, session_id, message_id, text, chat_id) do
          {:ok, _message_id} -> :ok
          {:error, _reason} -> send_to_connector(connector, session_id, text, chat_id)
        end
    end
  end

  defp send_to_connector(connector, session_id, text, chat_id) do
    with {:ok, pid} <- resolve_connector(connector) do
      case GenServer.call(pid, {:send_message, session_id, text, [chat_id: chat_id]}) do
        {:ok, %{"result" => %{"message_id" => message_id}}} ->
          {:ok, to_string(message_id)}

        {:ok, %{"message_id" => message_id}} ->
          {:ok, to_string(message_id)}

        {:ok, result} when is_binary(result) or is_integer(result) ->
          {:ok, to_string(result)}

        {:ok, _} ->
          {:ok, nil}

        error ->
          error
      end
    end
  end

  defp edit_in_connector(connector, session_id, message_id, text, chat_id) do
    with {:ok, pid} <- resolve_connector(connector) do
      request = {:edit_message, session_id, message_id, text, [chat_id: chat_id]}

      case GenServer.call(pid, request) do
        {:ok, %{"result" => %{"message_id" => edited_id}}} ->
          {:ok, to_string(edited_id)}

        {:ok, %{"message_id" => edited_id}} ->
          {:ok, to_string(edited_id)}

        {:ok, result} when is_binary(result) or is_integer(result) ->
          {:ok, to_string(result)}

        {:ok, _} ->
          {:ok, message_id}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, other}
      end
    end
  end

  defp resolve_connector(connector) when is_atom(connector) do
    case GatewayRegistry.whereis(connector) do
      nil -> {:error, :not_running}
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defp resolve_connector(pid) when is_pid(pid), do: {:ok, pid}

  defp throttle_ms do
    Application.get_env(:hermes, :gateway, [])
    |> Keyword.get(:streaming_throttle_ms, @default_throttle_ms)
  end
end
