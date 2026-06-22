defmodule Hermes.Gateway.Connectors.DiscordBot do
  @moduledoc """
  Thin REST client for the Discord Bot API.

  Ports the Bot API call patterns used by the Python Discord adapter. The
  original `../hermes-agent/gateway/platforms/discord.py` is no longer present
  in the current agent tree; the general webhook/adapter contract is described
  in `../hermes-agent/gateway/platforms/webhook.py:107` and the per-session
  task lifecycle in `../hermes-agent/gateway/platforms/base.py:2078`.

  Base URL: `https://discord.com/api/v10`.
  All calls go through `Hermes.Finch`.
  """

  require Logger

  @api_base "https://discord.com/api/v10"
  @receive_timeout_ms 10_000

  @spec get_current_user(String.t()) :: {:ok, map()} | {:error, term()}
  def get_current_user(bot_token) do
    request(bot_token, :get, "/users/@me", nil)
  end

  @spec send_message(String.t(), String.t() | integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(bot_token, channel_id, text, opts \\ []) do
    body = %{
      "content" => text,
      "tts" => Keyword.get(opts, :tts, false)
    }

    body =
      case Keyword.get(opts, :reply_to_message_id) do
        nil -> body
        id -> Map.put(body, "message_reference", %{"message_id" => to_string(id)})
      end

    request(bot_token, :post, "/channels/#{channel_id}/messages", body)
  end

  defp request(bot_token, method, path, body) do
    url = @api_base <> path

    headers = [
      {"Authorization", "Bot #{bot_token}"},
      {"Content-Type", "application/json"}
    ]

    req = Finch.build(method, url, headers, body && Jason.encode!(body))

    case Finch.request(req, Hermes.Finch, receive_timeout: @receive_timeout_ms) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        case Jason.decode(response_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:ok, %{"raw" => response_body}}
        end

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        Logger.warning("Discord Bot API returned HTTP #{status}: #{response_body}")
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        Logger.warning("Discord Bot API request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
