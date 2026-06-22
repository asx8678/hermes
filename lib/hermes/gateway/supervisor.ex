defmodule Hermes.Gateway.Supervisor do
  @moduledoc """
  DynamicSupervisor for connector processes.

  Each connector runs under its own supervised process so a crash in one
  connector cannot bring down other connectors or the gateway. This mirrors
  the per-session task isolation described in
  `../hermes-agent/gateway/platforms/base.py:2078`.

  The supervisor uses a `:one_for_one` strategy: a failing connector is
  restarted independently of its siblings.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts `module` under the supervisor with the given `config`.
  """
  @spec start_connector(module(), map()) :: DynamicSupervisor.on_start_child()
  def start_connector(module, config) when is_atom(module) and is_map(config) do
    spec = Map.merge(module.child_spec(config), %{restart: :transient})
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Stops a running connector by PID.
  """
  @spec stop_connector(pid()) :: :ok
  def stop_connector(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(__MODULE__, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
