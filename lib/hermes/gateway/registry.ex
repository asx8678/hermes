defmodule Hermes.Gateway.Registry do
  @moduledoc """
  Connector registry and process tracker.

  Ports `PlatformRegistry` from `../hermes-agent/gateway/platform_registry.py:172`.
  Stores connector metadata (name, label, implementing module, dependency check,
  required environment variables) and tracks the PID of each running connector
  so the public API can route calls to the correct process.

  A monitor is installed on every started connector; when it crashes its entry
  is removed from the active PID map automatically.
  """

  use GenServer

  defstruct [:name, :label, :module, :check_fn, :required_env]

  @type entry :: %__MODULE__{
          name: atom(),
          label: String.t(),
          module: module(),
          check_fn: (-> boolean()) | nil,
          required_env: [String.t()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    {:ok, %{entries: %{}, pids: %{}, monitors: %{}}}
  end

  @doc """
  Registers a connector entry.

  Returns `:ok` on success or `{:error, :already_registered}` if an entry
  with the same name already exists.
  """
  @spec register(map() | entry()) :: :ok | {:error, :already_registered}
  def register(%__MODULE__{} = entry) do
    GenServer.call(__MODULE__, {:register, entry})
  end

  def register(entry) when is_map(entry) do
    entry = struct!(__MODULE__, entry)
    GenServer.call(__MODULE__, {:register, entry})
  end

  @doc """
  Returns the registered entry for `name`, or `nil` if not registered.
  """
  @spec get(atom()) :: entry() | nil
  def get(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @doc """
  Lists all registered connector entries.
  """
  @spec list_connectors() :: [entry()]
  def list_connectors do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Unregisters a connector entry.
  """
  @spec unregister(atom()) :: :ok
  def unregister(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  @doc """
  Starts the connector identified by `name` under `Hermes.Gateway.Supervisor`
  using `config`.

  Returns `{:ok, pid}` on success, `{:error, :not_found}` if the connector is
  not registered, or another error from the supervisor.
  """
  @spec start_connector(atom(), map()) :: {:ok, pid()} | {:error, term()}
  def start_connector(name, config) when is_atom(name) and is_map(config) do
    GenServer.call(__MODULE__, {:start_connector, name, config})
  end

  @doc """
  Stops the running connector identified by `name`.
  """
  @spec stop_connector(atom()) :: :ok | {:error, :not_running}
  def stop_connector(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:stop_connector, name})
  end

  @doc """
  Returns the PID of the running connector identified by `name`, or `nil`.
  """
  @spec whereis(atom()) :: pid() | nil
  def whereis(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:whereis, name})
  end

  @impl true
  def handle_call({:register, entry}, _from, state) do
    if Map.has_key?(state.entries, entry.name) do
      {:reply, {:error, :already_registered}, state}
    else
      {:reply, :ok, %{state | entries: Map.put(state.entries, entry.name, entry)}}
    end
  end

  def handle_call({:get, name}, _from, state) do
    {:reply, state.entries[name], state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.entries), state}
  end

  def handle_call({:unregister, name}, _from, state) do
    entries = Map.delete(state.entries, name)
    {:reply, :ok, %{state | entries: entries}}
  end

  def handle_call({:start_connector, name, config}, _from, state) do
    case Map.fetch(state.entries, name) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, entry} ->
        if entry.check_fn != nil and not entry.check_fn.() do
          {:reply, {:error, :requirements_not_met}, state}
        else
          case Hermes.Gateway.Supervisor.start_connector(entry.module, config) do
            {:ok, pid} = ok ->
              ref = Process.monitor(pid)

              new_state = %{
                state
                | pids: Map.put(state.pids, name, pid),
                  monitors: Map.put(state.monitors, ref, name)
              }

              {:reply, ok, new_state}

            error ->
              {:reply, error, state}
          end
        end
    end
  end

  def handle_call({:stop_connector, name}, _from, state) do
    case Map.pop(state.pids, name) do
      {nil, _} ->
        {:reply, {:error, :not_running}, state}

      {pid, pids} ->
        Hermes.Gateway.Supervisor.stop_connector(pid)
        ref = find_ref(state.monitors, name)
        Process.demonitor(ref, [:flush])
        monitors = Map.delete(state.monitors, ref)
        {:reply, :ok, %{state | pids: pids, monitors: monitors}}
    end
  end

  def handle_call({:whereis, name}, _from, state) do
    {:reply, state.pids[name], state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {name, monitors} = Map.pop(state.monitors, ref)
    pids = if name, do: Map.delete(state.pids, name), else: state.pids
    {:noreply, %{state | pids: pids, monitors: monitors}}
  end

  defp find_ref(monitors, name) do
    Enum.find_value(monitors, fn {ref, n} -> if n == name, do: ref end)
  end
end
