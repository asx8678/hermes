defmodule Hermes.Gateway.WebhookTest do
  @moduledoc """
  Tests for `Hermes.Gateway.Webhook` Plug.

  Registers a mock connector in `Hermes.Gateway.Registry`, issues Plug test
  requests, and verifies routing, missing connectors, handler failures, and
  HTTP method handling.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias Hermes.Gateway.Registry, as: GatewayRegistry
  alias Hermes.Gateway.Webhook

  defmodule MockConnector do
    use GenServer
    @behaviour Hermes.Gateway.Connector

    @impl Hermes.Gateway.Connector
    def name, do: :telegram

    @impl Hermes.Gateway.Connector
    def label, do: "Mock Telegram"

    @impl Hermes.Gateway.Connector
    def start_link(config), do: GenServer.start_link(__MODULE__, config)

    @impl Hermes.Gateway.Connector
    def connect(state), do: {:ok, state}

    @impl Hermes.Gateway.Connector
    def disconnect(state), do: {:ok, state}

    @impl Hermes.Gateway.Connector
    def send_message(_session_id, _message, _opts), do: {:ok, %{}}

    @impl Hermes.Gateway.Connector
    def handle_inbound(_message, state), do: {:ok, state}

    @impl GenServer
    def init(config), do: {:ok, Map.put(config, :mode, :ok)}

    @impl GenServer
    def handle_call({:handle_inbound, _payload}, _from, %{mode: :error} = state) do
      {:reply, {:error, "boom"}, state}
    end

    def handle_call({:handle_inbound, payload}, _from, state) do
      {:reply, {:ok, payload}, state}
    end
  end

  defmodule FailingConnector do
    use GenServer
    @behaviour Hermes.Gateway.Connector

    @impl Hermes.Gateway.Connector
    def name, do: :failing

    @impl Hermes.Gateway.Connector
    def label, do: "Failing"

    @impl Hermes.Gateway.Connector
    def start_link(config), do: GenServer.start_link(__MODULE__, config)

    @impl Hermes.Gateway.Connector
    def connect(state), do: {:ok, state}

    @impl Hermes.Gateway.Connector
    def disconnect(state), do: {:ok, state}

    @impl Hermes.Gateway.Connector
    def send_message(_session_id, _message, _opts), do: {:ok, %{}}

    @impl Hermes.Gateway.Connector
    def handle_inbound(_message, state), do: {:ok, state}

    @impl GenServer
    def init(config), do: {:ok, config}

    @impl GenServer
    def handle_call({:handle_inbound, _payload}, _from, state) do
      {:reply, {:error, "handler_failed"}, state}
    end
  end

  setup do
    on_exit(fn ->
      Enum.each(GatewayRegistry.list_connectors(), fn entry ->
        pid = GatewayRegistry.whereis(entry.name)

        if is_pid(pid) and Process.alive?(pid) do
          GatewayRegistry.stop_connector(entry.name)
        end

        GatewayRegistry.unregister(entry.name)
      end)
    end)

    # Clean up any stale registrations left by other tests.
    GatewayRegistry.unregister(:telegram)
    GatewayRegistry.unregister(:failing)

    :ok = GatewayRegistry.register(telegram_entry())
    :ok = GatewayRegistry.register(failing_entry())
    {:ok, _pid} = GatewayRegistry.start_connector(:telegram, %{})
    {:ok, _pid} = GatewayRegistry.start_connector(:failing, %{})

    :ok
  end

  describe "POST routing" do
    test "POST /telegram with valid payload returns 200" do
      conn = conn(:post, "/webhook/telegram", %{"update_id" => 1})
      conn = Webhook.call(conn, [])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "ok"
    end

    test "POST to unknown connector returns 404" do
      conn = conn(:post, "/webhook/unknown-connector", %{"x" => 1})
      conn = Webhook.call(conn, [])

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] == "connector_not_found"
    end

    test "POST when handler returns {:error, reason} returns 500" do
      conn = conn(:post, "/webhook/failing", %{"x" => 1})
      conn = Webhook.call(conn, [])

      assert conn.status == 500
      assert Jason.decode!(conn.resp_body)["error"] == "handler_failed"
    end
  end

  describe "method handling" do
    test "GET request routes through the connector" do
      # The webhook does not restrict methods; GET is treated as a valid
      # webhook delivery and routed to the registered connector.
      conn = conn(:get, "/webhook/telegram", %{"x" => 1})
      conn = Webhook.call(conn, [])

      assert conn.status == 200
    end
  end

  describe "payload handling" do
    test "empty body routes with empty payload" do
      conn = conn(:post, "/webhook/telegram", "")
      conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")
      conn = Webhook.call(conn, [])

      assert conn.status == 200
    end
  end

  defp telegram_entry do
    %GatewayRegistry{
      name: :telegram,
      label: "Mock Telegram",
      module: MockConnector,
      check_fn: fn -> true end,
      required_env: []
    }
  end

  defp failing_entry do
    %GatewayRegistry{
      name: :failing,
      label: "Failing",
      module: FailingConnector,
      check_fn: fn -> true end,
      required_env: []
    }
  end
end
