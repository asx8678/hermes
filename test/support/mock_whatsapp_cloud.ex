defmodule Hermes.Test.MockWhatsAppCloud do
  @moduledoc """
  Test double for `Hermes.Gateway.Connectors.WhatsAppCloud`.

  Delegates to `Hermes.Test.MockGatewayClient` using the `:whatsapp` namespace.
  """

  alias Hermes.Test.MockGatewayClient

  def send_message(token, phone_number_id, to, text, opts) do
    MockGatewayClient.whatsapp_send_message(token, phone_number_id, to, text, opts)
  end
end
