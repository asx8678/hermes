defmodule Hermes.Gateway.Connectors.WhatsAppCloud do
  @moduledoc """
  Thin REST client for the Meta WhatsApp Cloud API.

  Ports the WhatsApp Cloud API call patterns used by the Python adapter
  (`../hermes-agent/gateway/platforms/whatsapp_cloud.py:178`) and the
  per-session task lifecycle from `../hermes-agent/gateway/platforms/base.py:2078`.

  Base URL: `https://graph.facebook.com/v20.0`.
  All calls go through `Hermes.Finch`.
  """

  require Logger

  @api_base "https://graph.facebook.com/v20.0"
  @receive_timeout_ms 15_000

  @spec send_message(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(token, phone_number_id, to, text, opts \\ []) do
    body = %{
      "messaging_product" => "whatsapp",
      "recipient_type" => "individual",
      "to" => to,
      "type" => "text",
      "text" => %{"body" => text}
    }

    request(token, :post, "/#{phone_number_id}/messages", body, opts)
  end

  defp request(token, method, path, body, opts) do
    url = @api_base <> path
    headers = [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]
    req = Finch.build(method, url, headers, Jason.encode!(body))

    receive_timeout = Keyword.get(opts, :receive_timeout, @receive_timeout_ms)

    case Finch.request(req, Hermes.Finch, receive_timeout: receive_timeout) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        case Jason.decode(response_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:ok, %{"raw" => response_body}}
        end

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        Logger.warning("WhatsApp Cloud API returned HTTP #{status}: #{response_body}")
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        Logger.warning("WhatsApp Cloud API request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
