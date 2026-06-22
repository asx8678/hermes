defmodule Hermes.Tools.CodeExecutionTool do
  @moduledoc """
  Minimal code execution tool: runs code in a subprocess.

  This is the Milestone A stand-in for the sandboxed execution sidecar
  planned for Milestone D. Port of `tools/code_execution_tool.py:1837`.
  """

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
  Runs code in a subprocess and returns stdout/stderr/exit_code.
  """
  @spec invoke(map()) :: map()
  def invoke(%{"code" => code} = args) when is_binary(code) do
    if String.trim(code) == "" do
      %{"success" => false, "error" => "code is empty"}
    else
      language = String.downcase(Map.get(args, "language", "elixir"))
      timeout_ms = int_or(Map.get(args, "timeout"), @default_timeout) * 1000

      case language do
        "elixir" -> run_elixir(code, timeout_ms)
        "python" -> run_python(code, timeout_ms)
        other -> %{"success" => false, "error" => "unsupported language: #{other}"}
      end
    end
  end

  def invoke(_args) do
    %{"success" => false, "error" => "code is required"}
  end

  defp run_elixir(code, _timeout_ms) do
    unique = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    path = Path.join(System.tmp_dir!(), "hermes_exec_#{unique}.exs")

    try do
      File.write!(path, code)

      {output, exit_code} =
        System.cmd("elixir", [path], stderr_to_stdout: true)

      %{
        "success" => exit_code == 0,
        "stdout" => output,
        "stderr" => "",
        "exit_code" => exit_code
      }
    after
      File.rm(path)
    end
  end

  defp run_python(code, _timeout_ms) do
    unique = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    path = Path.join(System.tmp_dir!(), "hermes_exec_#{unique}.py")

    try do
      File.write!(path, code)

      {output, exit_code} =
        System.cmd("python3", [path], stderr_to_stdout: true)

      %{
        "success" => exit_code == 0,
        "stdout" => output,
        "stderr" => "",
        "exit_code" => exit_code
      }
    after
      File.rm(path)
    end
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
