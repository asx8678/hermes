defmodule Hermes.Gateway.Connectors.ConnectorsTest do
  @moduledoc """
  Tests for the remaining Tier-1 gateway connectors.

  Verifies registration, lifecycle, outbound messaging, and inbound routing for
  Discord, Slack, WhatsApp, Signal, Email, and Feishu. All platform API calls
  are mocked through the platform-specific test doubles that delegate to
  `Hermes.Test.MockGatewayClient`.
  """

  use ExUnit.Case, async: false

  alias Hermes.Gateway
  alias Hermes.Gateway.Connectors.Discord
  alias Hermes.Gateway.Connectors.Email
  alias Hermes.Gateway.Connectors.Feishu
  alias Hermes.Gateway.Connectors.Signal
  alias Hermes.Gateway.Connectors.Slack
  alias Hermes.Gateway.Connectors.WhatsApp
  alias Hermes.Gateway.Registry, as: GatewayRegistry
  alias Hermes.Providers.Types.NormalizedResponse
  alias Hermes.Sessions.SessionServer
  alias Hermes.Test.MockDiscordBot
  alias Hermes.Test.MockEmailClient
  alias Hermes.Test.MockFeishuBot
  alias Hermes.Test.MockGatewayClient
  alias Hermes.Test.MockProvider
  alias Hermes.Test.MockSignalCli
  alias Hermes.Test.MockSlackBot
  alias Hermes.Test.MockWhatsAppCloud

  setup do
    ensure_registry_started()
    start_supervised!(MockGatewayClient)
    start_supervised!(MockProvider)
    MockGatewayClient.reset()
    MockProvider.reset()

    on_exit(fn ->
      Enum.each(GatewayRegistry.list_connectors(), fn entry ->
        Gateway.stop_connector(entry.name)
        GatewayRegistry.unregister(entry.name)
      end)
    end)

    :ok
  end

  # ===========================================================================
  # Discord
  # ===========================================================================

  describe "discord connector" do
    test "registered in gateway registry" do
      entry = GatewayRegistry.get(:discord)
      assert entry.name == :discord
      assert entry.label == "Discord"
      assert entry.module == Discord
      assert entry.required_env == ["DISCORD_BOT_TOKEN"]
    end

    test "start_link with valid config stays alive" do
      MockGatewayClient.push_response(
        :discord,
        :get_current_user,
        {:ok, %{"id" => "bot-1", "username" => "test-bot"}}
      )

      assert {:ok, pid} =
               Discord.start_link(
                 bot_token: "test-token",
                 bot_api: MockDiscordBot
               )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "start_link with missing bot_token stops with :missing_bot_token" do
      Process.flag(:trap_exit, true)
      assert {:error, :missing_bot_token} = Discord.start_link([])
    end

    test "send_message routes through the API with the correct channel_id" do
      MockGatewayClient.push_response(
        :discord,
        :get_current_user,
        {:ok, %{"id" => "bot-1"}}
      )

      MockGatewayClient.push_response(
        :discord,
        :send_message,
        {:ok, %{"id" => "msg-1"}}
      )

      {:ok, pid} = Discord.start_link(bot_token: "test-token", bot_api: MockDiscordBot)

      assert {:ok, %{"id" => "msg-1"}} =
               GenServer.call(pid, {:send_message, "session-1", "hello", channel_id: "C123"})

      assert Enum.any?(MockGatewayClient.calls(), fn
               {{:discord, :send_message}, ["test-token", "C123", "hello", [channel_id: "C123"]]} ->
                 true

               _ ->
                 false
             end)

      GenServer.stop(pid)
    end

    test "inbound MESSAGE_CREATE creates a session and triggers a turn" do
      channel_id = "C999"
      session_id = "discord:#{channel_id}"

      MockGatewayClient.push_response(
        :discord,
        :get_current_user,
        {:ok, %{"id" => "bot-1"}}
      )

      MockGatewayClient.push_response(
        :discord,
        :send_message,
        {:ok, %{"id" => "reply-1"}}
      )

      MockProvider.enqueue(%NormalizedResponse{
        content: "Hello back",
        finish_reason: "stop",
        tool_calls: nil
      })

      {:ok, pid} =
        Discord.start_link(
          bot_token: "test-token",
          bot_api: MockDiscordBot,
          session_provider: MockProvider
        )

      payload = %{
        "type" => "MESSAGE_CREATE",
        "channel_id" => channel_id,
        "content" => "hi there",
        "author" => %{"id" => "U999", "username" => "tester"}
      }

      :ok = GenServer.call(pid, {:handle_inbound, payload})

      assert_eventually(fn ->
        SessionServer.whereis(session_id) != nil and
          Enum.any?(MockGatewayClient.calls(), fn
            {{:discord, :send_message}, ["test-token", ^channel_id, "Hello back", []]} ->
              true

            _ ->
              false
          end)
      end)

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # Slack
  # ===========================================================================

  describe "slack connector" do
    test "registered in gateway registry" do
      entry = GatewayRegistry.get(:slack)
      assert entry.name == :slack
      assert entry.label == "Slack"
      assert entry.module == Slack
      assert entry.required_env == ["SLACK_BOT_TOKEN"]
    end

    test "start_link with valid config stays alive" do
      MockGatewayClient.push_response(:slack, :auth_test, {:ok, %{"ok" => true}})

      assert {:ok, pid} =
               Slack.start_link(
                 bot_token: "test-token",
                 bot_api: MockSlackBot
               )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "start_link with missing bot_token stops with :missing_bot_token" do
      Process.flag(:trap_exit, true)
      assert {:error, :missing_bot_token} = Slack.start_link([])
    end

    test "send_message routes through the API with the correct channel" do
      MockGatewayClient.push_response(:slack, :auth_test, {:ok, %{"ok" => true}})

      MockGatewayClient.push_response(
        :slack,
        :send_message,
        {:ok, %{"ok" => true, "ts" => "1234.5678"}}
      )

      {:ok, pid} = Slack.start_link(bot_token: "test-token", bot_api: MockSlackBot)

      assert {:ok, %{"ok" => true}} =
               GenServer.call(pid, {:send_message, "session-1", "hello", channel: "C123"})

      assert Enum.any?(MockGatewayClient.calls(), fn
               {{:slack, :send_message}, ["test-token", "C123", "hello", [channel: "C123"]]} ->
                 true

               _ ->
                 false
             end)

      GenServer.stop(pid)
    end

    test "inbound message event creates a session and triggers a turn" do
      channel = "C888"
      session_id = "slack:#{channel}"

      MockGatewayClient.push_response(:slack, :auth_test, {:ok, %{"ok" => true}})

      MockGatewayClient.push_response(
        :slack,
        :send_message,
        {:ok, %{"ok" => true}}
      )

      MockProvider.enqueue(%NormalizedResponse{
        content: "Slack reply",
        finish_reason: "stop",
        tool_calls: nil
      })

      {:ok, pid} =
        Slack.start_link(
          bot_token: "test-token",
          bot_api: MockSlackBot,
          session_provider: MockProvider
        )

      payload = %{
        "event" => %{
          "type" => "message",
          "channel" => channel,
          "user" => "U888",
          "text" => "hi slack"
        }
      }

      :ok = GenServer.call(pid, {:handle_inbound, payload})

      assert_eventually(fn ->
        SessionServer.whereis(session_id) != nil and
          Enum.any?(MockGatewayClient.calls(), fn
            {{:slack, :send_message}, ["test-token", ^channel, "Slack reply", []]} -> true
            _ -> false
          end)
      end)

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # WhatsApp
  # ===========================================================================

  describe "whatsapp connector" do
    test "registered in gateway registry" do
      entry = GatewayRegistry.get(:whatsapp)
      assert entry.name == :whatsapp
      assert entry.label == "WhatsApp"
      assert entry.module == WhatsApp
      assert entry.required_env == ["WHATSAPP_TOKEN", "WHATSAPP_PHONE_NUMBER_ID"]
    end

    test "start_link with valid config stays alive" do
      assert {:ok, pid} =
               WhatsApp.start_link(
                 token: "test-token",
                 phone_number_id: "123456789",
                 bot_api: MockWhatsAppCloud
               )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "start_link with missing config stops with {:missing_config, _}" do
      Process.flag(:trap_exit, true)
      assert {:error, {:missing_config, missing}} = WhatsApp.start_link([])
      assert :token in missing
      assert :phone_number_id in missing
    end

    test "send_message routes through the API with the correct recipient" do
      MockGatewayClient.push_response(
        :whatsapp,
        :send_message,
        {:ok, %{"messages" => [%{"id" => "wamid-1"}]}}
      )

      {:ok, pid} =
        WhatsApp.start_link(
          token: "test-token",
          phone_number_id: "123456789",
          bot_api: MockWhatsAppCloud
        )

      assert {:ok, %{"messages" => _}} =
               GenServer.call(pid, {:send_message, "session-1", "hello", to: "15551234567"})

      assert Enum.any?(MockGatewayClient.calls(), fn
               {{:whatsapp, :send_message},
                ["test-token", "123456789", "15551234567", "hello", [to: "15551234567"]]} ->
                 true

               _ ->
                 false
             end)

      GenServer.stop(pid)
    end

    test "inbound webhook payload creates a session and triggers a turn" do
      from = "15551234567"
      session_id = "whatsapp:#{from}"

      MockGatewayClient.push_response(
        :whatsapp,
        :send_message,
        {:ok, %{"messages" => [%{"id" => "wamid-reply"}]}}
      )

      MockProvider.enqueue(%NormalizedResponse{
        content: "WhatsApp reply",
        finish_reason: "stop",
        tool_calls: nil
      })

      {:ok, pid} =
        WhatsApp.start_link(
          token: "test-token",
          phone_number_id: "123456789",
          bot_api: MockWhatsAppCloud,
          session_provider: MockProvider
        )

      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [
                    %{
                      "from" => from,
                      "text" => %{"body" => "hi whatsapp"}
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      :ok = GenServer.call(pid, {:handle_inbound, payload})

      assert_eventually(fn ->
        SessionServer.whereis(session_id) != nil and
          Enum.any?(MockGatewayClient.calls(), fn
            {{:whatsapp, :send_message}, ["test-token", "123456789", ^from, "WhatsApp reply", []]} ->
              true

            _ ->
              false
          end)
      end)

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # Signal
  # ===========================================================================

  describe "signal connector" do
    test "registered in gateway registry" do
      entry = GatewayRegistry.get(:signal)
      assert entry.name == :signal
      assert entry.label == "Signal"
      assert entry.module == Signal
      assert entry.required_env == ["SIGNAL_PHONE_NUMBER", "SIGNAL_API_URL"]
    end

    test "start_link with valid config stays alive" do
      assert {:ok, pid} =
               Signal.start_link(
                 phone_number: "+1234567890",
                 api_url: "http://localhost:8080",
                 client: MockSignalCli,
                 poll_interval_ms: 1_000
               )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "start_link with missing config stops with {:missing_config, _}" do
      Process.flag(:trap_exit, true)
      assert {:error, {:missing_config, missing}} = Signal.start_link([])
      assert :phone_number in missing
      assert :api_url in missing
    end

    test "send_message routes through the client with the correct recipient" do
      MockGatewayClient.push_response(:signal, :send_message, {:ok, %{"sent" => true}})

      {:ok, pid} =
        Signal.start_link(
          phone_number: "+1234567890",
          api_url: "http://localhost:8080",
          client: MockSignalCli
        )

      assert {:ok, %{"sent" => true}} =
               GenServer.call(
                 pid,
                 {:send_message, "session-1", "hello", recipient: "+0987654321"}
               )

      assert Enum.any?(MockGatewayClient.calls(), fn
               {{:signal, :send_message},
                [
                  "+1234567890",
                  "http://localhost:8080",
                  "+0987654321",
                  "hello",
                  [recipient: "+0987654321"]
                ]} ->
                 true

               _ ->
                 false
             end)

      GenServer.stop(pid)
    end

    test "inbound polled message creates a session and triggers a turn" do
      from = "+15550000000"
      session_id = "signal:#{from}"

      MockGatewayClient.push_response(
        :signal,
        :get_messages,
        {:ok, [%{"sourceNumber" => from, "dataMessage" => %{"message" => "hi signal"}}]}
      )

      MockGatewayClient.push_response(
        :signal,
        :send_message,
        {:ok, %{"sent" => true}}
      )

      MockProvider.enqueue(%NormalizedResponse{
        content: "Signal reply",
        finish_reason: "stop",
        tool_calls: nil
      })

      {:ok, pid} =
        Signal.start_link(
          phone_number: "+1234567890",
          api_url: "http://localhost:8080",
          client: MockSignalCli,
          session_provider: MockProvider,
          poll_interval_ms: 0
        )

      assert_eventually(fn ->
        SessionServer.whereis(session_id) != nil and
          Enum.any?(MockGatewayClient.calls(), fn
            {{:signal, :send_message},
             ["+1234567890", "http://localhost:8080", ^from, "Signal reply", []]} ->
              true

            _ ->
              false
          end)
      end)

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # Email
  # ===========================================================================

  describe "email connector" do
    test "registered in gateway registry" do
      entry = GatewayRegistry.get(:email)
      assert entry.name == :email
      assert entry.label == "Email"
      assert entry.module == Email

      assert entry.required_env == [
               "IMAP_HOST",
               "IMAP_USER",
               "IMAP_PASSWORD",
               "SMTP_HOST",
               "SMTP_USER",
               "SMTP_PASSWORD"
             ]
    end

    test "start_link with valid config stays alive" do
      assert {:ok, pid} =
               Email.start_link(
                 imap_host: "imap.example.com",
                 imap_user: "in@example.com",
                 imap_password: "secret",
                 smtp_host: "smtp.example.com",
                 smtp_user: "out@example.com",
                 smtp_password: "secret",
                 client: MockEmailClient,
                 poll_interval_ms: 1_000
               )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "start_link with missing config stops with {:missing_config, _}" do
      Process.flag(:trap_exit, true)
      assert {:error, {:missing_config, missing}} = Email.start_link([])
      assert :imap_host in missing
      assert :smtp_password in missing
    end

    test "send_message routes through the client with the correct recipient" do
      MockGatewayClient.push_response(
        :email,
        :send_email,
        {:ok, %{"sent" => true}}
      )

      {:ok, pid} =
        Email.start_link(
          imap_host: "imap.example.com",
          imap_user: "in@example.com",
          imap_password: "secret",
          smtp_host: "smtp.example.com",
          smtp_user: "out@example.com",
          smtp_password: "secret",
          client: MockEmailClient
        )

      assert {:ok, %{"sent" => true}} =
               GenServer.call(
                 pid,
                 {:send_message, "session-1", "hello", to: "friend@example.com"}
               )

      assert Enum.any?(MockGatewayClient.calls(), fn
               {{:email, :send_email},
                [
                  "smtp.example.com",
                  "out@example.com",
                  "secret",
                  "friend@example.com",
                  "Re:",
                  "hello",
                  [to: "friend@example.com"]
                ]} ->
                 true

               _ ->
                 false
             end)

      GenServer.stop(pid)
    end

    test "inbound polled message creates a session and triggers a turn" do
      from = "sender@example.com"
      session_id = "email:#{from}"

      MockGatewayClient.push_response(
        :email,
        :check_imap,
        {:ok, [%{"from" => from, "body" => "hi email"}]}
      )

      MockGatewayClient.push_response(
        :email,
        :send_email,
        {:ok, %{"sent" => true}}
      )

      MockProvider.enqueue(%NormalizedResponse{
        content: "Email reply",
        finish_reason: "stop",
        tool_calls: nil
      })

      {:ok, pid} =
        Email.start_link(
          imap_host: "imap.example.com",
          imap_user: "in@example.com",
          imap_password: "secret",
          smtp_host: "smtp.example.com",
          smtp_user: "out@example.com",
          smtp_password: "secret",
          client: MockEmailClient,
          session_provider: MockProvider,
          poll_interval_ms: 0
        )

      assert_eventually(fn ->
        SessionServer.whereis(session_id) != nil and
          Enum.any?(MockGatewayClient.calls(), fn
            {{:email, :send_email},
             [
               "smtp.example.com",
               "out@example.com",
               "secret",
               ^from,
               "Re:",
               "Email reply",
               []
             ]} ->
              true

            _ ->
              false
          end)
      end)

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # Feishu
  # ===========================================================================

  describe "feishu connector" do
    test "registered in gateway registry" do
      entry = GatewayRegistry.get(:feishu)
      assert entry.name == :feishu
      assert entry.label == "Feishu"
      assert entry.module == Feishu
      assert entry.required_env == ["FEISHU_APP_ID", "FEISHU_APP_SECRET"]
    end

    test "start_link with valid config stays alive" do
      MockGatewayClient.push_response(
        :feishu,
        :get_tenant_access_token,
        {:ok, %{"tenant_access_token" => "token-1"}}
      )

      assert {:ok, pid} =
               Feishu.start_link(
                 app_id: "app-1",
                 app_secret: "secret-1",
                 bot_api: MockFeishuBot
               )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "start_link with missing config stops with {:missing_config, _}" do
      Process.flag(:trap_exit, true)
      assert {:error, {:missing_config, missing}} = Feishu.start_link([])
      assert :app_id in missing
      assert :app_secret in missing
    end

    test "send_message routes through the API with the correct chat_id" do
      MockGatewayClient.push_response(
        :feishu,
        :get_tenant_access_token,
        {:ok, %{"tenant_access_token" => "token-1"}}
      )

      MockGatewayClient.push_response(
        :feishu,
        :send_message,
        {:ok, %{"code" => 0}}
      )

      {:ok, pid} =
        Feishu.start_link(app_id: "app-1", app_secret: "secret-1", bot_api: MockFeishuBot)

      assert {:ok, %{"code" => 0}} =
               GenServer.call(pid, {:send_message, "session-1", "hello", chat_id: "oc_123"})

      assert Enum.any?(MockGatewayClient.calls(), fn
               {{:feishu, :send_message}, ["token-1", "oc_123", "hello", [chat_id: "oc_123"]]} ->
                 true

               _ ->
                 false
             end)

      GenServer.stop(pid)
    end

    test "inbound event creates a session and triggers a turn" do
      chat_id = "oc_999"
      session_id = "feishu:#{chat_id}"

      MockGatewayClient.push_response(
        :feishu,
        :get_tenant_access_token,
        {:ok, %{"tenant_access_token" => "token-1"}}
      )

      MockGatewayClient.push_response(
        :feishu,
        :send_message,
        {:ok, %{"code" => 0}}
      )

      MockProvider.enqueue(%NormalizedResponse{
        content: "Feishu reply",
        finish_reason: "stop",
        tool_calls: nil
      })

      {:ok, pid} =
        Feishu.start_link(
          app_id: "app-1",
          app_secret: "secret-1",
          bot_api: MockFeishuBot,
          session_provider: MockProvider
        )

      payload = %{
        "event" => %{
          "chat_id" => chat_id,
          "text" => "hi feishu",
          "open_id" => "ou_999"
        }
      }

      :ok = GenServer.call(pid, {:handle_inbound, payload})

      assert_eventually(fn ->
        SessionServer.whereis(session_id) != nil and
          Enum.any?(MockGatewayClient.calls(), fn
            {{:feishu, :send_message}, ["token-1", ^chat_id, "Feishu reply", []]} -> true
            _ -> false
          end)
      end)

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp ensure_registry_started do
    entries = [
      %{
        name: :discord,
        label: "Discord",
        module: Discord,
        check_fn: fn -> true end,
        required_env: ["DISCORD_BOT_TOKEN"]
      },
      %{
        name: :slack,
        label: "Slack",
        module: Slack,
        check_fn: fn -> true end,
        required_env: ["SLACK_BOT_TOKEN"]
      },
      %{
        name: :whatsapp,
        label: "WhatsApp",
        module: WhatsApp,
        check_fn: fn -> true end,
        required_env: ["WHATSAPP_TOKEN", "WHATSAPP_PHONE_NUMBER_ID"]
      },
      %{
        name: :signal,
        label: "Signal",
        module: Signal,
        check_fn: fn -> true end,
        required_env: ["SIGNAL_PHONE_NUMBER", "SIGNAL_API_URL"]
      },
      %{
        name: :email,
        label: "Email",
        module: Email,
        check_fn: fn -> true end,
        required_env: [
          "IMAP_HOST",
          "IMAP_USER",
          "IMAP_PASSWORD",
          "SMTP_HOST",
          "SMTP_USER",
          "SMTP_PASSWORD"
        ]
      },
      %{
        name: :feishu,
        label: "Feishu",
        module: Feishu,
        check_fn: fn -> true end,
        required_env: ["FEISHU_APP_ID", "FEISHU_APP_SECRET"]
      }
    ]

    Enum.each(entries, fn entry ->
      if GatewayRegistry.get(entry.name) == nil do
        :ok = GatewayRegistry.register(entry)
      end
    end)

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
