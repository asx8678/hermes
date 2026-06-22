defmodule Hermes.Gateway.ConnectorTest do
  @moduledoc """
  Tests for `Hermes.Gateway` connector behaviour, registry, and supervisor.

  Verifies the port of `BasePlatformAdapter` lifecycle and `PlatformRegistry`
  semantics from `../hermes-agent/gateway/platforms/base.py` and
  `../hermes-agent/gateway/platform_registry.py:172`.
  """

  use ExUnit.Case, async: false

  alias Hermes.Gateway
  alias Hermes.Gateway.Registry, as: GatewayRegistry

  # ---------------------------------------------------------------------------
  # Mock connectors
  # ---------------------------------------------------------------------------

  defmodule MockConnector do
    use GenServer
    @behaviour Hermes.Gateway.Connector

    @impl Hermes.Gateway.Connector
    def name, do: :mock

    @impl Hermes.Gateway.Connector
    def label, do: "Mock"

    @impl Hermes.Gateway.Connector
    def start_link(config) do
      GenServer.start_link(__MODULE__, config)
    end

    @impl Hermes.Gateway.Connector
    def connect(state), do: {:ok, Map.put(state, :connected, true)}

    @impl Hermes.Gateway.Connector
    def disconnect(state), do: {:ok, Map.put(state, :connected, false)}

    @impl Hermes.Gateway.Connector
    def send_message(session_id, message, opts) do
      {:ok, %{session_id: session_id, message: message, opts: opts}}
    end

    @impl Hermes.Gateway.Connector
    def handle_inbound(message, state) do
      {:ok, Map.put(state, :last_inbound, message)}
    end

    @impl GenServer
    def init(config) do
      {:ok, Map.put(config, :messages, [])}
    end

    @impl GenServer
    def handle_call({:send_message, session_id, message, opts}, _from, state) do
      {:reply, send_message(session_id, message, opts), state}
    end
  end

  defmodule CrashyConnector do
    use GenServer
    @behaviour Hermes.Gateway.Connector

    @impl Hermes.Gateway.Connector
    def name, do: :crashy

    @impl Hermes.Gateway.Connector
    def label, do: "Crashy"

    @impl Hermes.Gateway.Connector
    def start_link(config), do: GenServer.start_link(__MODULE__, config)

    @impl Hermes.Gateway.Connector
    def connect(state), do: {:ok, state}

    @impl Hermes.Gateway.Connector
    def disconnect(state), do: {:ok, state}

    @impl Hermes.Gateway.Connector
    def send_message(_session_id, "boom", _opts), do: raise("intentional crash")

    def send_message(session_id, message, opts) do
      {:ok, %{session_id: session_id, message: message, opts: opts}}
    end

    @impl Hermes.Gateway.Connector
    def handle_inbound(_message, state), do: {:ok, state}

    @impl GenServer
    def init(config), do: {:ok, config}

    @impl GenServer
    def handle_call({:send_message, _session_id, "boom", _opts}, _from, _state) do
      raise "intentional crash"
    end

    def handle_call({:send_message, session_id, message, opts}, _from, state) do
      {:reply, send_message(session_id, message, opts), state}
    end
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    on_exit(fn ->
      Enum.each(GatewayRegistry.list_connectors(), fn entry ->
        Gateway.stop_connector(entry.name)
        GatewayRegistry.unregister(entry.name)
      end)
    end)

    :ok = GatewayRegistry.register(mock_entry())
    :ok = GatewayRegistry.register(crashy_entry())

    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "registration" do
    test "a registered connector appears in list_connectors/0" do
      connectors = Gateway.list_connectors()
      names = Enum.map(connectors, & &1.name)
      assert :mock in names
      assert :crashy in names
    end

    test "registering the same connector twice returns :already_registered" do
      assert {:error, :already_registered} = GatewayRegistry.register(mock_entry())
    end

    test "get/1 returns the entry or nil" do
      assert %GatewayRegistry{name: :mock} = GatewayRegistry.get(:mock)
      assert GatewayRegistry.get(:unknown) == nil
    end
  end

  describe "lifecycle" do
    test "start_connector starts a process under the supervisor" do
      assert {:ok, pid} = Gateway.start_connector(:mock, %{token: "x"})
      assert Process.alive?(pid)
    end

    test "stop_connector terminates the running connector" do
      assert {:ok, pid} = Gateway.start_connector(:mock, %{token: "x"})
      assert Process.alive?(pid)
      assert :ok = Gateway.stop_connector(:mock)
      assert Process.alive?(pid) == false
    end
  end

  describe "routing" do
    test "send_message routes to the correct connector module" do
      assert {:ok, _pid} = Gateway.start_connector(:mock, %{token: "x"})

      assert {:ok, result} =
               Gateway.send_message(:mock, "session-1", "hello", reply_to: "msg-1")

      assert result.session_id == "session-1"
      assert result.message == "hello"
      assert result.opts == [reply_to: "msg-1"]
    end

    test "send_message returns :not_running when connector is stopped" do
      assert {:error, :not_running} = Gateway.send_message(:mock, "s", "m")
    end
  end

  describe "fault isolation" do
    @tag :capture_log
    test "a crash in one connector does not affect other connectors" do
      assert {:ok, mock_pid} = Gateway.start_connector(:mock, %{token: "x"})
      assert {:ok, crashy_pid} = Gateway.start_connector(:crashy, %{token: "y"})

      assert Process.alive?(mock_pid)
      assert Process.alive?(crashy_pid)

      # Crashing the crashy connector should not bring down the mock connector.
      catch_exit(Gateway.send_message(:crashy, "s", "boom"))

      # Give the supervisor a moment to process the failure.
      Process.sleep(50)

      assert Process.alive?(mock_pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp mock_entry do
    %GatewayRegistry{
      name: :mock,
      label: "Mock",
      module: MockConnector,
      check_fn: fn -> true end,
      required_env: []
    }
  end

  defp crashy_entry do
    %GatewayRegistry{
      name: :crashy,
      label: "Crashy",
      module: CrashyConnector,
      check_fn: nil,
      required_env: ["CRASHY_TOKEN"]
    }
  end
end
