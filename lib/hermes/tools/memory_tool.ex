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
  alias Hermes.Sessions.Search
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
        search_entries(target, content_filter, repo)
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
    prefix = "#{target}:%"

    count =
      if is_binary(old_text) and String.trim(old_text) != "" do
        case Search.sanitize_fts5_query(old_text) do
          "" ->
            delete_all_by_prefix(prefix, repo)

          sanitized ->
            delete_matching(prefix, sanitized, repo)
        end
      else
        delete_all_by_prefix(prefix, repo)
      end

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
    prefix = "#{target}:%"
    query = Search.sanitize_fts5_query(substring)

    if query == "" do
      nil
    else
      sql = """
      SELECT sm.key
      FROM state_meta AS sm
      JOIN state_meta_fts ON state_meta_fts.rowid = sm.rowid
      WHERE state_meta_fts MATCH ? AND sm.key LIKE ?
      LIMIT 1
      """

      case repo.query(sql, [query, prefix]) do
        {:ok, %{rows: [[key] | _]}} -> repo.get(StateMeta, key)
        _ -> nil
      end
    end
  end

  defp search_entries(target, query, repo) do
    prefix = "#{target}:%"
    query = Search.sanitize_fts5_query(query)

    if query == "" do
      list_entries(target, repo)
    else
      sql = """
      SELECT sm.key, sm.value
      FROM state_meta AS sm
      JOIN state_meta_fts ON state_meta_fts.rowid = sm.rowid
      WHERE state_meta_fts MATCH ? AND sm.key LIKE ?
      """

      case repo.query(sql, [query, prefix]) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [k, v] -> %{"key" => k, "value" => v} end)

        {:error, _} ->
          []
      end
    end
  end

  defp delete_all_by_prefix(prefix, repo) do
    {count, _} =
      StateMeta
      |> where([sm], like(sm.key, ^prefix))
      |> repo.delete_all()

    count
  end

  defp delete_matching(prefix, fts_query, repo) do
    sql = """
    DELETE FROM state_meta
    WHERE rowid IN (
      SELECT state_meta_fts.rowid
      FROM state_meta_fts
      JOIN state_meta AS sm ON sm.rowid = state_meta_fts.rowid
      WHERE state_meta_fts MATCH ? AND sm.key LIKE ?
    )
    """

    case repo.query(sql, [fts_query, prefix]) do
      {:ok, %{num_rows: count}} -> count
      {:error, _} -> 0
    end
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
