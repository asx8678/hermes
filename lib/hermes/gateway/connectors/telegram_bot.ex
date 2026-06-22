defmodule Hermes.Gateway.Connectors.TelegramBot do
  @moduledoc """
  Thin HTTP client for the Telegram Bot API.

  Ports the Bot API call patterns used by the Python Telegram adapter. The
  original `../hermes-agent/gateway/platforms/telegram.py` is no longer present
  in the current agent tree; the surviving network-layer conventions are
  documented in `../hermes-agent/plugins/platforms/telegram/telegram_network.py`.

  Base URL: `https://api.telegram.org/bot<token>/<method>`.
  Long polling uses the `getUpdates` method with `timeout=30` and a
  receive timeout slightly longer than the poll timeout.

  All calls go through `Hermes.Finch`.
  """

  require Logger

  @api_host "api.telegram.org"
  @default_timeout 30
  @receive_timeout_padding_ms 5_000

  @spec get_me(String.t()) :: {:ok, map()} | {:error, term()}
  def get_me(bot_token) do
    request(bot_token, "getMe", %{}, [])
  end

  @spec get_updates(String.t(), integer(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def get_updates(bot_token, offset, timeout \\ @default_timeout) do
    params = %{offset: offset, timeout: timeout}
    opts = [receive_timeout: timeout * 1000 + @receive_timeout_padding_ms]

    case request(bot_token, "getUpdates", params, opts) do
      {:ok, %{"result" => result}} when is_list(result) ->
        {:ok, result}

      {:ok, %{"ok" => true} = response} ->
        {:ok, Map.get(response, "result", [])}

      error ->
        error
    end
  end

  @spec send_message(String.t(), integer() | String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(bot_token, chat_id, text, opts \\ []) do
    params = %{
      chat_id: chat_id,
      text: text
    }

    params =
      Enum.reduce([:parse_mode, :reply_to_message_id, :disable_notification], params, fn key,
                                                                                         acc ->
        case Keyword.get(opts, key) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      end)

    request(bot_token, "sendMessage", params, [])
  end

  defp request(bot_token, method, params, opts) do
    url = "https://#{@api_host}/bot#{bot_token}/#{method}"
    body = Jason.encode!(params)

    headers = [{"content-type", "application/json"}]
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Hermes.Finch, opts) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        decode_response(response_body)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        Logger.warning("Telegram Bot API returned HTTP #{status}: #{response_body}")
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        Logger.warning("Telegram Bot API request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp decode_response(body) do
    case Jason.decode(body) do
      {:ok, %{"ok" => true} = decoded} ->
        {:ok, decoded}

      {:ok, %{"ok" => false, "description" => description}} ->
        {:error, description}

      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
