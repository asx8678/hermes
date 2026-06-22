defmodule Hermes.Gateway.Connectors.Telegram do
  @moduledoc """
  Telegram gateway connector.

  Ports the Bot API long-polling message flow from the Python Telegram adapter
  (`../hermes-agent/gateway/platforms/telegram.py`; the file is no longer present
  in the current agent tree, but the Bot API semantics survive in
  `../hermes-agent/plugins/platforms/telegram/telegram_network.py`) and the
  per-session task lifecycle from `../hermes-agent/gateway/platforms/base.py:2078`.

  On each inbound Telegram message a dedicated `Hermes.Sessions.SessionServer` is
  created or resumed for the chat, giving per-session fault isolation. The
  connector subscribes to the session's PubSub topic and sends the final
  assistant response back to the originating chat.
  """

  use GenServer
  @behaviour Hermes.Gateway.Connector

  require Logger

  alias Phoenix.PubSub

  defstruct [
    :bot_token,
    :bot_api,
    :session_provider,
    :poll_ref,
    :offset,
    :connected,
    subscriptions: MapSet.new(),
    chat_sessions: %{}
  ]

  @default_poll_interval_ms 100

  @impl Hermes.Gateway.Connector
  def name, do: :telegram

  @impl Hermes.Gateway.Connector
  def label, do: "Telegram"

  @impl Hermes.Gateway.Connector
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    bot_token = config[:bot_token] || System.get_env("TELEGRAM_BOT_TOKEN")
    bot_api = config[:bot_api] || Hermes.Gateway.Connectors.TelegramBot

    session_provider =
      config[:session_provider] ||
        Application.get_env(:hermes, :telegram_session_provider, Hermes.Providers.Anthropic)

    poll_interval = config[:poll_interval_ms] || @default_poll_interval_ms

    if is_nil(bot_token) or bot_token == "" do
      {:stop, :missing_bot_token}
    else
      state = %__MODULE__{
        bot_token: bot_token,
        bot_api: bot_api,
        session_provider: session_provider,
        offset: 0,
        connected: false
      }

      # Stash the parts of state needed by the callback-style `send_message/3`.
      Process.put(__MODULE__, %{bot_token: bot_token, bot_api: bot_api})

      case connect(state) do
        {:ok, state} ->
          state = schedule_poll(state, poll_interval)
          {:ok, state}

        {:error, reason} ->
          {:stop, reason}
      end
    end
  end

  @impl Hermes.Gateway.Connector
  def connect(state) do
    case state.bot_api.get_me(state.bot_token) do
      {:ok, _me} ->
        Logger.info("Telegram connector authenticated")
        {:ok, %{state | connected: true}}

      {:error, reason} ->
        Logger.error("Telegram getMe failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Hermes.Gateway.Connector
  def disconnect(state) do
    if state.poll_ref, do: Process.cancel_timer(state.poll_ref)
    {:ok, %{state | connected: false, poll_ref: nil}}
  end

  @impl Hermes.Gateway.Connector
  def send_message(_session_id, message, opts) do
    # The framework routes outbound messages through the GenServer handle_call
    # below. This callback is kept for direct use; it reads the bot state from
    # the process dictionary.
    case Process.get(__MODULE__) do
      nil ->
        {:error, :not_initialized}

      %{bot_token: bot_token, bot_api: bot_api} ->
        chat_id = Keyword.fetch!(opts, :chat_id)
        bot_api.send_message(bot_token, chat_id, message, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:send_message, _session_id, message, opts}, _from, state) do
    chat_id = Keyword.fetch!(opts, :chat_id)
    result = state.bot_api.send_message(state.bot_token, chat_id, message, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:poll, state) do
    poll_interval = Process.get(:telegram_poll_interval_ms, @default_poll_interval_ms)

    case state.bot_api.get_updates(state.bot_token, state.offset, 30) do
      {:ok, updates} when is_list(updates) ->
        new_state = Enum.reduce(updates, state, &process_update/2)
        new_state = schedule_poll(new_state, poll_interval)
        {:noreply, new_state}

      {:ok, _other} ->
        {:noreply, schedule_poll(state, poll_interval)}

      {:error, reason} ->
        Logger.warning("Telegram getUpdates failed: #{inspect(reason)}")
        Process.send_after(self(), :poll, 5_000)
        {:noreply, state}
    end
  end

  def handle_info({:turn_complete, %{session_id: session_id} = payload}, state) do
    final_response = payload[:final_response] || payload["final_response"]

    state =
      if MapSet.member?(state.subscriptions, session_id) do
        chat_id = state.chat_sessions[session_id]

        if is_binary(final_response) and not is_nil(chat_id) do
          _ = state.bot_api.send_message(state.bot_token, chat_id, final_response, [])
        end

        %{state | subscriptions: MapSet.delete(state.subscriptions, session_id)}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:turn_error, %{session_id: session_id} = payload}, state) do
    error = payload[:error] || payload["error"]

    state =
      if MapSet.member?(state.subscriptions, session_id) do
        chat_id = state.chat_sessions[session_id]

        if not is_nil(chat_id) do
          text = "Error: #{error}"
          _ = state.bot_api.send_message(state.bot_token, chat_id, text, [])
        end

        %{state | subscriptions: MapSet.delete(state.subscriptions, session_id)}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.poll_ref, do: Process.cancel_timer(state.poll_ref)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Inbound message routing
  # ---------------------------------------------------------------------------

  @impl Hermes.Gateway.Connector
  def handle_inbound(%{"message" => message} = _update, state) do
    chat_id = message["chat"]["id"]
    text = message["text"] || ""
    user = message["from"]
    username = if is_map(user), do: user["username"], else: nil
    session_id = "telegram:#{to_string(chat_id)}"

    unless Hermes.Sessions.SessionServer.whereis(session_id) do
      Hermes.Sessions.start_session(
        session_id: session_id,
        source: "telegram",
        user_id: to_string(chat_id),
        user_name: username,
        provider: state.session_provider
      )
    end

    state =
      if MapSet.member?(state.subscriptions, session_id) do
        state
      else
        PubSub.subscribe(Hermes.PubSub, "session:#{session_id}")
        %{state | subscriptions: MapSet.put(state.subscriptions, session_id)}
      end

    state = %{state | chat_sessions: Map.put(state.chat_sessions, session_id, chat_id)}

    :ok = Hermes.Sessions.run_turn_async(session_id, text)

    {:ok, state}
  end

  def handle_inbound(_update, state) do
    {:ok, state}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp process_update(update, state) do
    {:ok, new_state} = handle_inbound(update, state)
    new_state
  end

  defp schedule_poll(state, interval_ms) do
    ref = Process.send_after(self(), :poll, interval_ms)
    %{state | poll_ref: ref}
  end
end
