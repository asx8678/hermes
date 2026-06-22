defmodule Hermes.Test.MockDiscordBot do
  @moduledoc """
  Test double for `Hermes.Gateway.Connectors.DiscordBot`.

  Delegates to `Hermes.Test.MockGatewayClient` using the `:discord` namespace.
  """

  alias Hermes.Test.MockGatewayClient

  def get_current_user(token) do
    MockGatewayClient.discord_get_current_user(token)
  end

  def send_message(token, channel_id, text, opts) do
    MockGatewayClient.discord_send_message(token, channel_id, text, opts)
  end
end
