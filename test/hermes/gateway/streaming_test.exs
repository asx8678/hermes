defmodule Hermes.Gateway.StreamingTest do
  @moduledoc """
  Tests for `Hermes.Gateway.Streaming`.

  Verifies the three streaming strategies (`:edit`, `:draft`, `:off`) and the
  throttle behaviour that prevents rapid connector edits.
  """

  use ExUnit.Case, async: false

  alias Hermes.Gateway.Streaming

  defmodule FakeConnector do
    @moduledoc false
    use GenServer

    def start_link(parent) do
      GenServer.start_link(__MODULE__, parent)
    end

    @impl true
    def init(parent) do
      {:ok, %{parent: parent, counter: 1}}
    end

    @impl true
    def handle_call({:send_message, session_id, text, opts}, _from, state) do
      message_id = "msg-#{state.counter}"
      send(state.parent, {:send_message, session_id, text, opts})

      {:reply, {:ok, %{"result" => %{"message_id" => message_id}}},
       %{state | counter: state.counter + 1}}
    end

    @impl true
    def handle_call({:edit_message, session_id, message_id, text, opts}, _from, state) do
      send(state.parent, {:edit_message, session_id, message_id, text, opts})
      {:reply, {:ok, %{"result" => %{"message_id" => message_id}}}, state}
    end
  end

  setup do
    old_config = Application.get_env(:hermes, :gateway, [])

    Application.put_env(:hermes, :gateway,
      allowlist: [],
      approval_required: [:file_write],
      streaming_throttle_ms: 0
    )

    on_exit(fn ->
      Application.put_env(:hermes, :gateway, old_config)
    end)

    :ok
  end

  describe "strategy_for/1" do
    test "edit platforms return :edit" do
      assert Streaming.strategy_for(:telegram) == :edit
      assert Streaming.strategy_for(:discord) == :edit
      assert Streaming.strategy_for(:slack) == :edit
      assert Streaming.strategy_for(:feishu) == :edit
    end

    test "non-editing platforms return :off" do
      assert Streaming.strategy_for(:whatsapp) == :off
      assert Streaming.strategy_for(:signal) == :off
      assert Streaming.strategy_for(:email) == :off
      assert Streaming.strategy_for(:unknown) == :off
    end
  end

  describe "should_send_delta?/2" do
    test "returns true once throttle has elapsed" do
      assert Streaming.should_send_delta?(:edit, 100)
      assert Streaming.should_send_delta?(:edit, 500)
    end

    test "returns false before throttle has elapsed" do
      Application.put_env(:hermes, :gateway,
        allowlist: [],
        approval_required: [:file_write],
        streaming_throttle_ms: 100
      )

      refute Streaming.should_send_delta?(:edit, 0)
      refute Streaming.should_send_delta?(:edit, 50)
    end
  end

  describe ":edit strategy" do
    test "sends an initial message and then edits it" do
      connector = start_connector!()

      :ok = Streaming.send_streaming(connector, "session-1", "Hello ", :edit, "chat-1")
      assert_receive {:send_message, "session-1", "Hello ", [chat_id: "chat-1"]}

      :ok = Streaming.send_streaming(connector, "session-1", "world!", :edit, "chat-1")
      assert_receive {:edit_message, "session-1", "msg-1", "Hello world!", [chat_id: "chat-1"]}
    end

    test "different sessions do not share message ids" do
      connector = start_connector!()

      :ok = Streaming.send_streaming(connector, "session-a", "A", :edit, "chat-a")
      assert_receive {:send_message, "session-a", "A", [chat_id: "chat-a"]}

      :ok = Streaming.send_streaming(connector, "session-b", "B", :edit, "chat-b")
      assert_receive {:send_message, "session-b", "B", [chat_id: "chat-b"]}

      :ok = Streaming.send_streaming(connector, "session-a", " second", :edit, "chat-a")
      assert_receive {:edit_message, "session-a", "msg-1", "A second", [chat_id: "chat-a"]}

      :ok = Streaming.send_streaming(connector, "session-b", " second", :edit, "chat-b")
      assert_receive {:edit_message, "session-b", "msg-2", "B second", [chat_id: "chat-b"]}
    end
  end

  describe ":draft strategy" do
    test "uses the edit path as the draft primitive" do
      connector = start_connector!()

      :ok = Streaming.send_streaming(connector, "session-1", "Draft ", :draft, "chat-1")
      assert_receive {:send_message, "session-1", "Draft ", [chat_id: "chat-1"]}

      :ok = Streaming.send_streaming(connector, "session-1", "update", :draft, "chat-1")
      assert_receive {:edit_message, "session-1", "msg-1", "Draft update", [chat_id: "chat-1"]}
    end
  end

  describe ":off strategy" do
    test "buffers text and only sends the final message on finish/3" do
      connector = start_connector!()

      :ok = Streaming.send_streaming(connector, "session-1", "part one ", :off, "chat-1")
      refute_received {:send_message, _, _, _}

      :ok = Streaming.send_streaming(connector, "session-1", "part two", :off, "chat-1")
      refute_received {:send_message, _, _, _}

      :ok = Streaming.finish(connector, "session-1", "chat-1")
      assert_receive {:send_message, "session-1", "part one part two", [chat_id: "chat-1"]}
    end

    test "finish/3 is a no-op when nothing was buffered" do
      connector = start_connector!()

      assert :ok = Streaming.finish(connector, "session-1", "chat-1")
      refute_received {:send_message, _, _, _}
    end
  end

  describe "throttle" do
    test "prevents rapid edits" do
      Application.put_env(:hermes, :gateway,
        allowlist: [],
        approval_required: [:file_write],
        streaming_throttle_ms: 100
      )

      connector = start_connector!()

      # First delta creates the message.
      :ok = Streaming.send_streaming(connector, "session-1", "1", :edit, "chat-1")
      assert_receive {:send_message, "session-1", "1", [chat_id: "chat-1"]}

      # Immediate second delta is throttled; no edit is sent.
      :ok = Streaming.send_streaming(connector, "session-1", "2", :edit, "chat-1")
      refute_received {:edit_message, _, _, _, _}

      # After the throttle window a single edit with the accumulated text is sent.
      Process.sleep(120)
      :ok = Streaming.send_streaming(connector, "session-1", "3", :edit, "chat-1")
      assert_receive {:edit_message, "session-1", "msg-1", "123", [chat_id: "chat-1"]}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_connector! do
    {:ok, pid} = FakeConnector.start_link(self())
    pid
  end
end
