defmodule Hermes.Gateway.Connectors.SignalCli do
  @moduledoc """
  REST client for a self-hosted signal-cli daemon.

  Ports the signal-cli HTTP API call patterns from
  `hermes-agent/gateway/platforms/signal.py:247-353`.

  signal-cli exposes a local HTTP REST API (default `http://127.0.0.1:8080`).
  This module handles inbound message retrieval (`GET /v1/receive/{number}`)
  and outbound message sending (`POST /v2/send`).

  All HTTP calls use `Finch` (`Hermes.Finch`) with a 30s timeout.
  """

  require Logger

  @default_timeout 30_000

  @spec get_messages(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_messages(phone_number, api_url) do
    url = "#{String.trim_trailing(api_url, "/")}/v1/receive/#{phone_number}?timeout=1"

    request =
      Finch.build(:get, url, headers())

    case Finch.request(request, Hermes.Finch, receive_timeout: @default_timeout) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, messages} when is_list(messages) ->
            {:ok, Enum.map(messages, &normalize_inbound_message/1)}

          {:ok, _} ->
            {:ok, []}

          {:error, _} ->
            {:ok, []}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.warning("SignalCli get_messages HTTP #{status}: #{body}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.warning("SignalCli get_messages failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec send_message(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def send_message(phone_number, api_url, recipient, text, opts \\ []) do
    url = "#{String.trim_trailing(api_url, "/")}/v2/send"

    body =
      %{
        number: phone_number,
        recipients: [recipient],
        message: text
      }
      |> maybe_put(:timestamp, Keyword.get(opts, :timestamp))
      |> Jason.encode!()

    request = Finch.build(:post, url, headers(), body)

    case Finch.request(request, Hermes.Finch, receive_timeout: @default_timeout) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        case Jason.decode(resp_body) do
          {:ok, result} -> {:ok, result}
          _ -> {:ok, %{"sent" => true}}
        end

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("SignalCli send_message HTTP #{status}: #{resp_body}")
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        Logger.warning("SignalCli send_message failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp headers do
    [{"content-type", "application/json"}, {"accept", "application/json"}]
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_inbound_message(%{"envelope" => envelope}) do
    %{
      "sender" => envelope["source"],
      "source_uuid" => envelope["sourceUuid"],
      "source_number" => envelope["sourceNumber"],
      "timestamp" => envelope["timestamp"],
      "data_message" => envelope["dataMessage"],
      "sync_message" => envelope["syncMessage"],
      "call_message" => envelope["callMessage"],
      "receipt" => envelope["receipt"]
    }
  end

  defp normalize_inbound_message(msg), do: msg
end
