defmodule Hermes.Gateway.Connectors.SlackBot do
  @moduledoc """
  Thin REST client for the Slack Web API.

  Ports the Slack Web API call patterns used by the Python Slack adapter. The
  original `../hermes-agent/gateway/platforms/slack.py` is no longer present
  in the current agent tree; the general webhook/adapter contract is described
  in `../hermes-agent/gateway/platforms/webhook.py:107` and the per-session
  task lifecycle in `../hermes-agent/gateway/platforms/base.py:2078`.

  Base URL: `https://slack.com/api`.
  All calls go through `Hermes.Finch`.
  """

  require Logger

  @api_base "https://slack.com/api"
  @receive_timeout_ms 10_000

  @spec auth_test(String.t()) :: {:ok, map()} | {:error, term()}
  def auth_test(bot_token) do
    request(bot_token, :post, "/auth.test", %{})
  end

  @spec send_message(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(bot_token, channel, text, opts \\ []) do
    body = %{
      "channel" => channel,
      "text" => text
    }

    body =
      case Keyword.get(opts, :thread_ts) do
        nil -> body
        ts -> Map.put(body, "thread_ts", ts)
      end

    request(bot_token, :post, "/chat.postMessage", body)
  end

  defp request(bot_token, method, path, body) do
    url = @api_base <> path

    headers = [
      {"Authorization", "Bearer #{bot_token}"},
      {"Content-Type", "application/x-www-form-urlencoded"}
    ]

    encoded_body = URI.encode_query(body)
    req = Finch.build(method, url, headers, encoded_body)

    case Finch.request(req, Hermes.Finch, receive_timeout: @receive_timeout_ms) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        case Jason.decode(response_body) do
          {:ok, %{"ok" => true} = decoded} -> {:ok, decoded}
          {:ok, %{"ok" => false} = decoded} -> {:error, decoded}
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:ok, %{"raw" => response_body}}
        end

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        Logger.warning("Slack Web API returned HTTP #{status}: #{response_body}")
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        Logger.warning("Slack Web API request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
