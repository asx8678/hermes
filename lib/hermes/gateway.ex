defmodule Hermes.Gateway do
  @moduledoc """
  Public API for the gateway subsystem.

  Wraps `Hermes.Gateway.Registry` to expose a single entry point for listing,
  starting, stopping, and sending messages through connectors. The behaviour
  contract and registry semantics are ported from
  `../hermes-agent/gateway/platforms/base.py` and
  `../hermes-agent/gateway/platform_registry.py:172`.

  `send_message/4` is the middleware layer for authorization, approval, and
  streaming strategy selection. Connectors themselves are not modified; they
  continue to implement `Hermes.Gateway.Connector` callbacks.
  """

  alias Hermes.Gateway.Authz
  alias Hermes.Gateway.Registry
  alias Hermes.Gateway.Streaming

  @doc """
  Starts the connector identified by `name` with the given `config`.
  """
  @spec start_connector(atom(), map()) :: {:ok, pid()} | {:error, term()}
  defdelegate start_connector(name, config), to: Registry

  @doc """
  Stops the running connector identified by `name`.
  """
  @spec stop_connector(atom()) :: :ok | {:error, :not_running}
  defdelegate stop_connector(name), to: Registry

  @doc """
  Lists all registered connector entries.
  """
  @spec list_connectors() :: [Registry.entry()]
  defdelegate list_connectors, to: Registry

  @doc """
  Sends `message` to `session_id` through the running connector `name`.

  Before the message reaches the connector this function runs the gateway
  authorization gate and, when streaming is requested, routes the text
  through `Hermes.Gateway.Streaming` according to the connector's strategy.

  Options:
    * `:chat_id` – destination chat (required for streaming/authorization).
    * `:user_id` – originating user id (required for authorization).
    * `:streaming` – when `true`, treat `message` as a streaming delta.
    * `:final` – when `true` with `:streaming`, finalises the stream.
    * `:action` – action category for approval checks (default `:send_message`).
  """
  @spec send_message(atom(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def send_message(name, session_id, message, opts \\ []) do
    chat_id = Keyword.get(opts, :chat_id)
    user_id = Keyword.get(opts, :user_id)

    with :ok <- check_authz(name, user_id),
         :ok <- check_approval(name, session_id, message, opts) do
      if Keyword.get(opts, :streaming, false) do
        route_streaming(name, session_id, message, chat_id, opts)
      else
        do_send_message(name, session_id, message, opts)
      end
    end
  end

  defp check_authz(_name, nil), do: :ok

  defp check_authz(name, user_id) do
    if Authz.is_allowed?(name, to_string(user_id)) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp check_approval(name, session_id, message, opts) do
    action = Keyword.get(opts, :action, :send_message)

    if Authz.requires_approval?(name, action) do
      details = %{
        connector: name,
        action: action,
        message_preview: String.slice(to_string(message), 0, 200)
      }

      case Authz.request_approval(session_id, action, details) do
        {:ok, _approval_id} -> :ok
        {:denied, reason} -> {:error, {:approval_denied, reason}}
      end
    else
      :ok
    end
  end

  defp route_streaming(name, session_id, message, chat_id, opts) do
    strategy = Streaming.strategy_for(name)

    cond do
      Keyword.get(opts, :final, false) ->
        Streaming.finish(name, session_id, chat_id)

      strategy == :off ->
        Streaming.send_streaming(name, session_id, message, :off, chat_id)

      true ->
        Streaming.send_streaming(name, session_id, message, strategy, chat_id)
    end
  end

  defp do_send_message(name, session_id, message, opts) do
    case Registry.whereis(name) do
      nil ->
        {:error, :not_running}

      pid ->
        GenServer.call(pid, {:send_message, session_id, message, opts})
    end
  end
end
