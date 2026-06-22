defmodule Hermes.Gateway do
  @moduledoc """
  Public API for the gateway subsystem.

  Wraps `Hermes.Gateway.Registry` to expose a single entry point for listing,
  starting, stopping, and sending messages through connectors. The behaviour
  contract and registry semantics are ported from
  `../hermes-agent/gateway/platforms/base.py` and
  `../hermes-agent/gateway/platform_registry.py:172`.
  """

  alias Hermes.Gateway.Registry

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

  Returns the result of the connector's `send_message/3` callback.
  """
  @spec send_message(atom(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def send_message(name, session_id, message, opts \\ []) do
    case Registry.whereis(name) do
      nil ->
        {:error, :not_running}

      pid ->
        GenServer.call(pid, {:send_message, session_id, message, opts})
    end
  end
end
