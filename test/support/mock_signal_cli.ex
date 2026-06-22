defmodule Hermes.Test.MockSignalCli do
  @moduledoc """
  Test double for `Hermes.Gateway.Connectors.SignalCli`.

  Delegates to `Hermes.Test.MockGatewayClient` using the `:signal` namespace.
  """

  alias Hermes.Test.MockGatewayClient

  def get_messages(phone_number, api_url) do
    MockGatewayClient.signal_get_messages(phone_number, api_url)
  end

  def send_message(phone_number, api_url, recipient, text, opts) do
    MockGatewayClient.signal_send_message(phone_number, api_url, recipient, text, opts)
  end
end
