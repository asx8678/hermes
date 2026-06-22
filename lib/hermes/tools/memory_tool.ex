defmodule Hermes.Tools.MemoryTool do
  @moduledoc """
  Memory tool for durable key-value notes.

  Minimal port of `tools/memory_tool.py:1040`. Stores entries in the
  `state_meta` table (from A4) using the `Hermes.Sessions.StateMeta` schema.
  Targets:
    * `profile` / `user` — user profile facts.
    * `notes` / `memory` — session notes and environment facts.
  """

  import Ecto.Query

  alias Hermes.Repo
  alias Hermes.Sessions.StateMeta

  @type context :: %{repo: module()} | %{}

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "memory",
        toolset: "memory",
        schema: memory_schema(),
        handler: &invoke/2,
        check_fn: &always_available/0
      }
    ]
  end

  @doc """
  Dispatches a memory action and returns a JSON-encodable result.
  """
  @spec invoke(map(), context()) :: map()
  def invoke(args, context) do
    repo = Map.get(context, :repo, Repo)
    target = normalize_target(Map.get(args, "target", "notes"))

    operations = Map.get(args, "operations")

    if is_list(operations) do
      results =
        Enum.map(operations, fn op ->
          apply_op(op, target, repo)
        end)

      %{"success" => true, "results" => results}
    else
      apply_op(args, target, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  defp apply_op(%{"action" => "add"} = op, target, repo) do
    content = Map.get(op, "content")

    if is_nil(content) or not is_binary(content) or String.trim(content) == "" do
      %{"success" => false, "error" => "content is required for add"}
    else
      key = "#{target}:#{System.unique_integer([:positive])}"

      %StateMeta{}
      |> StateMeta.changeset(%{key: key, value: content})
      |> repo.insert!()

      %{"success" => true, "action" => "add", "key" => key}
    end
  end

  defp apply_op(%{"action" => "list"}, target, repo) do
    entries = list_entries(target, repo)

    %{
      "success" => true,
      "action" => "list",
      "target" => target,
      "entries" => entries,
      "count" => length(entries)
    }
  end

  defp apply_op(%{"action" => "get"} = op, target, repo) do
    content_filter = Map.get(op, "content")

    entries =
      if is_binary(content_filter) and String.trim(content_filter) != "" do
        target
        |> list_entries(repo)
        |> Enum.filter(fn entry ->
          String.contains?(entry["value"], content_filter)
        end)
      else
        list_entries(target, repo)
      end

    %{
      "success" => true,
      "action" => "get",
      "target" => target,
      "entries" => entries,
      "count" => length(entries)
    }
  end

  defp apply_op(%{"action" => "replace"} = op, target, repo) do
    old_text = Map.get(op, "old_text")
    new_text = Map.get(op, "content")

    cond do
      is_nil(old_text) or not is_binary(old_text) or String.trim(old_text) == "" ->
        %{"success" => false, "error" => "old_text is required for replace"}

      is_nil(new_text) ->
        %{"success" => false, "error" => "content is required for replace"}

      true ->
        case find_first_matching(target, old_text, repo) do
          nil ->
            %{"success" => false, "error" => "no matching entry found"}

          entry ->
            new_value = String.replace(entry.value, old_text, new_text, global: false)

            entry
            |> StateMeta.changeset(%{value: new_value})
            |> repo.update!()

            %{"success" => true, "action" => "replace", "key" => entry.key}
        end
    end
  end

  defp apply_op(%{"action" => "delete"} = op, target, repo) do
    old_text = Map.get(op, "old_text")

    query =
      from(sm in StateMeta,
        where: like(sm.key, ^"#{target}:%")
      )

    query =
      if is_binary(old_text) and String.trim(old_text) != "" do
        from(sm in query, where: like(sm.value, ^"%#{old_text}%"))
      else
        query
      end

    {count, _} = repo.delete_all(query)

    %{"success" => true, "action" => "delete", "deleted" => count}
  end

  defp apply_op(op, _target, _repo) do
    action = Map.get(op, "action", "<missing>")
    %{"success" => false, "error" => "unknown memory action: #{action}"}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_target(target) when is_binary(target) do
    case String.downcase(String.trim(target)) do
      "user" -> "profile"
      "profile" -> "profile"
      "memory" -> "notes"
      "notes" -> "notes"
      other -> other
    end
  end

  defp normalize_target(_), do: "notes"

  defp list_entries(target, repo) do
    StateMeta
    |> where([sm], like(sm.key, ^"#{target}:%"))
    |> select([sm], %{key: sm.key, value: sm.value})
    |> repo.all()
    |> Enum.map(fn %{key: k, value: v} -> %{"key" => k, "value" => v} end)
  end

  defp find_first_matching(target, substring, repo) do
    StateMeta
    |> where([sm], like(sm.key, ^"#{target}:%"))
    |> where([sm], like(sm.value, ^"%#{substring}%"))
    |> select([sm], sm)
    |> limit(1)
    |> repo.one()
  end

  defp always_available, do: true

  # ---------------------------------------------------------------------------
  # Schema
  # ---------------------------------------------------------------------------

  defp memory_schema do
    %{
      name: "memory",
      description: "Save durable facts to persistent memory.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["add", "replace", "get", "list", "delete"],
            description: "Memory action to perform."
          },
          target: %{
            type: "string",
            enum: ["profile", "user", "notes", "memory"],
            description: "Which memory store to target.",
            default: "notes"
          },
          content: %{
            type: "string",
            description: "Entry content for add/replace; filter for get."
          },
          old_text: %{
            type: "string",
            description: "Text identifying the entry to replace or delete."
          },
          operations: %{
            type: "array",
            description: "Batch of memory operations.",
            items: %{
              type: "object",
              properties: %{
                action: %{
                  type: "string",
                  enum: ["add", "replace", "get", "list", "delete"]
                },
                target: %{type: "string"},
                content: %{type: "string"},
                old_text: %{type: "string"}
              },
              required: ["action"]
            }
          }
        },
        required: ["action"]
      }
    }
  end
end
