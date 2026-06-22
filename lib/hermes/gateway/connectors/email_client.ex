defmodule Hermes.Gateway.Connectors.EmailClient do
  @moduledoc """
  Thin client for inbound IMAP and outbound SMTP.

  Ports the email platform concepts from
  `../hermes-agent/gateway/platforms/msgraph_webhook.py:45` and the
  per-session task lifecycle from `../hermes-agent/gateway/platforms/base.py:2078`.

  Real email protocols (IMAP/SMTP) need dedicated client libraries. This module
  is a stub template: all interaction is isolated behind it so tests can swap
  it for a mock.
  """

  require Logger

  @spec check_imap(String.t(), String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def check_imap(_host, _user, _password) do
    # Template stub: a real implementation would poll the IMAP inbox.
    {:ok, []}
  end

  @spec send_email(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, term()} | {:error, term()}
  def send_email(_host, _user, _password, to, subject, text, _opts) do
    # Template stub: a real implementation would send via SMTP.
    Logger.info("Email send to #{to} / #{subject}: #{text}")
    {:ok, %{"sent" => true}}
  end
end
