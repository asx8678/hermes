defmodule Hermes.Test.MockFeishuBot do
  @moduledoc """
  Test double for `Hermes.Gateway.Connectors.FeishuBot`.

  Delegates to `Hermes.Test.MockGatewayClient` using the `:feishu` namespace.
  """

  alias Hermes.Test.MockGatewayClient

  def get_tenant_access_token(app_id, app_secret) do
    MockGatewayClient.feishu_get_tenant_access_token(app_id, app_secret)
  end

  def send_message(token, chat_id, text, opts) do
    MockGatewayClient.feishu_send_message(token, chat_id, text, opts)
  end
end
