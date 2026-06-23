defmodule Hermes.Tools.KanbanTool do
  @moduledoc """
  Kanban board tools.

  Port of `tools/kanban_tools.py` and `hermes_cli/kanban_db.py`.
  Stores tasks, comments, and links in SQLite via Ecto.
  """

  alias Hermes.Kanban.Task
  alias Hermes.Repo

  import Ecto.Query

  @valid_statuses ~w(triage todo scheduled ready running blocked review done archived)
  @default_limit 50
  @max_limit 200

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      entry("kanban_show", &handle_show/2, show_schema()),
      entry("kanban_list", &handle_list/2, list_schema()),
      entry("kanban_complete", &handle_complete/2, complete_schema()),
      entry("kanban_block", &handle_block/2, block_schema()),
      entry("kanban_heartbeat", &handle_heartbeat/2, heartbeat_schema()),
      entry("kanban_comment", &handle_comment/2, comment_schema()),
      entry("kanban_create", &handle_create/2, create_schema()),
      entry("kanban_link", &handle_link/2, link_schema()),
      entry("kanban_unblock", &handle_unblock/2, unblock_schema())
    ]
  end

  # ---------------------------------------------------------------------------
  # Handlers
  # ---------------------------------------------------------------------------

  def handle_show(args, _context) do
    task_id = default_task_id(args["task_id"])

    if is_nil(task_id) or task_id == "" do
      %{"success" => false, "error" => "task_id is required"}
    else
      case Repo.get(Task, task_id) do
        nil ->
          %{"success" => false, "error" => "task not found: #{task_id}"}

        task ->
          comments =
            Repo.all(
              from(c in "kanban_comments",
                where: c.task_id == ^task_id,
                select: %{
                  id: c.id,
                  task_id: c.task_id,
                  author: c.author,
                  body: c.body,
                  inserted_at: c.inserted_at
                }
              )
            )

          %{
            "success" => true,
            "task" => serialize_task(task),
            "comments" => Enum.map(comments, &serialize_comment/1),
            "links" => fetch_links(task_id)
          }
      end
    end
  end

  def handle_list(args, _context) do
    limit = clamp_limit(args["limit"])

    query =
      from(t in Task)
      |> filter_status(args["status"])
      |> filter_assignee(args["assignee"])
      |> filter_tenant(args["tenant"])
      |> filter_archived(args["include_archived"])
      |> order_by([t], desc: t.priority, asc: t.inserted_at)
      |> limit(^limit)

    tasks = Repo.all(query)

    %{
      "success" => true,
      "count" => length(tasks),
      "tasks" => Enum.map(tasks, &serialize_task_summary/1)
    }
  end

  def handle_complete(args, _context) do
    task_id = default_task_id(args["task_id"])

    cond do
      is_nil(task_id) or task_id == "" ->
        %{"success" => false, "error" => "task_id is required"}

      is_nil(args["summary"]) and is_nil(args["result"]) ->
        %{"success" => false, "error" => "provide at least one of summary or result"}

      true ->
        now = DateTime.utc_now()
        metadata = encode_metadata(args["metadata"])

        case Repo.get(Task, task_id) do
          nil ->
            %{"success" => false, "error" => "task not found: #{task_id}"}

          task when task.status in ["done", "archived"] ->
            %{"success" => false, "error" => "task already terminal"}

          task ->
            changes = %{
              status: "done",
              completed_at: now,
              result: args["result"] || task.result,
              metadata: metadata
            }

            changes =
              if args["summary"] do
                Map.put(changes, :result, (args["result"] || "") <> "\n" <> args["summary"])
              else
                changes
              end

            Task.changeset(task, changes) |> Repo.update!()

            # Promote children whose parents are all done.
            promote_ready_children()

            %{"success" => true, "task_id" => task_id, "status" => "done"}
        end
    end
  end

  def handle_block(args, _context) do
    task_id = default_task_id(args["task_id"])
    reason = args["reason"]

    cond do
      is_nil(task_id) or task_id == "" ->
        %{"success" => false, "error" => "task_id is required"}

      not is_binary(reason) or String.trim(reason) == "" ->
        %{"success" => false, "error" => "reason is required"}

      true ->
        case Repo.get(Task, task_id) do
          nil ->
            %{"success" => false, "error" => "task not found: #{task_id}"}

          task when task.status not in ["running", "ready"] ->
            %{"success" => false, "error" => "task must be running or ready to block"}

          task ->
            comment_id = generate_id()
            now = DateTime.utc_now()

            Repo.insert_all("kanban_comments", [
              %{
                id: comment_id,
                task_id: task_id,
                author: "worker",
                body: "Blocked: #{reason}",
                inserted_at: now,
                updated_at: now
              }
            ])

            Task.changeset(task, %{status: "blocked"}) |> Repo.update!()

            %{"success" => true, "task_id" => task_id, "status" => "blocked"}
        end
    end
  end

  def handle_heartbeat(args, _context) do
    task_id = default_task_id(args["task_id"])

    if is_nil(task_id) or task_id == "" do
      %{"success" => false, "error" => "task_id is required"}
    else
      case Repo.get(Task, task_id) do
        nil ->
          %{"success" => false, "error" => "task not found: #{task_id}"}

        task when task.status != "running" ->
          %{"success" => false, "error" => "task must be running to heartbeat"}

        task ->
          note = args["note"]
          now = DateTime.utc_now()

          if is_binary(note) and String.trim(note) != "" do
            Repo.insert_all("kanban_comments", [
              %{
                id: generate_id(),
                task_id: task_id,
                author: "worker",
                body: "Heartbeat: #{note}",
                inserted_at: now,
                updated_at: now
              }
            ])
          end

          Task.changeset(task, %{claim_expires: future_timestamp(now, 300)})
          |> Repo.update!()

          %{"success" => true, "task_id" => task_id, "status" => "running"}
      end
    end
  end

  def handle_comment(args, _context) do
    task_id = args["task_id"]
    body = args["body"]

    cond do
      is_nil(task_id) or task_id == "" ->
        %{"success" => false, "error" => "task_id is required"}

      not is_binary(body) or String.trim(body) == "" ->
        %{"success" => false, "error" => "body is required"}

      true ->
        now = DateTime.utc_now()

        Repo.insert_all("kanban_comments", [
          %{
            id: generate_id(),
            task_id: task_id,
            author: "worker",
            body: body,
            inserted_at: now,
            updated_at: now
          }
        ])

        %{"success" => true, "task_id" => task_id, "comment_id" => generate_id()}
    end
  end

  def handle_create(args, _context) do
    title = args["title"]
    assignee = args["assignee"]

    cond do
      not is_binary(title) or String.trim(title) == "" ->
        %{"success" => false, "error" => "title is required"}

      not is_binary(assignee) or String.trim(assignee) == "" ->
        %{"success" => false, "error" => "assignee is required"}

      true ->
        task_id = generate_id()
        now = DateTime.utc_now()
        status = initial_status(args["initial_status"], args["triage"])
        workspace_kind = normalize_workspace_kind(args["workspace_kind"])

        attrs = %{
          id: task_id,
          title: title,
          body: args["body"],
          assignee: assignee,
          status: status,
          priority: parse_int(args["priority"], 0),
          tenant: args["tenant"],
          workspace_kind: workspace_kind,
          workspace_path: args["workspace_path"],
          skills: encode_json(args["skills"]),
          metadata: encode_metadata(args["metadata"]),
          inserted_at: now,
          updated_at: now
        }

        Task.changeset(%Task{}, attrs) |> Repo.insert!()

        parents = normalize_list(args["parents"])

        Enum.each(parents, fn parent_id ->
          Repo.insert_all("kanban_links", [
            %{
              parent_id: parent_id,
              child_id: task_id,
              inserted_at: now,
              updated_at: now
            }
          ])
        end)

        # If created with no parents, move from todo to ready.
        if parents == [] do
          promote_ready_children()
        end

        %{
          "success" => true,
          "task_id" => task_id,
          "status" => status
        }
    end
  end

  def handle_link(args, _context) do
    parent_id = args["parent_id"]
    child_id = args["child_id"]

    cond do
      is_nil(parent_id) or parent_id == "" ->
        %{"success" => false, "error" => "parent_id is required"}

      is_nil(child_id) or child_id == "" ->
        %{"success" => false, "error" => "child_id is required"}

      parent_id == child_id ->
        %{"success" => false, "error" => "self-link is not allowed"}

      true ->
        now = DateTime.utc_now()

        Repo.insert_all(
          "kanban_links",
          [%{parent_id: parent_id, child_id: child_id, inserted_at: now, updated_at: now}],
          on_conflict: :nothing
        )

        promote_ready_children()

        %{"success" => true, "parent_id" => parent_id, "child_id" => child_id}
    end
  end

  def handle_unblock(args, _context) do
    task_id = args["task_id"]

    if is_nil(task_id) or task_id == "" do
      %{"success" => false, "error" => "task_id is required"}
    else
      case Repo.get(Task, task_id) do
        nil ->
          %{"success" => false, "error" => "task not found: #{task_id}"}

        task when task.status != "blocked" ->
          %{"success" => false, "error" => "task must be blocked to unblock"}

        task ->
          Task.changeset(task, %{status: "ready"}) |> Repo.update!()
          %{"success" => true, "task_id" => task_id, "status" => "ready"}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp entry(name, handler, schema) do
    %{
      name: name,
      toolset: "kanban",
      schema: schema,
      handler: handler,
      check_fn: &always_available/0
    }
  end

  defp default_task_id(nil) do
    System.get_env("HERMES_KANBAN_TASK")
  end

  defp default_task_id(""), do: System.get_env("HERMES_KANBAN_TASK")
  defp default_task_id(task_id), do: task_id

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp promote_ready_children do
    # Find todo/scheduled tasks where all parents are done.
    child_ids =
      Repo.all(
        from(t in Task,
          where: t.status in ["todo", "scheduled"],
          select: t.id
        )
      )

    Enum.each(child_ids, fn child_id ->
      parent_statuses =
        Repo.all(
          from(l in "kanban_links",
            join: t in Task,
            on: l.parent_id == t.id,
            where: l.child_id == ^child_id,
            select: t.status
          )
        )

      if parent_statuses != [] and Enum.all?(parent_statuses, &(&1 == "done")) do
        Repo.update_all(
          from(t in Task, where: t.id == ^child_id),
          set: [status: "ready"]
        )
      end
    end)
  end

  defp fetch_links(task_id) do
    parents =
      Repo.all(from(l in "kanban_links", where: l.child_id == ^task_id, select: l.parent_id))

    children =
      Repo.all(from(l in "kanban_links", where: l.parent_id == ^task_id, select: l.child_id))

    %{"parents" => parents, "children" => children}
  end

  defp filter_status(query, status) when status in @valid_statuses do
    where(query, [t], t.status == ^status)
  end

  defp filter_status(query, _), do: query

  defp filter_assignee(query, nil), do: query
  defp filter_assignee(query, ""), do: query
  defp filter_assignee(query, assignee), do: where(query, [t], t.assignee == ^assignee)

  defp filter_tenant(query, nil), do: query
  defp filter_tenant(query, ""), do: query
  defp filter_tenant(query, tenant), do: where(query, [t], t.tenant == ^tenant)

  defp filter_archived(query, true), do: query
  defp filter_archived(query, _), do: where(query, [t], t.status != "archived")

  defp clamp_limit(limit) do
    n = parse_int(limit, @default_limit)
    min(n, @max_limit)
  end

  defp parse_int(nil, default), do: default
  defp parse_int(n, _) when is_integer(n), do: n
  defp parse_int(_, default), do: default

  defp initial_status("blocked", _), do: "blocked"
  defp initial_status("running", _), do: "running"
  defp initial_status(_, true), do: "triage"
  defp initial_status(_, _), do: "todo"

  defp normalize_workspace_kind("dir"), do: "dir"
  defp normalize_workspace_kind("worktree"), do: "worktree"
  defp normalize_workspace_kind(_), do: "scratch"

  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: list
  defp normalize_list(_), do: []

  defp encode_json(nil), do: nil
  defp encode_json(list) when is_list(list), do: Jason.encode!(list)
  defp encode_json(_), do: nil

  defp encode_metadata(nil), do: nil
  defp encode_metadata(map) when is_map(map), do: Jason.encode!(map)
  defp encode_metadata(_), do: nil

  defp future_timestamp(%DateTime{} = dt, seconds) do
    DateTime.add(dt, seconds, :second) |> DateTime.to_unix()
  end

  defp serialize_task(task) do
    %{
      "id" => task.id,
      "title" => task.title,
      "body" => task.body,
      "assignee" => task.assignee,
      "status" => task.status,
      "priority" => task.priority,
      "tenant" => task.tenant,
      "created_at" => task.inserted_at,
      "started_at" => task.started_at,
      "completed_at" => task.completed_at,
      "workspace_kind" => task.workspace_kind,
      "workspace_path" => task.workspace_path,
      "metadata" => decode_json(task.metadata),
      "skills" => decode_json(task.skills)
    }
  end

  defp serialize_task_summary(task) do
    %{
      "id" => task.id,
      "title" => task.title,
      "status" => task.status,
      "assignee" => task.assignee,
      "priority" => task.priority,
      "created_at" => task.inserted_at
    }
  end

  defp serialize_comment(comment) do
    %{
      "id" => Map.get(comment, :id),
      "task_id" => Map.get(comment, :task_id),
      "author" => Map.get(comment, :author),
      "body" => Map.get(comment, :body),
      "created_at" => Map.get(comment, :inserted_at)
    }
  end

  defp decode_json(nil), do: nil

  defp decode_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp decode_json(_), do: nil

  defp always_available, do: true

  # ---------------------------------------------------------------------------
  # Schemas
  # ---------------------------------------------------------------------------

  defp show_schema do
    %{
      name: "kanban_show",
      description: "Show a kanban task's full state.",
      parameters: %{
        type: "object",
        properties: %{
          task_id: %{type: "string", description: "Task id."}
        },
        required: []
      }
    }
  end

  defp list_schema do
    %{
      name: "kanban_list",
      description:
        "List Kanban task summaries. Supports status, assignee, tenant, " <>
          "and archived filters.",
      parameters: %{
        type: "object",
        properties: %{
          status: %{
            type: "string",
            enum: ["triage", "todo", "ready", "running", "blocked", "done", "archived"]
          },
          assignee: %{type: "string"},
          tenant: %{type: "string"},
          include_archived: %{type: "boolean"},
          limit: %{type: "integer", description: "Default 50, max 200."}
        },
        required: []
      }
    }
  end

  defp complete_schema do
    %{
      name: "kanban_complete",
      description: "Mark a kanban task as done.",
      parameters: %{
        type: "object",
        properties: %{
          task_id: %{type: "string"},
          summary: %{type: "string"},
          result: %{type: "string"},
          metadata: %{type: "object"}
        },
        required: []
      }
    }
  end

  defp block_schema do
    %{
      name: "kanban_block",
      description: "Block a kanban task with a reason.",
      parameters: %{
        type: "object",
        properties: %{
          task_id: %{type: "string"},
          reason: %{type: "string"}
        },
        required: ["reason"]
      }
    }
  end

  defp heartbeat_schema do
    %{
      name: "kanban_heartbeat",
      description: "Record a heartbeat for a running kanban task.",
      parameters: %{
        type: "object",
        properties: %{
          task_id: %{type: "string"},
          note: %{type: "string"}
        },
        required: []
      }
    }
  end

  defp comment_schema do
    %{
      name: "kanban_comment",
      description: "Append a comment to a kanban task.",
      parameters: %{
        type: "object",
        properties: %{
          task_id: %{type: "string"},
          body: %{type: "string"}
        },
        required: ["task_id", "body"]
      }
    }
  end

  defp create_schema do
    %{
      name: "kanban_create",
      description: "Create a new kanban task.",
      parameters: %{
        type: "object",
        properties: %{
          title: %{type: "string"},
          assignee: %{type: "string"},
          body: %{type: "string"},
          parents: %{type: "array", items: %{type: "string"}},
          tenant: %{type: "string"},
          priority: %{type: "integer"},
          workspace_kind: %{type: "string", enum: ["scratch", "dir", "worktree"]},
          workspace_path: %{type: "string"},
          triage: %{type: "boolean"},
          initial_status: %{type: "string", enum: ["running", "blocked"]}
        },
        required: ["title", "assignee"]
      }
    }
  end

  defp link_schema do
    %{
      name: "kanban_link",
      description: "Add a parent->child dependency between kanban tasks.",
      parameters: %{
        type: "object",
        properties: %{
          parent_id: %{type: "string"},
          child_id: %{type: "string"}
        },
        required: ["parent_id", "child_id"]
      }
    }
  end

  defp unblock_schema do
    %{
      name: "kanban_unblock",
      description: "Move a blocked kanban task back to ready.",
      parameters: %{
        type: "object",
        properties: %{
          task_id: %{type: "string"}
        },
        required: ["task_id"]
      }
    }
  end
end
