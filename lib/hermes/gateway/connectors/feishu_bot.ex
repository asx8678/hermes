defmodule Hermes.Gateway.Connectors.FeishuBot do
  @moduledoc """
  Thin REST client for the Feishu (Lark) Open Platform Bot API.

  Ports the Feishu call patterns from the Python Weixin adapter
  (`../hermes-agent/gateway/platforms/weixin.py:1`) and the per-session
  task lifecycle from `../hermes-agent/gateway/platforms/base.py:2078`.

  Base URL: `https://open.feishu.cn/open-apis`.
  All calls go through `Hermes.Finch`.
  """

  require Logger

  @api_base "https://open.feishu.cn/open-apis"
  @receive_timeout_ms 10_000

  @spec get_tenant_access_token(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_tenant_access_token(app_id, app_secret) do
    body = %{
      "app_id" => app_id,
      "app_secret" => app_secret
    }

    request(:post, "/auth/v3/tenant_access_token/internal", body, [])
  end

  @spec send_message(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(token, chat_id, text, opts \\ []) do
    body = %{
      "receive_id" => chat_id,
      "msg_type" => "text",
      "content" => Jason.encode!(%{"text" => text})
    }

    headers = [{"Authorization", "Bearer #{token}"}]
    request(:post, "/im/v1/messages?receive_id_type=chat_id", body, headers)
  end

  defp request(method, path, body, extra_headers) do
    url = @api_base <> path
    headers = [{"Content-Type", "application/json"} | extra_headers]
    req = Finch.build(method, url, headers, Jason.encode!(body))

    case Finch.request(req, Hermes.Finch, receive_timeout: @receive_timeout_ms) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        case Jason.decode(response_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:ok, %{"raw" => response_body}}
        end

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        Logger.warning("Feishu Open Platform returned HTTP #{status}: #{response_body}")
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        Logger.warning("Feishu Open Platform request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
