defmodule Hermes.Tools.ProcessTool do
  @moduledoc """
  Process management tool: list/kill background processes.

  Port of `tools/process_registry.py:1786` and the background process
  management used by the terminal tool. In this implementation we use the
  terminal sidecar to run `ps`/`kill` because the Elixir sidecar does not
  maintain a separate in-process process registry.
  """

  alias Hermes.Tools.TerminalSidecar

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "process",
        toolset: "terminal",
        schema: process_schema(),
        handler: &invoke/2,
        check_fn: &always_available/0
      }
    ]
  end

  @doc """
  Dispatches a process action and returns a JSON-encodable result.
  """
  @spec invoke(map(), map()) :: map()
  def invoke(%{"action" => "list"}, _context) do
    command = ps_list_command()

    case TerminalSidecar.execute(command, timeout: 30) do
      %{"success" => true, "stdout" => output} ->
        processes =
          output
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.reject(&String.starts_with?(&1, "PID"))
          |> Enum.map(&parse_ps_line/1)

        %{
          "success" => true,
          "action" => "list",
          "count" => length(processes),
          "processes" => processes
        }

      %{"success" => false} = result ->
        Map.merge(result, %{"action" => "list"})
    end
  end

  # macOS `ps` uses `-axo` (all processes) with `%` prefixed CPU/MEM column names.
  # Linux `ps` uses `-eo` with `pcpu`/`pmem` and supports `--no-headers`.
  defp ps_list_command do
    case :os.type() do
      {:unix, :darwin} ->
        "ps -axo pid,ppid,user,%cpu,%mem,etime,command | head -n 200"

      {:unix, :linux} ->
        "ps -eo pid,ppid,user,pcpu,pmem,etime,command --no-headers | head -n 200"

      _ ->
        "ps -axo pid,ppid,user,%cpu,%mem,etime,command | head -n 200"
    end
  end

  def invoke(%{"action" => "kill", "pid" => pid_arg}, _context) do
    pid_str = to_string(pid_arg) |> String.trim()

    if pid_str == "" or not String.match?(pid_str, ~r/^\d+$/) do
      %{"success" => false, "error" => "pid must be a positive integer"}
    else
      command = "kill -15 #{pid_str} 2>&1 || kill -9 #{pid_str} 2>&1"

      case TerminalSidecar.execute(command, timeout: 10) do
        %{"success" => true} ->
          %{
            "success" => true,
            "action" => "kill",
            "pid" => pid_str,
            "status" => "killed"
          }

        %{"success" => false, "error" => error} ->
          %{
            "success" => false,
            "action" => "kill",
            "pid" => pid_str,
            "error" => error,
            "status" => "error"
          }

        %{"success" => false} = result ->
          %{
            "success" => false,
            "action" => "kill",
            "pid" => pid_str,
            "error" => Map.get(result, "stderr", Map.get(result, "stdout", "kill failed")),
            "status" => "error"
          }
      end
    end
  end

  def invoke(%{"action" => action}, _context) do
    %{
      "success" => false,
      "error" => "unknown process action: #{action}. Use: list, kill"
    }
  end

  def invoke(_args, _context) do
    %{
      "success" => false,
      "error" => "action is required (list/kill) and pid is required for kill"
    }
  end

  defp parse_ps_line(line) do
    # pid, ppid, user, pcpu, pmem, etime, command
    parts = String.split(line, ~r/\s+/, parts: 7)

    case parts do
      [pid, ppid, user, pcpu, pmem, etime, command] ->
        %{
          "pid" => pid,
          "ppid" => ppid,
          "user" => user,
          "cpu_percent" => pcpu,
          "mem_percent" => pmem,
          "elapsed" => etime,
          "command" => command
        }

      _ ->
        %{"line" => line}
    end
  end

  defp always_available, do: true

  defp process_schema do
    %{
      name: "process",
      description:
        "Manage background processes. Actions: 'list' (show running processes), " <>
          "'kill' (terminate a process by pid).",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["list", "kill"],
            description: "Action to perform on processes"
          },
          pid: %{
            type: "integer",
            description: "Process ID to terminate. Required for kill."
          }
        },
        required: ["action"]
      }
    }
  end
end
