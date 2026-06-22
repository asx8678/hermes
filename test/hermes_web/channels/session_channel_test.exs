defmodule HermesWeb.SessionChannelTest do
  @moduledoc """
  Tests for `HermesWeb.SessionChannel`.
  """

  use HermesWeb.ChannelCase, async: false

  alias Hermes.Providers.Types.NormalizedResponse
  alias Hermes.Test.MockProvider

  setup do
    start_supervised!(MockProvider)
    MockProvider.reset()
    :ok
  end

  describe "join" do
    test "joins a session topic and subscribes to its PubSub topic" do
      {:ok, _, socket} =
        socket(@endpoint) |> join(HermesWeb.SessionChannel, "session:123")

      assert socket.assigns.session_id == "123"
    end

    test "rejects an empty session_id" do
      assert {:error, %{reason: "invalid session_id"}} ==
               socket(@endpoint) |> join(HermesWeb.SessionChannel, "session:")
    end
  end

  describe "session:create" do
    test "creates a new session and replies with session_id" do
      {:ok, _, socket} =
        socket(@endpoint) |> join(HermesWeb.SessionChannel, "session:new")

      ref = push(socket, "session:create", %{"model" => "claude-sonnet-4-20250514"})
      assert_reply ref, :ok, %{session_id: session_id, pid: _pid}
      assert is_binary(session_id)
    end
  end

  describe "send_prompt" do
    test "triggers a non-blocking turn and replies with status started" do
      # Pre-create a session wired to the mock provider so the test does not
      # hit the real Anthropic API.
      {:ok, _pid, session_id} =
        Hermes.Sessions.start_session(provider: Hermes.Test.MockProvider)

      MockProvider.enqueue(%NormalizedResponse{
        content: "Hello back",
        finish_reason: "stop",
        tool_calls: nil,
        usage: %{input_tokens: 1, output_tokens: 2}
      })

      {:ok, _, socket} =
        socket(@endpoint)
        |> join(HermesWeb.SessionChannel, "session:#{session_id}")

      ref = push(socket, "send_prompt", %{"message" => "hi"})
      assert_reply ref, :ok, %{status: "started"}

      assert_push("turn:complete", %{final_response: "Hello back", completed: true}, 1000)
    end

    test "returns an error when the session is not found" do
      {:ok, _, socket} =
        socket(@endpoint) |> join(HermesWeb.SessionChannel, "session:missing")

      ref = push(socket, "send_prompt", %{"message" => "hi"})
      assert_reply ref, :error, %{reason: "session not found"}
    end

    test "returns an error when message is missing" do
      {:ok, _, socket} =
        socket(@endpoint) |> join(HermesWeb.SessionChannel, "session:123")

      ref = push(socket, "send_prompt", %{"foo" => "bar"})
      assert_reply ref, :error, %{reason: "missing message"}
    end
  end

  describe "PubSub forwarding" do
    test "pushes stream:delta events to the client" do
      {:ok, _, _socket} =
        socket(@endpoint) |> join(HermesWeb.SessionChannel, "session:456")

      Phoenix.PubSub.broadcast(
        Hermes.PubSub,
        "session:456",
        {:stream_delta, "hello"}
      )

      assert_push("stream:delta", %{text: "hello"})
    end

    test "pushes tool:start events to the client" do
      {:ok, _, _socket} =
        socket(@endpoint) |> join(HermesWeb.SessionChannel, "session:456")

      Phoenix.PubSub.broadcast(
        Hermes.PubSub,
        "session:456",
        {:tool_start, %{tool_name: "terminal", args: %{}}}
      )

      assert_push("tool:start", %{tool_name: "terminal", args: %{}})
    end

    test "pushes tool:result events to the client" do
      {:ok, _, _socket} =
        socket(@endpoint) |> join(HermesWeb.SessionChannel, "session:456")

      Phoenix.PubSub.broadcast(
        Hermes.PubSub,
        "session:456",
        {:tool_result, %{tool_name: "terminal", result: "ok"}}
      )

      assert_push("tool:result", %{tool_name: "terminal", result: "ok"})
    end

    test "pushes turn:complete events to the client" do
      {:ok, _, _socket} =
        socket(@endpoint) |> join(HermesWeb.SessionChannel, "session:456")

      Phoenix.PubSub.broadcast(
        Hermes.PubSub,
        "session:456",
        {:turn_complete, %{final_response: "done", api_calls: 1, completed: true}}
      )

      assert_push("turn:complete", %{
        final_response: "done",
        api_calls: 1,
        completed: true
      })
    end

    test "pushes turn:error events to the client" do
      {:ok, _, _socket} =
        socket(@endpoint) |> join(HermesWeb.SessionChannel, "session:456")

      Phoenix.PubSub.broadcast(
        Hermes.PubSub,
        "session:456",
        {:turn_error, %{error: "it broke", partial: true}}
      )

      assert_push("turn:error", %{error: "it broke", partial: true})
    end

    test "pushes session:status events to the client" do
      {:ok, _, _socket} =
        socket(@endpoint) |> join(HermesWeb.SessionChannel, "session:456")

      Phoenix.PubSub.broadcast(
        Hermes.PubSub,
        "session:456",
        {:session_status, %{status: "running"}}
      )

      assert_push("session:status", %{status: "running"})
    end
  end
end
