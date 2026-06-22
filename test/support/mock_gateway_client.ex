defmodule Hermes.Test.MockGatewayClient do
  @moduledoc """
  Generic test double for gateway platform API clients.

  Records every call and returns canned responses pushed by tests. Each
  response is namespaced by `{platform, function}` so a single mock can serve
  all connector API modules.
  """

  use Agent

  def start_link(_ \\ []) do
    Agent.start_link(fn -> %{calls: [], responses: %{}} end, name: __MODULE__)
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> %{calls: [], responses: %{}} end)
  end

  def push_response(platform, function, response) do
    Agent.update(__MODULE__, fn state ->
      key = {platform, function}
      responses = Map.update(state.responses, key, [response], &(&1 ++ [response]))
      %{state | responses: responses}
    end)
  end

  def calls do
    Agent.get(__MODULE__, & &1.calls)
  end

  # ---------------------------------------------------------------------------
  # Discord
  # ---------------------------------------------------------------------------

  def discord_get_current_user(token) do
    pop_response(:discord, :get_current_user, [token])
  end

  def discord_send_message(token, channel_id, text, opts) do
    pop_response(:discord, :send_message, [token, channel_id, text, opts])
  end

  # ---------------------------------------------------------------------------
  # Slack
  # ---------------------------------------------------------------------------

  def slack_auth_test(token) do
    pop_response(:slack, :auth_test, [token])
  end

  def slack_send_message(token, channel, text, opts) do
    pop_response(:slack, :send_message, [token, channel, text, opts])
  end

  # ---------------------------------------------------------------------------
  # WhatsApp Cloud
  # ---------------------------------------------------------------------------

  def whatsapp_send_message(token, phone_number_id, to, text, opts) do
    pop_response(:whatsapp, :send_message, [token, phone_number_id, to, text, opts])
  end

  # ---------------------------------------------------------------------------
  # Signal
  # ---------------------------------------------------------------------------

  def signal_get_messages(phone_number, api_url) do
    pop_response(:signal, :get_messages, [phone_number, api_url])
  end

  def signal_send_message(phone_number, api_url, recipient, text, opts) do
    pop_response(:signal, :send_message, [phone_number, api_url, recipient, text, opts])
  end

  # ---------------------------------------------------------------------------
  # Email
  # ---------------------------------------------------------------------------

  def email_check_imap(host, user, password) do
    pop_response(:email, :check_imap, [host, user, password])
  end

  def email_send_email(smtp_host, smtp_user, smtp_password, to, subject, text, opts) do
    pop_response(:email, :send_email, [
      smtp_host,
      smtp_user,
      smtp_password,
      to,
      subject,
      text,
      opts
    ])
  end

  # ---------------------------------------------------------------------------
  # Feishu
  # ---------------------------------------------------------------------------

  def feishu_get_tenant_access_token(app_id, app_secret) do
    pop_response(:feishu, :get_tenant_access_token, [app_id, app_secret])
  end

  def feishu_send_message(token, chat_id, text, opts) do
    pop_response(:feishu, :send_message, [token, chat_id, text, opts])
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp pop_response(platform, function, args) do
    key = {platform, function}

    Agent.get_and_update(__MODULE__, fn state ->
      calls = [{key, args} | state.calls]
      responses = Map.get(state.responses, key, [])

      case responses do
        [head | tail] ->
          new_responses = Map.put(state.responses, key, tail)
          {head, %{state | calls: calls, responses: new_responses}}

        [] ->
          {{:error, :no_mock_response}, %{state | calls: calls}}
      end
    end)
  end
end
