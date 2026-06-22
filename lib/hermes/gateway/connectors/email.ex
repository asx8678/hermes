defmodule Hermes.Gateway.Connectors.Email do
  @moduledoc """
  Email gateway connector.

  Ports the email message flow from the Python Microsoft Graph webhook adapter
  (`../hermes-agent/gateway/platforms/msgraph_webhook.py:45`) and the
  per-session task lifecycle from `../hermes-agent/gateway/platforms/base.py:2078`.

  Inbound messages are polled from the configured IMAP inbox. Each inbound
  message creates or resumes a dedicated `Hermes.Sessions.SessionServer` for
  the sender address, giving per-session fault isolation. The connector
  subscribes to the session's PubSub topic and sends the final assistant
  response back to the originating sender via SMTP.
  """

  use GenServer
  @behaviour Hermes.Gateway.Connector

  require Logger

  alias Phoenix.PubSub

  defstruct [
    :imap_host,
    :imap_user,
    :imap_password,
    :smtp_host,
    :smtp_user,
    :smtp_password,
    :client,
    :session_provider,
    :poll_ref,
    :connected,
    subscriptions: MapSet.new(),
    sender_sessions: %{}
  ]

  @default_poll_interval_ms 5_000

  @impl Hermes.Gateway.Connector
  def name, do: :email

  @impl Hermes.Gateway.Connector
  def label, do: "Email"

  @impl Hermes.Gateway.Connector
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    imap_host = config[:imap_host] || System.get_env("IMAP_HOST")
    imap_user = config[:imap_user] || System.get_env("IMAP_USER")
    imap_password = config[:imap_password] || System.get_env("IMAP_PASSWORD")
    smtp_host = config[:smtp_host] || System.get_env("SMTP_HOST")
    smtp_user = config[:smtp_user] || System.get_env("SMTP_USER")
    smtp_password = config[:smtp_password] || System.get_env("SMTP_PASSWORD")
    client = config[:client] || Hermes.Gateway.Connectors.EmailClient

    session_provider =
      config[:session_provider] ||
        Application.get_env(:hermes, :email_session_provider, Hermes.Providers.Anthropic)

    poll_interval = config[:poll_interval_ms] || @default_poll_interval_ms

    missing =
      [
        imap_host: imap_host,
        imap_user: imap_user,
        imap_password: imap_password,
        smtp_host: smtp_host,
        smtp_user: smtp_user,
        smtp_password: smtp_password
      ]
      |> Enum.filter(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.map(fn {k, _v} -> k end)

    if missing != [] do
      {:stop, {:missing_config, missing}}
    else
      state = %__MODULE__{
        imap_host: imap_host,
        imap_user: imap_user,
        imap_password: imap_password,
        smtp_host: smtp_host,
        smtp_user: smtp_user,
        smtp_password: smtp_password,
        client: client,
        session_provider: session_provider,
        connected: false
      }

      Process.put(__MODULE__, %{
        imap_host: imap_host,
        imap_user: imap_user,
        imap_password: imap_password,
        smtp_host: smtp_host,
        smtp_user: smtp_user,
        smtp_password: smtp_password,
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
    Logger.info("Email connector configured for IMAP #{state.imap_host}")
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

      %{
        smtp_host: smtp_host,
        smtp_user: smtp_user,
        smtp_password: smtp_password,
        client: client
      } ->
        to = Keyword.fetch!(opts, :to)
        subject = Keyword.get(opts, :subject, "Re:")
        client.send_email(smtp_host, smtp_user, smtp_password, to, subject, message, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:send_message, _session_id, message, opts}, _from, state) do
    to = Keyword.fetch!(opts, :to)
    subject = Keyword.get(opts, :subject, "Re:")

    result =
      state.client.send_email(
        state.smtp_host,
        state.smtp_user,
        state.smtp_password,
        to,
        subject,
        message,
        opts
      )

    {:reply, result, state}
  end

  @impl true
  def handle_info(:poll, state) do
    poll_interval = Process.get(:email_poll_interval_ms, @default_poll_interval_ms)

    case state.client.check_imap(state.imap_host, state.imap_user, state.imap_password) do
      {:ok, messages} when is_list(messages) ->
        new_state = Enum.reduce(messages, state, &process_message/2)
        new_state = schedule_poll(new_state, poll_interval)
        {:noreply, new_state}

      {:ok, _other} ->
        {:noreply, schedule_poll(state, poll_interval)}

      {:error, reason} ->
        Logger.warning("Email IMAP poll failed: #{inspect(reason)}")
        Process.send_after(self(), :poll, 5_000)
        {:noreply, state}
    end
  end

  def handle_info({:turn_complete, %{session_id: session_id} = payload}, state) do
    final_response = payload[:final_response] || payload["final_response"]

    state =
      if MapSet.member?(state.subscriptions, session_id) do
        to = state.sender_sessions[session_id]

        if is_binary(final_response) and not is_nil(to) do
          _ =
            state.client.send_email(
              state.smtp_host,
              state.smtp_user,
              state.smtp_password,
              to,
              "Re:",
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
        to = state.sender_sessions[session_id]

        if not is_nil(to) do
          text = "Error: #{error}"

          _ =
            state.client.send_email(
              state.smtp_host,
              state.smtp_user,
              state.smtp_password,
              to,
              "Re:",
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
    sender = message["from"]
    text = message["body"] || message["text"] || ""
    session_id = "email:#{to_string(sender)}"

    unless Hermes.Sessions.SessionServer.whereis(session_id) do
      Hermes.Sessions.start_session(
        session_id: session_id,
        source: "email",
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
