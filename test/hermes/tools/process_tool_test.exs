defmodule Hermes.Tools.ProcessToolTest do
  @moduledoc """
  Tests for `Hermes.Tools.ProcessTool`.

  The tool delegates `ps`/`kill` to the terminal sidecar. Tests here assert
  the shape of successful and error responses without depending on specific
  processes running on the host.
  """

  use Hermes.DataCase, async: false

  alias Hermes.Tools.ProcessTool

  describe "tool_entries/0" do
    test "returns one entry named process under the terminal toolset" do
      entries = ProcessTool.tool_entries()
      assert length(entries) == 1

      [entry] = entries
      assert entry.name == "process"
      assert entry.toolset == "terminal"
      assert entry.schema[:name] == "process"
      assert is_function(entry.handler, 2)
      assert entry.check_fn.() == true
    end
  end

  describe "invoke/2 list action" do
    test "lists running processes with expected fields" do
      result = ProcessTool.invoke(%{"action" => "list"}, %{})

      assert result["success"] == true
      assert result["action"] == "list"
      assert is_list(result["processes"])
      assert result["count"] == length(result["processes"])
      assert result["count"] >= 0

      if result["count"] > 0 do
        [first | _] = result["processes"]

        assert Map.has_key?(first, "pid")
        assert Map.has_key?(first, "ppid")
        assert Map.has_key?(first, "user")
        assert Map.has_key?(first, "cpu_percent")
        assert Map.has_key?(first, "mem_percent")
        assert Map.has_key?(first, "elapsed")
        assert Map.has_key?(first, "command")
      end
    end
  end

  describe "invoke/2 kill action" do
    test "returns success when killing a non-existent pid is reported" do
      # Use a pid that is extremely unlikely to exist.
      fake_pid = System.unique_integer([:positive])
      result = ProcessTool.invoke(%{"action" => "kill", "pid" => fake_pid}, %{})

      assert result["action"] == "kill"
      assert result["pid"] == to_string(fake_pid)

      # The sidecar may report success even when kill prints an error (because
      # the exit code falls back to kill -9), or it may report an error. Both
      # are acceptable behaviours; we only assert shape.
      case result["success"] do
        true ->
          assert result["status"] == "killed"

        false ->
          assert is_binary(result["error"])
          assert result["status"] == "error"
      end
    end

    test "accepts string pids" do
      result = ProcessTool.invoke(%{"action" => "kill", "pid" => "999999"}, %{"session_id" => "s1"})

      assert result["action"] == "kill"
      assert result["pid"] == "999999"
      assert is_boolean(result["success"])
    end

    test "rejects invalid pid string" do
      result = ProcessTool.invoke(%{"action" => "kill", "pid" => "abc"}, %{"session_id" => "s1"})

      assert result["success"] == false
      assert result["error"] == "pid must be a positive integer"
    end

    test "rejects empty pid string" do
      result = ProcessTool.invoke(%{"action" => "kill", "pid" => "  "}, %{"session_id" => "s1"})

      assert result["success"] == false
      assert result["error"] == "pid must be a positive integer"
    end

    test "rejects negative integer pid" do
      result = ProcessTool.invoke(%{"action" => "kill", "pid" => -1}, %{"session_id" => "s1"})

      assert result["success"] == false
      assert result["error"] == "pid must be a positive integer"
    end
  end

  describe "invoke/2 action validation" do
    test "returns error for unknown action" do
      result = ProcessTool.invoke(%{"action" => "pause"}, %{"session_id" => "s1"})

      assert result["success"] == false
      assert result["error"] =~ "unknown process action: pause"
      assert result["error"] =~ "list, kill"
    end

    test "returns error when action is missing" do
      result = ProcessTool.invoke(%{"pid" => 123}, %{"session_id" => "s1"})

      assert result["success"] == false
      assert result["error"] == "action is required (list/kill) and pid is required for kill"
    end
  end
end
