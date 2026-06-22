defmodule Hermes.Gateway.Connectors.WhatsApp do
  @moduledoc """
  WhatsApp Cloud gateway connector.

  Ports the WhatsApp Business Cloud API message flow from the Python adapter
  (`../hermes-agent/gateway/platforms/whatsapp_cloud.py:178`) and the
  per-session task lifecycle from `../hermes-agent/gateway/platforms/base.py:2078`.

  Inbound webhook payloads are delivered via `handle_inbound/2` (the HTTP
  listener is intentionally omitted from this template). Each inbound message
  creates or resumes a dedicated `Hermes.Sessions.SessionServer` for the
  sender, giving per-session fault isolation. The connector subscribes to the
  session's PubSub topic and sends the final assistant response back to the
  originating phone number.
  """

  use GenServer
  @behaviour Hermes.Gateway.Connector

  require Logger

  alias Phoenix.PubSub

  defstruct [
    :token,
    :phone_number_id,
    :bot_api,
    :session_provider,
    :connected,
    subscriptions: MapSet.new(),
    sender_sessions: %{}
  ]

  @impl Hermes.Gateway.Connector
  def name, do: :whatsapp

  @impl Hermes.Gateway.Connector
  def label, do: "WhatsApp"

  @impl Hermes.Gateway.Connector
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    token = config[:token] || System.get_env("WHATSAPP_TOKEN")
    phone_number_id = config[:phone_number_id] || System.get_env("WHATSAPP_PHONE_NUMBER_ID")
    bot_api = config[:bot_api] || Hermes.Gateway.Connectors.WhatsAppCloud

    session_provider =
      config[:session_provider] ||
        Application.get_env(:hermes, :whatsapp_session_provider, Hermes.Providers.Anthropic)

    missing =
      [token: token, phone_number_id: phone_number_id]
      |> Enum.filter(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.map(fn {k, _v} -> k end)

    if missing != [] do
      {:stop, {:missing_config, missing}}
    else
      state = %__MODULE__{
        token: token,
        phone_number_id: phone_number_id,
        bot_api: bot_api,
        session_provider: session_provider,
        connected: false
      }

      Process.put(__MODULE__, %{
        token: token,
        phone_number_id: phone_number_id,
        bot_api: bot_api
      })

      {:ok, state} = connect(state)
      {:ok, state}
    end
  end

  @impl Hermes.Gateway.Connector
  def connect(state) do
    Logger.info("WhatsApp connector configured for #{state.phone_number_id}")
    {:ok, %{state | connected: true}}
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

      %{token: token, phone_number_id: phone_number_id, bot_api: bot_api} ->
        to = Keyword.fetch!(opts, :to)
        bot_api.send_message(token, phone_number_id, to, message, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:send_message, _session_id, message, opts}, _from, state) do
    to = Keyword.fetch!(opts, :to)

    result =
      state.bot_api.send_message(state.token, state.phone_number_id, to, message, opts)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:handle_inbound, payload}, _from, state) do
    {:ok, new_state} = handle_inbound(payload, state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({:turn_complete, %{session_id: session_id} = payload}, state) do
    final_response = payload[:final_response] || payload["final_response"]

    state =
      if MapSet.member?(state.subscriptions, session_id) do
        to = state.sender_sessions[session_id]

        if is_binary(final_response) and not is_nil(to) do
          _ =
            state.bot_api.send_message(
              state.token,
              state.phone_number_id,
              to,
              final_response,
              []
            )
        end

        %{state | subscriptions: MapSet.delete(state.subscriptions, session_id)}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:turn_error, %{session_id: session_id} = payload}, state) do
    error = payload[:error] || payload["error"]

    state =
      if MapSet.member?(state.subscriptions, session_id) do
        to = state.sender_sessions[session_id]

        if not is_nil(to) do
          text = "Error: #{error}"

          _ =
            state.bot_api.send_message(
              state.token,
              state.phone_number_id,
              to,
              text,
              []
            )
        end

        %{state | subscriptions: MapSet.delete(state.subscriptions, session_id)}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
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
  def handle_inbound(%{"entry" => entries} = _payload, state) when is_list(entries) do
    Enum.reduce(entries, state, fn entry, state_acc ->
      changes = entry["changes"] || []

      Enum.reduce(changes, state_acc, fn change, change_state ->
        value = change["value"] || %{}
        messages = value["messages"] || []

        Enum.reduce(messages, change_state, fn message, msg_state ->
          {:ok, new_state} = process_message(message, msg_state)
          new_state
        end)
      end)
    end)
    |> then(&{:ok, &1})
  end

  def handle_inbound(_payload, state) do
    {:ok, state}
  end

  defp process_message(message, state) do
    sender = message["from"]
    text = get_in(message, ["text", "body"]) || ""
    session_id = "whatsapp:#{to_string(sender)}"

    unless Hermes.Sessions.SessionServer.whereis(session_id) do
      Hermes.Sessions.start_session(
        session_id: session_id,
        source: "whatsapp",
        user_id: to_string(sender),
        user_name: nil,
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

    state = %{state | sender_sessions: Map.put(state.sender_sessions, session_id, sender)}

    :ok = Hermes.Sessions.run_turn_async(session_id, text)

    {:ok, state}
  end
end
