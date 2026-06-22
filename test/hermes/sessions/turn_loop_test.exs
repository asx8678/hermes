defmodule Hermes.Sessions.TurnLoopTest do
  @moduledoc """
  Tests for `Hermes.Sessions.TurnLoop`.

  Ports the behavior exercised by `agent/conversation_loop.py:589-4562`.
  """

  use Hermes.DataCase, async: false

  alias Hermes.Providers.Types.NormalizedResponse
  alias Hermes.Providers.Types.ToolCall
  alias Hermes.Sessions.IterationBudget
  alias Hermes.Sessions.TurnLoop
  alias Hermes.Test.MockProvider
  alias Hermes.Tools.Registry

  setup do
    ensure_registry()
    start_supervised!(MockProvider)
    MockProvider.reset()
    :ok
  end

  describe "single text response" do
    test "returns final_response and appends assistant message" do
      MockProvider.enqueue(%NormalizedResponse{
        content: "Hello, world!",
        finish_reason: "stop"
      })

      assert {:ok, result} =
               TurnLoop.run(
                 session_id: "sess_1",
                 messages: [%{role: "user", content: "hi"}],
                 provider: MockProvider,
                 max_iterations: 5
               )

      assert result.completed == true
      assert result.api_calls == 1
      assert result.final_response == "Hello, world!"

      assert [%{role: "user", content: "hi"}, %{role: "assistant", content: "Hello, world!"}] =
               result.messages
    end
  end

  describe "tool-call turn" do
    test "executes one tool and continues until final response" do
      MockProvider.enqueue(%NormalizedResponse{
        content: nil,
        finish_reason: "tool_calls",
        tool_calls: [
          ToolCall.new(
            id: "call_1",
            name: "todo",
            arguments: %{"action" => "list"}
          )
        ]
      })

      MockProvider.enqueue(%NormalizedResponse{
        content: "Done",
        finish_reason: "stop"
      })

      assert {:ok, result} =
               TurnLoop.run(
                 session_id: "sess_2",
                 messages: [%{role: "user", content: "manage my todos"}],
                 provider: MockProvider,
                 max_iterations: 5
               )

      assert result.completed == true
      assert result.api_calls == 2
      assert result.final_response == "Done"

      assert [assistant_msg, tool_result, final_msg] = Enum.take(result.messages, -3)
      assert assistant_msg.role == "assistant"
      assert [%{"function" => %{"name" => "todo"}}] = assistant_msg.tool_calls
      assert tool_result.role == "tool"
      assert tool_result.tool_call_id == "call_1"
      assert final_msg.role == "assistant"
      assert final_msg.content == "Done"
    end
  end

  describe "budget exhaustion" do
    test "exits with budget_exhausted when budget is consumed" do
      budget = IterationBudget.new(1)
      {:ok, budget} = IterationBudget.consume(budget)

      assert {:error, result} =
               TurnLoop.run(
                 session_id: "sess_3",
                 messages: [%{role: "user", content: "hi"}],
                 provider: MockProvider,
                 max_iterations: 5,
                 iteration_budget: budget
               )

      assert result.partial == true
      assert result.api_calls == 0
      assert result.message =~ "budget_exhausted"
    end
  end

  describe "max_iterations reached" do
    test "exits once api_call_count reaches max_iterations" do
      # Each mock response asks for another tool call, so the loop would
      # continue forever without max_iterations.
      MockProvider.enqueue(%NormalizedResponse{
        content: nil,
        finish_reason: "tool_calls",
        tool_calls: [
          ToolCall.new(
            id: "call_iter",
            name: "todo",
            arguments: %{"action" => "list"}
          )
        ]
      })

      MockProvider.enqueue(%NormalizedResponse{
        content: nil,
        finish_reason: "tool_calls",
        tool_calls: [
          ToolCall.new(
            id: "call_iter2",
            name: "todo",
            arguments: %{"action" => "list"}
          )
        ]
      })

      assert {:error, result} =
               TurnLoop.run(
                 session_id: "sess_4",
                 messages: [%{role: "user", content: "loop"}],
                 provider: MockProvider,
                 max_iterations: 2
               )

      assert result.partial == true
      assert result.api_calls == 2
    end
  end

  describe "execute_code refund" do
    test "refunds the budget when only execute_code is called" do
      MockProvider.enqueue(%NormalizedResponse{
        content: nil,
        finish_reason: "tool_calls",
        tool_calls: [
          ToolCall.new(
            id: "call_code",
            name: "execute_code",
            arguments: %{"language" => "elixir", "code" => "1 + 1"}
          )
        ]
      })

      MockProvider.enqueue(%NormalizedResponse{
        content: "Refunded turn complete",
        finish_reason: "stop"
      })

      # With a budget of 1 and no refund, the second provider call
      # (the final text response) would exhaust the budget and exit
      # with budget_exhausted. The refund proves execute_code-only
      # turns do not consume budget.
      budget = IterationBudget.new(1)

      assert {:ok, result} =
               TurnLoop.run(
                 session_id: "sess_5",
                 messages: [%{role: "user", content: "compute"}],
                 provider: MockProvider,
                 max_iterations: 5,
                 iteration_budget: budget
               )

      assert result.completed == true
      assert result.api_calls == 2
      assert result.final_response == "Refunded turn complete"
    end
  end

  describe "API error" do
    test "fills missing tool results and returns a partial result near max_iterations" do
      MockProvider.enqueue(%NormalizedResponse{
        content: nil,
        finish_reason: "tool_calls",
        tool_calls: [
          ToolCall.new(
            id: "call_err",
            name: "todo",
            arguments: %{"action" => "list"}
          )
        ]
      })

      MockProvider.enqueue_error("network timeout")

      assert {:error, result} =
               TurnLoop.run(
                 session_id: "sess_6",
                 messages: [%{role: "user", content: "fail"}],
                 provider: MockProvider,
                 max_iterations: 2
               )

      assert result.partial == true
      assert result.api_calls == 2

      tool_result = Enum.find(result.messages, &match?(%{role: "tool"}, &1))
      assert tool_result.tool_call_id == "call_err"
      assert tool_result.name == "todo"
    end
  end

  describe "tool validation" do
    test "rejects invalid tool names and continues" do
      MockProvider.enqueue(%NormalizedResponse{
        content: nil,
        finish_reason: "tool_calls",
        tool_calls: [
          ToolCall.new(
            id: "call_bad",
            name: "nonexistent_tool",
            arguments: %{}
          )
        ]
      })

      MockProvider.enqueue(%NormalizedResponse{
        content: "Acknowledged",
        finish_reason: "stop"
      })

      assert {:ok, result} =
               TurnLoop.run(
                 session_id: "sess_7",
                 messages: [%{role: "user", content: "bad tool"}],
                 provider: MockProvider,
                 max_iterations: 5
               )

      assert result.completed == true
      assert result.api_calls == 2

      tool_result = Enum.find(result.messages, &match?(%{role: "tool"}, &1))
      assert tool_result.tool_call_id == "call_bad"
      assert tool_result.content =~ "does not exist"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ensure_registry do
    case Registry.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Registry.register_builtins()
  end
end
