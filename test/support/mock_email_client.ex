defmodule Hermes.Test.MockEmailClient do
  @moduledoc """
  Test double for `Hermes.Gateway.Connectors.EmailClient`.

  Delegates to `Hermes.Test.MockGatewayClient` using the `:email` namespace.
  """

  alias Hermes.Test.MockGatewayClient

  def check_imap(host, user, password) do
    MockGatewayClient.email_check_imap(host, user, password)
  end

  def send_email(smtp_host, smtp_user, smtp_password, to, subject, text, opts) do
    MockGatewayClient.email_send_email(
      smtp_host,
      smtp_user,
      smtp_password,
      to,
      subject,
      text,
      opts
    )
  end
end
