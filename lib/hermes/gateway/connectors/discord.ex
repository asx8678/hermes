defmodule Hermes.Gateway.Connectors.Discord do
  @moduledoc """
  Discord gateway connector.

  Ports the Discord Bot API message flow from the Python Discord adapter
  (`../hermes-agent/gateway/platforms/discord.py`; the file is no longer present
  in the current agent tree, but the general webhook/adapter contract survives
  in `../hermes-agent/gateway/platforms/webhook.py:107`) and the per-session
  task lifecycle from `../hermes-agent/gateway/platforms/base.py:2078`.

  Inbound events are delivered via `handle_inbound/2` (the Gateway/WebSocket
  polling is intentionally omitted from this template; see C4 for streaming).
  Each inbound message creates or resumes a dedicated
  `Hermes.Sessions.SessionServer` for the channel, giving per-session fault
  isolation. The connector subscribes to the session's PubSub topic and sends
  the final assistant response back to the originating channel.
  """

  use GenServer
  @behaviour Hermes.Gateway.Connector

  require Logger

  alias Phoenix.PubSub

  defstruct [
    :bot_token,
    :bot_api,
    :session_provider,
    :connected,
    subscriptions: MapSet.new(),
    channel_sessions: %{}
  ]

  @impl Hermes.Gateway.Connector
  def name, do: :discord

  @impl Hermes.Gateway.Connector
  def label, do: "Discord"

  @impl Hermes.Gateway.Connector
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    bot_token = config[:bot_token] || System.get_env("DISCORD_BOT_TOKEN")
    bot_api = config[:bot_api] || Hermes.Gateway.Connectors.DiscordBot

    session_provider =
      config[:session_provider] ||
        Application.get_env(:hermes, :discord_session_provider, Hermes.Providers.Anthropic)

    if is_nil(bot_token) or bot_token == "" do
      {:stop, :missing_bot_token}
    else
      state = %__MODULE__{
        bot_token: bot_token,
        bot_api: bot_api,
        session_provider: session_provider,
        connected: false
      }

      Process.put(__MODULE__, %{bot_token: bot_token, bot_api: bot_api})

      case connect(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:stop, reason}
      end
    end
  end

  @impl Hermes.Gateway.Connector
  def connect(state) do
    case state.bot_api.get_current_user(state.bot_token) do
      {:ok, _me} ->
        Logger.info("Discord connector authenticated")
        {:ok, %{state | connected: true}}

      {:error, reason} ->
        Logger.error("Discord getCurrentUser failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Hermes.Gateway.Connector
  def disconnect(state) do
    {:ok, %{state | connected: false}}
  end

  @impl Hermes.Gateway.Connector
  def send_message(_session_id, message, opts) do
    case Process.get(__MODULE__) do
      nil ->
        {:error, :not_initialized}

      %{bot_token: bot_token, bot_api: bot_api} ->
        channel_id = Keyword.fetch!(opts, :channel_id)
        bot_api.send_message(bot_token, channel_id, message, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:send_message, _session_id, message, opts}, _from, state) do
    channel_id = Keyword.fetch!(opts, :channel_id)
    result = state.bot_api.send_message(state.bot_token, channel_id, message, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:handle_inbound, payload}, _from, state) do
    case handle_inbound(payload, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_info({:turn_complete, %{session_id: session_id} = payload}, state) do
    final_response = payload[:final_response] || payload["final_response"]

    state =
      if MapSet.member?(state.subscriptions, session_id) do
        channel_id = state.channel_sessions[session_id]

        if is_binary(final_response) and not is_nil(channel_id) do
          _ = state.bot_api.send_message(state.bot_token, channel_id, final_response, [])
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
        channel_id = state.channel_sessions[session_id]

        if not is_nil(channel_id) do
          text = "Error: #{error}"
          _ = state.bot_api.send_message(state.bot_token, channel_id, text, [])
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
  def terminate(_reason, _state) do
    :ok
  end

  # ---------------------------------------------------------------------------
  # Inbound message routing
  # ---------------------------------------------------------------------------

  @impl Hermes.Gateway.Connector
  def handle_inbound(%{"type" => "MESSAGE_CREATE"} = event, state) do
    author = event["author"] || %{}

    if author["bot"] do
      {:ok, state}
    else
      channel_id = event["channel_id"]
      text = event["content"] || ""
      username = author["username"]
      session_id = "discord:#{to_string(channel_id)}"

      unless Hermes.Sessions.SessionServer.whereis(session_id) do
        Hermes.Sessions.start_session(
          session_id: session_id,
          source: "discord",
          user_id: to_string(channel_id),
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

      state = %{state | channel_sessions: Map.put(state.channel_sessions, session_id, channel_id)}

      :ok = Hermes.Sessions.run_turn_async(session_id, text)

      {:ok, state}
    end
  end

  def handle_inbound(_event, state) do
    {:ok, state}
  end
end
