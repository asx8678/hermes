defmodule Hermes.Tools.TerminalTool do
  @moduledoc """
  Terminal tool backed by an OS-isolated Rust sidecar.

  Commands run in a separate OS process via `Hermes.Tools.TerminalSidecar`,
  so a crash or hang cannot affect the BEAM. Port of `tools/terminal_tool.py:2738`.
  """

  alias Hermes.Tools.TerminalSidecar

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
  Executes a shell command through the sidecar and returns a JSON-encodable result.
  """
  @spec invoke(map()) :: map()
  def invoke(%{"command" => command} = args) when is_binary(command) do
    if String.trim(command) == "" do
      %{"success" => false, "error" => "command is empty"}
    else
      timeout = get_timeout(args)
      execute(command, timeout: timeout)
    end
  end

  def invoke(_args) do
    %{"success" => false, "error" => "command is required"}
  end

  @doc """
  Execute a shell command via the terminal sidecar.

  ## Options

    * `:timeout` - maximum seconds to wait for the command (default #{@default_timeout})
    * `:cwd` - working directory for the command
  """
  @spec execute(String.t(), keyword()) :: map()
  def execute(command, opts \\ []) when is_binary(command) do
    TerminalSidecar.execute(command, opts)
  end

  defp always_available, do: true

  # The original Python tool permitted an optional `timeout` key in the args
  # map (in addition to the schema default). Keep that behaviour.
  defp get_timeout(args) when is_map(args) do
    case Map.get(args, "timeout") do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_timeout
    end
  end

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
