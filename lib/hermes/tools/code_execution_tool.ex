defmodule Hermes.Tools.CodeExecutionTool do
  @moduledoc """
  Code execution tool backed by an OS-isolated Rust sidecar.

  Code runs in a separate OS process via `Hermes.Tools.CodeExecutionSidecar`,
  so a crash or runaway script cannot affect the BEAM. Port of
  `tools/code_execution_tool.py:1837`.
  """

  alias Hermes.Tools.CodeExecutionSidecar

  @default_timeout 30

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "execute_code",
        toolset: "code_execution",
        schema: execute_code_schema(),
        handler: fn args, _ctx -> invoke(args) end,
        check_fn: &always_available/0
      }
    ]
  end

  @doc """
  Runs code through the sidecar and returns stdout/stderr/exit_code.
  """
  @spec invoke(map()) :: map()
  def invoke(%{"code" => code} = args) when is_binary(code) do
    if String.trim(code) == "" do
      %{"success" => false, "error" => "code is empty"}
    else
      language = String.downcase(Map.get(args, "language", "elixir"))
      timeout = int_or(Map.get(args, "timeout"), @default_timeout)

      case language do
        "elixir" -> run_elixir(code, timeout)
        "python" -> run_python(code, timeout)
        other -> %{"success" => false, "error" => "unsupported language: #{other}"}
      end
    end
  end

  def invoke(_args) do
    %{"success" => false, "error" => "code is required"}
  end

  @doc """
  Execute Python code with a mock `hermes_tools` module.

  Only useful for tests; the LLM-facing `invoke/1` does not expose this mode.
  """
  @spec execute_with_tools(String.t(), [String.t()], keyword()) :: map()
  def execute_with_tools(code, allowed_tools, opts \\ []) when is_binary(code) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    CodeExecutionSidecar.execute(code,
      language: "python",
      timeout: timeout,
      allowed_tools: allowed_tools
    )
  end

  defp run_elixir(code, timeout) do
    CodeExecutionSidecar.execute(code, language: "elixir", timeout: timeout)
  end

  defp run_python(code, timeout) do
    CodeExecutionSidecar.execute(code, language: "python", timeout: timeout)
  end

  defp int_or(nil, default), do: default
  defp int_or(value, _default) when is_integer(value), do: value

  defp int_or(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp int_or(_, default), do: default

  defp always_available, do: true

  defp execute_code_schema do
    %{
      name: "execute_code",
      description: "Execute a snippet of code in a subprocess sandbox.",
      parameters: %{
        type: "object",
        properties: %{
          code: %{type: "string", description: "Source code to execute."},
          language: %{
            type: "string",
            enum: ["elixir", "python"],
            description: "Language of the code snippet.",
            default: "elixir"
          },
          timeout: %{
            type: "integer",
            description: "Maximum seconds to wait.",
            default: @default_timeout,
            minimum: 1
          }
        },
        required: ["code"]
      }
    }
  end
end
