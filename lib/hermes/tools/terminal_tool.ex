defmodule Hermes.Tools.TerminalTool do
  @moduledoc """
  Minimal terminal tool: shells out via `System.cmd/3`.

  This is the Milestone A stand-in for the full sidecar terminal backend
  planned for Milestone D. Port of `tools/terminal_tool.py:2738`.
  """

  @default_timeout 60

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "terminal",
        toolset: "terminal",
        schema: terminal_schema(),
        handler: fn args, _ctx -> invoke(args) end,
        check_fn: &always_available/0
      }
    ]
  end

  @doc """
  Executes a shell command and returns a JSON-encodable result.
  """
  @spec invoke(map()) :: map()
  def invoke(%{"command" => command}) when is_binary(command) do
    if String.trim(command) == "" do
      %{"success" => false, "error" => "command is empty"}
    else
      {output, exit_code} =
        System.cmd("sh", ["-c", command], stderr_to_stdout: true)

      %{
        "success" => exit_code == 0,
        "stdout" => output,
        "stderr" => "",
        "exit_code" => exit_code
      }
    end
  end

  def invoke(_args) do
    %{"success" => false, "error" => "command is required"}
  end

  defp always_available, do: true

  defp terminal_schema do
    %{
      name: "terminal",
      description: "Execute a shell command on the local machine.",
      parameters: %{
        type: "object",
        properties: %{
          command: %{
            type: "string",
            description: "The command to execute."
          },
          timeout: %{
            type: "integer",
            description: "Maximum seconds to wait for the command.",
            default: @default_timeout,
            minimum: 1
          }
        },
        required: ["command"]
      }
    }
  end
end
