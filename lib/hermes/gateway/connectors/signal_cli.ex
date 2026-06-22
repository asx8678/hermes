defmodule Hermes.Gateway.Connectors.SignalCli do
  @moduledoc """
  Thin REST client for a self-hosted signal-cli daemon.

  Ports the signal-cli call patterns used by the Python Signal adapter
  (`../hermes-agent/gateway/platforms/signal.py:247`). The per-session task
  lifecycle is described in `../hermes-agent/gateway/platforms/base.py:2078`.

  signal-cli exposes a local HTTP REST API. This module is a stub template:
  real SMTP/IMAP protocols would need dedicated client libraries. All
  interaction is isolated behind this module so tests can swap it for a mock.
  """

  require Logger

  @spec get_messages(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_messages(_phone_number, _api_url) do
    # Template stub: a real implementation would GET /v1/receive/{phone_number}
    # from the signal-cli REST API.
    {:ok, []}
  end

  @spec send_message(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def send_message(_phone_number, _api_url, recipient, text, _opts) do
    # Template stub: a real implementation would POST /v2/send.
    Logger.info("Signal send to #{recipient}: #{text}")
    {:ok, %{"sent" => true}}
  end
end
