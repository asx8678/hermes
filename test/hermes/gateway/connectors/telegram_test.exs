defmodule Hermes.Gateway.Connectors.TelegramTest do
  @moduledoc """
  Tests for `Hermes.Gateway.Connectors.Telegram`.

  Verifies the connector end-to-end: registration, lifecycle, outbound
  messaging, inbound update routing, and per-session isolation. All Telegram
  Bot API calls are mocked through `Hermes.Test.MockTelegramBot`.
  """

  use Hermes.DataCase, async: false

  alias Hermes.Gateway
  alias Hermes.Gateway.Connectors.Telegram
  alias Hermes.Gateway.Registry, as: GatewayRegistry
  alias Hermes.Providers.Types.NormalizedResponse
  alias Hermes.Sessions.SessionServer
  alias Hermes.Test.MockProvider
  alias Hermes.Test.MockTelegramBot

  setup do
    ensure_registry_started()
    start_supervised!(MockTelegramBot)
    start_supervised!(MockProvider)
    MockTelegramBot.reset()
    MockProvider.reset()

    on_exit(fn ->
      Enum.each(GatewayRegistry.list_connectors(), fn entry ->
        Gateway.stop_connector(entry.name)
        GatewayRegistry.unregister(entry.name)
      end)
    end)

    :ok
  end

  describe "registration" do
    test "telegram connector is registered on app start" do
      entry = GatewayRegistry.get(:telegram)
      assert entry.name == :telegram
      assert entry.label == "Telegram"
      assert entry.module == Telegram
      assert entry.required_env == ["TELEGRAM_BOT_TOKEN"]
    end

    test "telegram connector appears in list_connectors/0" do
      connectors = Gateway.list_connectors()
      assert Enum.any?(connectors, &(&1.name == :telegram))
    end
  end

  describe "lifecycle" do
    test "start_link with valid config stays alive" do
      MockTelegramBot.push_response(:get_me, {:ok, %{"ok" => true, "result" => %{}}})

      assert {:ok, pid} =
               Telegram.start_link(
                 bot_token: "test-token",
                 bot_api: MockTelegramBot,
                 poll_interval_ms: 1_000
               )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "start_link with missing bot_token stops with :missing_bot_token" do
      Process.flag(:trap_exit, true)

      assert {:error, :missing_bot_token} =
               Telegram.start_link([])
    end

    test "connect/1 fails when getMe fails" do
      Process.flag(:trap_exit, true)
      MockTelegramBot.push_response(:get_me, {:error, "unauthorized"})

      assert {:error, "unauthorized"} =
               Telegram.start_link(
                 bot_token: "bad-token",
                 bot_api: MockTelegramBot,
                 poll_interval_ms: 1_000
               )
    end
  end

  describe "outbound messaging" do
    test "send_message routes through the Bot API with the correct chat_id" do
      MockTelegramBot.push_response(:get_me, {:ok, %{"ok" => true, "result" => %{}}})

      MockTelegramBot.push_response(
        :send_message,
        {:ok, %{"ok" => true, "result" => %{"message_id" => 42}}}
      )

      {:ok, pid} =
        Telegram.start_link(
          bot_token: "test-token",
          bot_api: MockTelegramBot,
          poll_interval_ms: 1_000
        )

      assert {:ok, %{"ok" => true}} =
               GenServer.call(pid, {:send_message, "session-1", "hello", chat_id: 12345})

      assert Enum.any?(MockTelegramBot.calls(), fn
               {:send_message, ["test-token", 12345, "hello", [chat_id: 12345]]} -> true
               _ -> false
             end)

      GenServer.stop(pid)
    end
  end

  describe "inbound routing" do
    test "inbound message creates a session and triggers a turn" do
      chat_id = 99_999
      session_id = "telegram:#{chat_id}"

      MockTelegramBot.push_response(:get_me, {:ok, %{"ok" => true, "result" => %{}}})

      MockTelegramBot.push_response(:get_updates, {
        :ok,
        [
          %{
            "update_id" => 1,
            "message" => %{
              "message_id" => 100,
              "chat" => %{"id" => chat_id, "type" => "private"},
              "from" => %{"id" => chat_id, "username" => "tester"},
              "text" => "hi there"
            }
          }
        ]
      })

      MockProvider.enqueue(%NormalizedResponse{
        content: "Hello back",
        finish_reason: "stop",
        tool_calls: nil
      })

      {:ok, pid} =
        Telegram.start_link(
          bot_token: "test-token",
          bot_api: MockTelegramBot,
          session_provider: MockProvider,
          poll_interval_ms: 0
        )

      # Give the zero-delay poll, session creation, turn loop, and PubSub
      # round-trip time to complete.
      assert_eventually(fn ->
        SessionServer.whereis(session_id) != nil and
          Enum.any?(MockTelegramBot.calls(), fn
            {:send_message, ["test-token", ^chat_id, "Hello back", []]} -> true
            _ -> false
          end)
      end)

      GenServer.stop(pid)
    end

    test "per-session isolation: different chat_ids get different sessions" do
      chat_id_a = 100_001
      chat_id_b = 100_002
      session_id_a = "telegram:#{chat_id_a}"
      session_id_b = "telegram:#{chat_id_b}"

      MockTelegramBot.push_response(:get_me, {:ok, %{"ok" => true, "result" => %{}}})

      MockTelegramBot.push_response(:get_updates, {
        :ok,
        [
          %{
            "update_id" => 1,
            "message" => %{
              "message_id" => 100,
              "chat" => %{"id" => chat_id_a, "type" => "private"},
              "from" => %{"id" => chat_id_a, "username" => "user_a"},
              "text" => "message A"
            }
          },
          %{
            "update_id" => 2,
            "message" => %{
              "message_id" => 101,
              "chat" => %{"id" => chat_id_b, "type" => "private"},
              "from" => %{"id" => chat_id_b, "username" => "user_b"},
              "text" => "message B"
            }
          }
        ]
      })

      MockProvider.enqueue(%NormalizedResponse{
        content: "Reply A",
        finish_reason: "stop",
        tool_calls: nil
      })

      MockProvider.enqueue(%NormalizedResponse{
        content: "Reply B",
        finish_reason: "stop",
        tool_calls: nil
      })

      {:ok, pid} =
        Telegram.start_link(
          bot_token: "test-token",
          bot_api: MockTelegramBot,
          session_provider: MockProvider,
          poll_interval_ms: 0
        )

      assert_eventually(fn ->
        pid_a = SessionServer.whereis(session_id_a)
        pid_b = SessionServer.whereis(session_id_b)

        pid_a != nil and pid_b != nil and pid_a != pid_b and
          Enum.count(MockTelegramBot.calls(), fn
            {:send_message, _} -> true
            _ -> false
          end) == 2
      end)

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ensure_registry_started do
    # The application normally starts the registry; this guards against tests
    # run in isolation where the registry may have been unregistered by a
    # previous test's on_exit callback.
    if GatewayRegistry.get(:telegram) == nil do
      :ok =
        GatewayRegistry.register(%{
          name: :telegram,
          label: "Telegram",
          module: Telegram,
          check_fn: fn -> true end,
          required_env: ["TELEGRAM_BOT_TOKEN"]
        })
    end

    :ok
  end

  defp assert_eventually(assertion, retries \\ 50, delay_ms \\ 100) do
    if retries <= 0 do
      flunk("assert_eventually timed out")
    else
      if assertion.() do
        :ok
      else
        Process.sleep(delay_ms)
        assert_eventually(assertion, retries - 1, delay_ms)
      end
    end
  end
end
