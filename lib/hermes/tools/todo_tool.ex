defmodule Hermes.Tools.TodoTool do
  @moduledoc """
  Minimal per-session todo list.

  Provides a tiny in-memory todo store keyed by session id. This is the
  narrow-waist planning primitive used by the dispatcher for the `todo`
  tool name.
  """

  use Agent

  @name __MODULE__

  @doc """
  Starts the todo store agent.
  """
  @spec start_link() :: Agent.on_start()
  def start_link do
    Agent.start_link(fn -> %{} end, name: @name)
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil -> start_link()
      pid -> {:ok, pid}
    end
  end

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "todo",
        toolset: "planning",
        schema: %{
          name: "todo",
          description: "Manage a per-session todo list.",
          parameters: %{
            type: "object",
            properties: %{
              action: %{
                type: "string",
                enum: ["add", "list", "complete", "reset"],
                description: "Action to perform on the session todo list."
              },
              content: %{
                type: "string",
                description: "Todo text for add/complete actions."
              },
              todos: %{
                type: "array",
                items: %{type: "string"},
                description: "Batch of todo items to merge."
              },
              merge: %{
                type: "boolean",
                description: "When true, merge `todos` into the existing list."
              }
            },
            required: ["action"]
          }
        },
        handler: &invoke/2,
        check_fn: &always_available/0
      }
    ]
  end

  @doc """
  Dispatches a todo action and returns a JSON-encodable result.
  """
  @spec invoke(map(), map()) :: map()
  def invoke(args, context) do
    ensure_started()
    session_id = Map.get(context, :session_id, "default")
    action = Map.get(args, "action", "list")

    case action do
      "add" ->
        content = Map.get(args, "content", "")

        if String.trim(content) == "" do
          %{"success" => false, "error" => "content required for add"}
        else
          Agent.update(@name, fn state ->
            items = Map.get(state, session_id, [])
            Map.put(state, session_id, items ++ [content])
          end)

          %{"success" => true, "action" => "add", "item" => content}
        end

      "list" ->
        items = Agent.get(@name, &Map.get(&1, session_id, []))
        %{"success" => true, "todos" => items, "count" => length(items)}

      "complete" ->
        content = Map.get(args, "content", "")

        Agent.update(@name, fn state ->
          items = Map.get(state, session_id, [])
          updated = Enum.reject(items, &String.contains?(&1, content))
          Map.put(state, session_id, updated)
        end)

        %{"success" => true, "action" => "complete"}

      "reset" ->
        Agent.update(@name, &Map.put(&1, session_id, []))
        %{"success" => true, "action" => "reset"}

      _other ->
        %{"success" => false, "error" => "unknown todo action: #{action}"}
    end
  end

  defp always_available, do: true
end
