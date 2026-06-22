defmodule Hermes.GoldenTranscriptTest do
  @moduledoc """
  Golden-transcript parity tests for `Hermes.Sessions.TurnLoop`.

  These synthetic transcripts capture the shape of the Python agent's
  behavior so the Elixir turn loop cannot silently drop edge cases.

  Captured edge cases:

    * Single text response — provider returns a plain answer with no tool
      calls. Mirrors `agent/conversation_loop.py:4144-4480`.

    * Single tool call — provider returns a `read_file` tool call, the
      dispatcher invokes it, and the provider answers with a final response.
      Mirrors `agent/conversation_loop.py:3791-4142`.

    * Budget exhaustion — provider always returns tool calls and never a
      final answer; the loop exits with `budget_exhausted`.
      Mirrors `agent/conversation_loop.py:605-614`.

    * Error recovery — a transient API error after a tool call is absorbed,
      missing tool results are filled, and the loop retries until a final
      answer is produced. Mirrors `agent/conversation_loop.py:4482-4537`.

    * execute_code budget refund — a turn containing only `execute_code` is
      refunded so the iteration budget is not consumed.
      Mirrors `agent/conversation_loop.py:4083-4088`.
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
    test "matches golden transcript" do
      transcript = load_fixture("single_text_response")
      result = run_transcript(transcript)
      assert_ok_result(result, transcript["expected"])
    end
  end

  describe "single tool call" do
    test "matches golden transcript" do
      transcript = load_fixture("single_tool_call")
      result = run_transcript(transcript)
      assert_ok_result(result, transcript["expected"])
    end
  end

  describe "budget exhaustion" do
    test "matches golden transcript" do
      transcript = load_fixture("budget_exhaustion")
      result = run_transcript(transcript)
      assert_error_result(result, transcript["expected"])
    end
  end

  describe "error recovery" do
    test "matches golden transcript" do
      transcript = load_fixture("error_recovery")
      result = run_transcript(transcript)
      assert_ok_result(result, transcript["expected"])
    end
  end

  describe "execute_code budget refund" do
    test "matches golden transcript" do
      transcript = load_fixture("execute_code_refund")
      result = run_transcript(transcript)
      assert_ok_result(result, transcript["expected"])
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_fixture(name) do
    path = Path.join(["test", "support", "golden_transcripts", "#{name}.json"])

    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp run_transcript(transcript) do
    input = transcript["input"]
    expected = transcript["expected"]

    Enum.each(transcript["responses"], fn response ->
      case response["type"] do
        "ok" ->
          tool_calls =
            case response["tool_calls"] || [] do
              [] ->
                nil

              calls ->
                Enum.map(calls, fn tc ->
                  ToolCall.new(
                    id: tc["id"],
                    name: tc["name"],
                    arguments: tc["arguments"]
                  )
                end)
            end

          MockProvider.enqueue(%NormalizedResponse{
            content: response["content"],
            finish_reason: response["finish_reason"],
            tool_calls: tool_calls
          })

        "error" ->
          MockProvider.enqueue_error(response["reason"])
      end
    end)

    opts =
      [
        session_id: input["session_id"],
        messages: input["messages"],
        provider: MockProvider,
        max_iterations: input["max_iterations"]
      ]
      |> maybe_put_budget(input["budget"])

    case expected["status"] do
      "ok" ->
        assert {:ok, result} = TurnLoop.run(opts)
        result

      "error" ->
        assert {:error, result} = TurnLoop.run(opts)
        result
    end
  end

  defp maybe_put_budget(opts, nil), do: opts

  defp maybe_put_budget(opts, budget_config) do
    budget = IterationBudget.new(budget_config["max_total"])
    Keyword.put(opts, :iteration_budget, budget)
  end

  defp assert_ok_result(result, expected) do
    assert result.completed == true
    assert result.api_calls == expected["api_calls"]
    assert result.final_response == expected["final_response"]

    if expected["has_tool_result"] do
      tool_result = Enum.find(result.messages, &match?(%{role: "tool"}, &1))
      assert tool_result
      assert tool_result.tool_call_id == expected["tool_call_id"]
    end
  end

  defp assert_error_result(result, expected) do
    assert result.partial == true
    assert result.api_calls == expected["api_calls"]

    if expected["message_contains"] do
      assert result.message =~ expected["message_contains"]
    end
  end

  defp ensure_registry do
    case Registry.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Registry.register_builtins()
  end
end
