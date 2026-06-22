defmodule Hermes.Tools.CodeExecutionToolTest do
  @moduledoc """
  Tests for the OS-isolated code execution sidecar integration.
  """

  use Hermes.DataCase, async: false
  alias Hermes.Tools.CodeExecutionTool

  describe "invoke/1" do
    test "runs simple Python code and returns stdout" do
      result = CodeExecutionTool.invoke(%{"code" => "print('hello')", "language" => "python"})

      assert result["success"]
      assert result["exit_code"] == 0
      assert result["stdout"] =~ "hello"
      assert result["stderr"] == ""
    end

    test "runs simple Elixir code and returns stdout" do
      result = CodeExecutionTool.invoke(%{"code" => "IO.puts(1 + 2)", "language" => "elixir"})

      assert result["success"]
      assert result["exit_code"] == 0
      assert result["stdout"] =~ "3"
    end

    test "captures stderr on syntax error" do
      result = CodeExecutionTool.invoke(%{"code" => "print(", "language" => "python"})

      refute result["success"]
      assert result["exit_code"] != 0
      assert result["stderr"] =~ "SyntaxError"
    end

    test "enforces timeout and kills the script" do
      result =
        CodeExecutionTool.invoke(%{
          "code" => "while True: pass",
          "language" => "python",
          "timeout" => 1
        })

      refute result["success"]
      assert result["exit_code"] == -1
      assert result["stderr"] =~ "killed after 1s timeout"
    end

    test "does not block the BEAM while code runs" do
      long_task =
        Task.async(fn ->
          CodeExecutionTool.invoke(%{
            "code" => "import time; time.sleep(5)",
            "language" => "python",
            "timeout" => 30
          })
        end)

      quick = CodeExecutionTool.invoke(%{"code" => "print('quick')", "language" => "python"})
      assert quick["success"]
      assert quick["stdout"] =~ "quick"

      long = Task.await(long_task, 10_000)
      assert long["success"]
    end

    test "recovers after the sidecar process exits" do
      # Make sure the sidecar is running and the call works.
      before = CodeExecutionTool.invoke(%{"code" => "print('before')", "language" => "python"})
      assert before["success"]

      kill_sidecar_port()

      # Wait briefly for the exit_status message to be processed.
      Process.sleep(100)

      after_kill = CodeExecutionTool.invoke(%{"code" => "print('after')", "language" => "python"})
      assert after_kill["success"]
      assert after_kill["stdout"] =~ "after"
    end
  end

  describe "execute_with_tools/3" do
    test "mock tool calls return results to the script" do
      result =
        CodeExecutionTool.execute_with_tools(
          "print(web_search('foo'))",
          ["web_search"],
          timeout: 10
        )

      assert result["success"]
      assert result["exit_code"] == 0
      assert result["stdout"] =~ "'ok': True"
      assert result["stdout"] =~ "'tool': 'web_search'"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp kill_sidecar_port do
    case Process.whereis(Hermes.Tools.CodeExecutionSidecar) do
      nil ->
        :ok

      pid ->
        %{port: port} = :sys.get_state(pid)
        true = is_port(port)
        Port.close(port)
    end
  end
end
