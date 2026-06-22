defmodule Hermes.Gateway.Connectors.Signal do
  @moduledoc """
  Signal gateway connector.

  Ports the signal-cli REST API message flow from the Python Signal adapter
  (`../hermes-agent/gateway/platforms/signal.py:247`) and the per-session
  task lifecycle from `../hermes-agent/gateway/platforms/base.py:2078`.

  Inbound messages are polled from the configured signal-cli daemon. Each
  inbound message creates or resumes a dedicated
  `Hermes.Sessions.SessionServer` for the sender, giving per-session fault
  isolation. The connector subscribes to the session's PubSub topic and sends
  the final assistant response back to the originating phone number.
  """

  use GenServer
  @behaviour Hermes.Gateway.Connector

  require Logger

  alias Phoenix.PubSub

  defstruct [
    :phone_number,
    :api_url,
    :client,
    :session_provider,
    :poll_ref,
    :connected,
    subscriptions: MapSet.new(),
    sender_sessions: %{}
  ]

  @default_poll_interval_ms 1_000

  @impl Hermes.Gateway.Connector
  def name, do: :signal

  @impl Hermes.Gateway.Connector
  def label, do: "Signal"

  @impl Hermes.Gateway.Connector
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    phone_number = config[:phone_number] || System.get_env("SIGNAL_PHONE_NUMBER")
    api_url = config[:api_url] || System.get_env("SIGNAL_API_URL")
    client = config[:client] || Hermes.Gateway.Connectors.SignalCli

    session_provider =
      config[:session_provider] ||
        Application.get_env(:hermes, :signal_session_provider, Hermes.Providers.Anthropic)

    poll_interval = config[:poll_interval_ms] || @default_poll_interval_ms

    missing =
      [phone_number: phone_number, api_url: api_url]
      |> Enum.filter(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.map(fn {k, _v} -> k end)

    if missing != [] do
      {:stop, {:missing_config, missing}}
    else
      state = %__MODULE__{
        phone_number: phone_number,
        api_url: api_url,
        client: client,
        session_provider: session_provider,
        connected: false
      }

      Process.put(__MODULE__, %{
        phone_number: phone_number,
        api_url: api_url,
        client: client
      })

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
    Logger.info("Signal connector configured for #{state.phone_number}")
    {:ok, %{state | connected: true}}
  end

  @impl Hermes.Gateway.Connector
  def disconnect(state) do
    if state.poll_ref, do: Process.cancel_timer(state.poll_ref)
    {:ok, %{state | connected: false, poll_ref: nil}}
  end

  @impl Hermes.Gateway.Connector
  def send_message(_session_id, message, opts) do
    case Process.get(__MODULE__) do
      nil ->
        {:error, :not_initialized}

      %{phone_number: phone_number, api_url: api_url, client: client} ->
        recipient = Keyword.fetch!(opts, :recipient)
        client.send_message(phone_number, api_url, recipient, message, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:send_message, _session_id, message, opts}, _from, state) do
    recipient = Keyword.fetch!(opts, :recipient)

    result =
      state.client.send_message(state.phone_number, state.api_url, recipient, message, opts)

    {:reply, result, state}
  end

  @impl true
  def handle_info(:poll, state) do
    poll_interval = Process.get(:signal_poll_interval_ms, @default_poll_interval_ms)

    case state.client.get_messages(state.phone_number, state.api_url) do
      {:ok, messages} when is_list(messages) ->
        new_state = Enum.reduce(messages, state, &process_message/2)
        new_state = schedule_poll(new_state, poll_interval)
        {:noreply, new_state}

      {:ok, _other} ->
        {:noreply, schedule_poll(state, poll_interval)}

      {:error, reason} ->
        Logger.warning("Signal poll failed: #{inspect(reason)}")
        Process.send_after(self(), :poll, 5_000)
        {:noreply, state}
    end
  end

  def handle_info({:turn_complete, %{session_id: session_id} = payload}, state) do
    final_response = payload[:final_response] || payload["final_response"]

    state =
      if MapSet.member?(state.subscriptions, session_id) do
        recipient = state.sender_sessions[session_id]

        if is_binary(final_response) and not is_nil(recipient) do
          _ =
            state.client.send_message(
              state.phone_number,
              state.api_url,
              recipient,
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

  def handle_info({:turn_error, %{session_id: session_id} = payload}, state) do
    error = payload[:error] || payload["error"]

    state =
      if MapSet.member?(state.subscriptions, session_id) do
        recipient = state.sender_sessions[session_id]

        if not is_nil(recipient) do
          text = "Error: #{error}"

          _ =
            state.client.send_message(
              state.phone_number,
              state.api_url,
              recipient,
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
  def handle_inbound(message, state) do
    {:ok, process_message(message, state)}
  end

  defp process_message(message, state) do
    sender = message["sourceNumber"] || message["from"]
    text = message["dataMessage"] || message["text"] || ""

    text =
      if is_map(text) do
        text["message"] || text["body"] || ""
      else
        text
      end

    session_id = "signal:#{to_string(sender)}"

    unless Hermes.Sessions.SessionServer.whereis(session_id) do
      Hermes.Sessions.start_session(
        session_id: session_id,
        source: "signal",
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

    state
  end

  defp schedule_poll(state, interval_ms) do
    ref = Process.send_after(self(), :poll, interval_ms)
    %{state | poll_ref: ref}
  end
end
