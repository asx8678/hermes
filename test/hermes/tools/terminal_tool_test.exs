defmodule Hermes.Tools.TerminalToolTest do
  @moduledoc """
  Tests for the OS-isolated terminal sidecar integration.
  """

  use Hermes.DataCase, async: false

  alias Hermes.Tools.TerminalTool

  describe "execute/2" do
    test "runs a simple command and returns stdout" do
      result = TerminalTool.execute("echo hello")
      assert result["success"] == true
      assert result["exit_code"] == 0
      assert result["stdout"] =~ "hello"
      assert result["stderr"] == ""
    end

    test "captures stdout and stderr separately" do
      result = TerminalTool.execute("echo out && echo err >&2")
      assert result["success"] == true
      assert result["stdout"] =~ "out"
      assert result["stderr"] =~ "err"
    end

    test "enforces timeout and kills the command" do
      start = System.monotonic_time(:millisecond)
      result = TerminalTool.execute("sleep 30", timeout: 1)
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed < 3_000
      assert result["success"] == false
      assert result["exit_code"] == -1
      assert result["stderr"] =~ "killed after 1s timeout"
    end

    test "does not block the BEAM while a command runs" do
      Task.async(fn -> TerminalTool.execute("sleep 2", timeout: 10) end)

      # The BEAM should remain responsive while the sidecar waits.
      assert TerminalTool.execute("echo still responsive")["stdout"] =~ "still responsive"
    end

    test "recovers after the sidecar process exits" do
      # First command works.
      assert TerminalTool.execute("echo first")["stdout"] =~ "first"

      # Kill the sidecar process and wait for the port to die.
      kill_sidecar_port()

      # The next request should detect the dead port, start a fresh sidecar,
      # and still return a correct result.
      assert TerminalTool.execute("echo second")["stdout"] =~ "second"
    end
  end

  describe "invoke/1" do
    test "returns error for empty command" do
      result = TerminalTool.invoke(%{"command" => "   "})
      assert result["success"] == false
      assert result["error"] =~ "empty"
    end

    test "returns error when command is missing" do
      result = TerminalTool.invoke(%{})
      assert result["success"] == false
      assert result["error"] =~ "required"
    end

    test "uses the timeout from args" do
      start = System.monotonic_time(:millisecond)
      result = TerminalTool.invoke(%{"command" => "sleep 30", "timeout" => 1})
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed < 3_000
      assert result["success"] == false
      assert result["exit_code"] == -1
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp kill_sidecar_port do
    # Find the sidecar port owned by the TerminalSidecar GenServer.
    case Process.whereis(Hermes.Tools.TerminalSidecar) do
      nil ->
        :ok

      pid ->
        port = :sys.get_state(pid).port

        if is_port(port) do
          # Ask the OS to terminate the sidecar process. On Unix this is the
          # negative process group id sent to the whole group.
          os_pid = Port.info(port)[:os_pid]
          _ = System.cmd("kill", ["-9", "-#{os_pid}"])
          # Wait until the port is reported as dead.
          wait_for_port_exit(pid)
        end
    end
  end

  defp wait_for_port_exit(pid) do
    case :sys.get_state(pid).port do
      port when is_port(port) ->
        if Port.info(port) do
          Process.sleep(50)
          wait_for_port_exit(pid)
        end

      _ ->
        :ok
    end
  end
end
