defmodule Hermes.Test.MockSlackBot do
  @moduledoc """
  Test double for `Hermes.Gateway.Connectors.SlackBot`.

  Delegates to `Hermes.Test.MockGatewayClient` using the `:slack` namespace.
  """

  alias Hermes.Test.MockGatewayClient

  def auth_test(token) do
    MockGatewayClient.slack_auth_test(token)
  end

  def send_message(token, channel, text, opts) do
    MockGatewayClient.slack_send_message(token, channel, text, opts)
  end
end
