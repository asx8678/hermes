defmodule Hermes.Tools.Dispatcher do
  @moduledoc """
  Dispatches tool invocations to the appropriate handler.

  Ported from the Python source `agent/agent_runtime_helpers.py:1733`.

  Implements the irreducible-6 core tool families described in
  `02-core-tools.md`: terminal, file I/O, execute_code, skills,
  memory/session_search, and delegate_task.

  The dispatcher is the single entry point used by the turn loop (A2).
  It receives a tool name, decoded JSON arguments, and a context map, and
  always returns a JSON-encoded result string.
  """

  alias Hermes.Tools.Registry

  @type context :: %{
          required(:session_id) => String.t(),
          required(:session_pid) => pid(),
          required(:finch_name) => atom(),
          required(:repo) => module()
        }

  @doc """
  Invokes a tool and returns a JSON string.

  `args` may be a map of decoded JSON arguments; any non-map value is
  coerced to an empty map. `context` carries the session id/pid, Finch
  pool name, and Ecto repo.
  """
  @spec invoke(String.t(), map() | any(), context()) :: String.t()
  def invoke(tool_name, args, context) do
    args = to_map(args)

    result =
      try do
        dispatch(tool_name, args, context)
      rescue
        e ->
          %{
            "error" => "tool execution failed: #{Exception.message(e)}",
            "tool" => tool_name
          }
      catch
        kind, value ->
          %{
            "error" => "tool execution failed: #{inspect({kind, value})}",
            "tool" => tool_name
          }
      end

    encode_result(result)
  end

  defp to_map(nil), do: %{}
  defp to_map(args) when is_map(args), do: args
  defp to_map(args) when is_list(args), do: Enum.into(args, %{})
  defp to_map(_), do: %{}

  defp dispatch("todo", args, context),
    do: Hermes.Tools.TodoTool.invoke(args, context)

  defp dispatch("session_search", args, context),
    do: run_session_search(args, context)

  defp dispatch("memory", args, context),
    do: Hermes.Tools.MemoryTool.invoke(args, context)

  defp dispatch("clarify", args, context),
    do: run_clarify(args, context)

  defp dispatch("delegate_task", args, context),
    do: Hermes.Tools.DelegateTool.invoke(args, context)

  defp dispatch(name, args, _context)
       when name in ["read_file", "write_file", "patch", "search_files"],
       do: Hermes.Tools.FileTools.invoke(name, args)

  defp dispatch("terminal", args, _context),
    do: Hermes.Tools.TerminalTool.invoke(args)

  defp dispatch("execute_code", args, _context),
    do: Hermes.Tools.CodeExecutionTool.invoke(args)

  defp dispatch(name, args, _context)
       when name in ["skills_list", "skill_view", "skill_manage"],
       do: Hermes.Tools.SkillTools.invoke(name, args)

  defp dispatch(name, args, context) do
    case Registry.get_entry(name) do
      nil ->
        %{"error" => "unknown tool: #{name}"}

      entry ->
        call_handler(entry.handler, args, context)
    end
  end

  defp call_handler(handler, args, context) when is_function(handler, 2),
    do: handler.(args, context)

  defp call_handler(handler, args, _context) when is_function(handler, 1),
    do: handler.(args)

  defp call_handler(_handler, args, _context),
    do: %{"error" => "invalid handler for args: #{inspect(args)}"}

  # ---------------------------------------------------------------------------
  # Built-in dispatch helpers
  # ---------------------------------------------------------------------------

  defp run_clarify(args, context) do
    question = args["question"] || args["prompt"] || "Could you clarify your request?"
    choices = args["choices"] || args["options"] || []

    if session_id = context[:session_id] do
      Phoenix.PubSub.broadcast(
        Hermes.PubSub,
        "session:#{session_id}",
        {:clarify_request, %{question: question, choices: choices}}
      )
    end

    %{
      "status" => "asked",
      "question" => question,
      "note" =>
        "The question has been posed to the user. The turn will pause; the user's " <>
          "next message is their answer."
    }
  end

  defp run_session_search(args, context) do
    opts = session_search_opts(args, context)
    Hermes.Sessions.SessionSearch.search(opts)
  end

  defp session_search_opts(args, context) do
    base = [
      query: args["query"],
      session_id: args["session_id"],
      around_message_id: args["around_message_id"],
      window: args["window"],
      limit: args["limit"],
      role_filter: args["role_filter"],
      sort: args["sort"]
    ]

    base =
      if session_id = context[:session_id] do
        Keyword.put(base, :current_session_id, session_id)
      else
        base
      end

    Keyword.reject(base, fn {_k, v} -> is_nil(v) end)
  end

  # ---------------------------------------------------------------------------
  # Result encoding
  # ---------------------------------------------------------------------------

  defp encode_result(result) when is_binary(result), do: result
  defp encode_result(result), do: Jason.encode!(result)
end
