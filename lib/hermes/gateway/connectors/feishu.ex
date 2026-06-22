defmodule Hermes.Gateway.Connectors.Feishu do
  @moduledoc """
  Feishu (Lark) gateway connector.

  Ports the Feishu Open Platform event-subscription message flow from the
  Python Weixin adapter (`../hermes-agent/gateway/platforms/weixin.py:1`) and
  the per-session task lifecycle from
  `../hermes-agent/gateway/platforms/base.py:2078`.

  Inbound events are delivered via `handle_inbound/2` (the event-subscription
  HTTP listener is intentionally omitted from this template). Each inbound
  message creates or resumes a dedicated `Hermes.Sessions.SessionServer` for
  the chat, giving per-session fault isolation. The connector subscribes to
  the session's PubSub topic and sends the final assistant response back to
  the originating chat.
  """

  use GenServer
  @behaviour Hermes.Gateway.Connector

  require Logger

  alias Phoenix.PubSub

  defstruct [
    :app_id,
    :app_secret,
    :bot_api,
    :session_provider,
    :connected,
    subscriptions: MapSet.new(),
    chat_sessions: %{}
  ]

  @impl Hermes.Gateway.Connector
  def name, do: :feishu

  @impl Hermes.Gateway.Connector
  def label, do: "Feishu"

  @impl Hermes.Gateway.Connector
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    app_id = config[:app_id] || System.get_env("FEISHU_APP_ID")
    app_secret = config[:app_secret] || System.get_env("FEISHU_APP_SECRET")
    bot_api = config[:bot_api] || Hermes.Gateway.Connectors.FeishuBot

    session_provider =
      config[:session_provider] ||
        Application.get_env(:hermes, :feishu_session_provider, Hermes.Providers.Anthropic)

    missing =
      [app_id: app_id, app_secret: app_secret]
      |> Enum.filter(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.map(fn {k, _v} -> k end)

    if missing != [] do
      {:stop, {:missing_config, missing}}
    else
      state = %__MODULE__{
        app_id: app_id,
        app_secret: app_secret,
        bot_api: bot_api,
        session_provider: session_provider,
        connected: false
      }

      Process.put(__MODULE__, %{
        app_id: app_id,
        app_secret: app_secret,
        bot_api: bot_api
      })

      case connect(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:stop, reason}
      end
    end
  end

  @impl Hermes.Gateway.Connector
  def connect(state) do
    case state.bot_api.get_tenant_access_token(state.app_id, state.app_secret) do
      {:ok, _result} ->
        Logger.info("Feishu connector authenticated")
        {:ok, %{state | connected: true}}

      {:error, reason} ->
        Logger.error("Feishu tenant_access_token failed: #{inspect(reason)}")
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

      %{app_id: app_id, app_secret: app_secret, bot_api: bot_api} ->
        chat_id = Keyword.fetch!(opts, :chat_id)

        case bot_api.get_tenant_access_token(app_id, app_secret) do
          {:ok, %{"tenant_access_token" => token}} ->
            bot_api.send_message(token, chat_id, message, opts)

          {:ok, result} ->
            Logger.error("Feishu send could not obtain token: #{inspect(result)}")
            {:error, :missing_token}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:send_message, _session_id, message, opts}, _from, state) do
    chat_id = Keyword.fetch!(opts, :chat_id)

    result =
      case state.bot_api.get_tenant_access_token(state.app_id, state.app_secret) do
        {:ok, %{"tenant_access_token" => token}} ->
          state.bot_api.send_message(token, chat_id, message, opts)

        {:ok, result} ->
          Logger.error("Feishu send could not obtain token: #{inspect(result)}")
          {:error, :missing_token}

        {:error, reason} ->
          {:error, reason}
      end

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
        chat_id = state.chat_sessions[session_id]

        if is_binary(final_response) and not is_nil(chat_id) do
          _ =
            state.bot_api.get_tenant_access_token(state.app_id, state.app_secret)
            |> case do
              {:ok, %{"tenant_access_token" => token}} ->
                state.bot_api.send_message(token, chat_id, final_response, [])

              _ ->
                :error
            end
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

          _ =
            state.bot_api.get_tenant_access_token(state.app_id, state.app_secret)
            |> case do
              {:ok, %{"tenant_access_token" => token}} ->
                state.bot_api.send_message(token, chat_id, text, [])

              _ ->
                :error
            end
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
  def handle_inbound(%{"event" => event} = _payload, state) do
    chat_id = event["chat_id"] || get_in(event, ["message", "chat_id"])
    text = event["text"] || get_in(event, ["message", "content"]) || ""
    user = event["open_id"] || get_in(event, ["sender", "sender_id", "open_id"])
    session_id = "feishu:#{to_string(chat_id)}"

    unless Hermes.Sessions.SessionServer.whereis(session_id) do
      Hermes.Sessions.start_session(
        session_id: session_id,
        source: "feishu",
        user_id: to_string(chat_id),
        user_name: user,
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

  def handle_inbound(_payload, state) do
    {:ok, state}
  end
end
