defmodule Hermes.Gateway.Connector do
  @moduledoc """
  Connector behaviour for gateway platform adapters.

  Ports the lifecycle contract of `BasePlatformAdapter` from
  `../hermes-agent/gateway/platforms/base.py` and the registry metadata from
  `../hermes-agent/gateway/platform_registry.py:172`.

  Specific adapters (for example Telegram in C2) implement this behaviour
  as a `GenServer` whose `start_link/1` is started under
  `Hermes.Gateway.Supervisor`. The callbacks define the minimal surface the
  gateway needs to drive a connector: identification, lifecycle, outbound
  messaging, and inbound message handling.
  """

  @doc """
  Returns the short atom identifier for this connector (e.g. `:telegram`).
  """
  @callback name() :: atom()

  @doc """
  Returns a human-readable label for this connector.
  """
  @callback label() :: String.t()

  @doc """
  Starts a connector process linked to the current process.

  Receives the platform-specific configuration map. This callback is invoked
  by `Hermes.Gateway.Supervisor.start_connector/2`.
  """
  @callback start_link(config :: map()) :: GenServer.on_start()

  @doc """
  Connects the adapter to its backing platform.

  Receives and returns the connector state. Called at the discretion of the
  implementing `GenServer`, typically from `init/1` or a dedicated connect call.
  """
  @callback connect(state :: term()) :: {:ok, term()} | {:error, term()}

  @doc """
  Disconnects the adapter from its backing platform.

  Receives and returns the connector state. Called at the discretion of the
  implementing `GenServer`, typically from `terminate/2`.
  """
  @callback disconnect(state :: term()) :: {:ok, term()}

  @doc """
  Sends an outbound message through the connector.

  The implementing `GenServer` usually exposes this through a `handle_call/3`
  handler invoked by `Hermes.Gateway.send_message/4`.
  """
  @callback send_message(session_id :: String.t(), message :: String.t(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Handles an inbound message event from the backing platform.

  Receives and returns the connector state. Called at the discretion of the
  implementing `GenServer` when the platform delivers a new message.
  """
  @callback handle_inbound(message :: map(), state :: term()) ::
              {:ok, term()} | {:error, term()}
end
