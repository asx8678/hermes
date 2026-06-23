defmodule Hermes.Tools.KanbanToolTest do
  use Hermes.DataCase, async: false

  alias Hermes.Kanban.Task
  alias Hermes.Repo
  alias Hermes.Tools.KanbanTool

  defp insert_task(attrs) do
    id = System.unique_integer([:positive]) |> Integer.to_string()

    %Task{id: id}
    |> Task.changeset(Map.merge(%{title: "Task #{id}", status: "todo", assignee: "tester"}, attrs))
    |> Repo.insert!()
  end

  describe "tool_entries/0" do
    test "returns 9 entries with expected names and toolset kanban" do
      entries = KanbanTool.tool_entries()

      names = Enum.map(entries, & &1.name)

      assert length(entries) == 9

      expected = [
        "kanban_show",
        "kanban_list",
        "kanban_complete",
        "kanban_block",
        "kanban_heartbeat",
        "kanban_comment",
        "kanban_create",
        "kanban_link",
        "kanban_unblock"
      ]

      assert Enum.sort(names) == Enum.sort(expected)
      assert Enum.all?(entries, &(&1.toolset == "kanban"))
      assert Enum.all?(entries, &is_function(&1.handler))
      assert Enum.all?(entries, &(&1.check_fn.() == true))
    end
  end

  describe "kanban_create" do
    test "with valid args returns success map with task_id and status" do
      result = KanbanTool.handle_create(%{"title" => "Build widget", "assignee" => "alice"}, %{})

      assert result["success"] == true
      assert is_binary(result["task_id"])
      assert result["status"] == "todo"

      task = Repo.get(Task, result["task_id"])
      assert task.title == "Build widget"
      assert task.assignee == "alice"
      assert task.status == "todo"
    end

    test "missing title returns error" do
      assert KanbanTool.handle_create(%{"assignee" => "alice"}, %{}) == %{
               "success" => false,
               "error" => "title is required"
             }

      assert KanbanTool.handle_create(%{"title" => "", "assignee" => "alice"}, %{}) == %{
               "success" => false,
               "error" => "title is required"
             }

      assert KanbanTool.handle_create(%{"title" => nil, "assignee" => "alice"}, %{}) == %{
               "success" => false,
               "error" => "title is required"
             }
    end

    test "missing assignee returns error" do
      assert KanbanTool.handle_create(%{"title" => "Build widget"}, %{}) == %{
               "success" => false,
               "error" => "assignee is required"
             }

      assert KanbanTool.handle_create(%{"title" => "Build widget", "assignee" => ""}, %{}) == %{
               "success" => false,
               "error" => "assignee is required"
             }

      assert KanbanTool.handle_create(%{"title" => "Build widget", "assignee" => nil}, %{}) == %{
               "success" => false,
               "error" => "assignee is required"
             }
    end

    test "with triage flag sets status to triage" do
      result =
        KanbanTool.handle_create(
          %{"title" => "Triage task", "assignee" => "alice", "triage" => true},
          %{}
        )

      assert result["status"] == "triage"
    end
  end

  describe "kanban_show" do
    test "for existing task returns task map with comments and links" do
      task = insert_task(%{status: "running"})

      now = DateTime.utc_now()

      Repo.insert_all("kanban_comments", [
        %{
          id: "comment-1",
          task_id: task.id,
          author: "worker",
          body: "note",
          inserted_at: now,
          updated_at: now
        }
      ])

      Repo.insert_all("kanban_links", [
        %{parent_id: "parent-1", child_id: task.id, inserted_at: now, updated_at: now}
      ])

      result = KanbanTool.handle_show(%{"task_id" => task.id}, %{})

      assert result["success"] == true
      assert result["task"]["id"] == task.id
      assert result["task"]["title"] == task.title
      assert result["task"]["status"] == "running"
      assert [%{"body" => "note"}] = result["comments"]
      assert result["links"]["parents"] == ["parent-1"]
      assert result["links"]["children"] == []
    end

    test "missing task_id returns error" do
      assert KanbanTool.handle_show(%{}, %{}) == %{
               "success" => false,
               "error" => "task_id is required"
             }

      assert KanbanTool.handle_show(%{"task_id" => ""}, %{}) == %{
               "success" => false,
               "error" => "task_id is required"
             }
    end

    test "for nonexistent task returns error" do
      assert KanbanTool.handle_show(%{"task_id" => "missing"}, %{}) == %{
               "success" => false,
               "error" => "task not found: missing"
             }
    end
  end

  describe "kanban_list" do
    test "returns count and tasks list" do
      insert_task(%{status: "ready"})
      insert_task(%{status: "running"})

      result = KanbanTool.handle_list(%{}, %{})

      assert result["success"] == true
      assert result["count"] == 2
      assert length(result["tasks"]) == 2

      assert Enum.all?(result["tasks"], fn t ->
               Map.keys(t) == ["assignee", "created_at", "id", "priority", "status", "title"]
             end)
    end

    test "filters by status" do
      insert_task(%{status: "ready"})
      insert_task(%{status: "running"})

      result = KanbanTool.handle_list(%{"status" => "running"}, %{})
      assert result["count"] == 1
      assert hd(result["tasks"])["status"] == "running"
    end

    test "invalid status filter is ignored" do
      insert_task(%{status: "ready"})

      result = KanbanTool.handle_list(%{"status" => "bogus"}, %{})
      assert result["count"] == 1
    end
  end

  describe "kanban_complete" do
    test "marks task done and includes summary/result" do
      task = insert_task(%{status: "running"})

      result =
        KanbanTool.handle_complete(
          %{"task_id" => task.id, "summary" => "Completed work", "result" => "result.txt"},
          %{}
        )

      assert result == %{"success" => true, "task_id" => task.id, "status" => "done"}

      completed = Repo.get(Task, task.id)
      assert completed.status == "done"
      assert completed.completed_at != nil
      assert completed.result == "result.txt\nCompleted work"
    end

    test "rejects terminal tasks" do
      task = insert_task(%{status: "done"})

      assert KanbanTool.handle_complete(
               %{"task_id" => task.id, "summary" => "again"},
               %{}
             ) == %{
               "success" => false,
               "error" => "task already terminal"
             }
    end
  end

  describe "kanban_block and kanban_unblock" do
    test "block running task, unblock returns ready" do
      task = insert_task(%{status: "running"})

      block_result =
        KanbanTool.handle_block(%{"task_id" => task.id, "reason" => "waiting for API"}, %{})

      assert block_result == %{
               "success" => true,
               "task_id" => task.id,
               "status" => "blocked"
             }

      blocked = Repo.get(Task, task.id)
      assert blocked.status == "blocked"

      unblock_result = KanbanTool.handle_unblock(%{"task_id" => task.id}, %{})

      assert unblock_result == %{
               "success" => true,
               "task_id" => task.id,
               "status" => "ready"
             }

      ready = Repo.get(Task, task.id)
      assert ready.status == "ready"
    end

    test "block requires reason" do
      task = insert_task(%{status: "running"})

      assert KanbanTool.handle_block(%{"task_id" => task.id}, %{}) == %{
               "success" => false,
               "error" => "reason is required"
             }

      assert KanbanTool.handle_block(%{"task_id" => task.id, "reason" => ""}, %{}) == %{
               "success" => false,
               "error" => "reason is required"
             }
    end
  end

  describe "kanban_heartbeat" do
    test "on running task returns running" do
      task = insert_task(%{status: "running"})

      result = KanbanTool.handle_heartbeat(%{"task_id" => task.id, "note" => "still alive"}, %{})

      assert result == %{"success" => true, "task_id" => task.id, "status" => "running"}

      beat = Repo.get(Task, task.id)
      assert beat.claim_expires != nil
    end

    test "on non-running task returns error" do
      task = insert_task(%{status: "ready"})

      assert KanbanTool.handle_heartbeat(%{"task_id" => task.id}, %{}) == %{
               "success" => false,
               "error" => "task must be running to heartbeat"
             }
    end
  end

  describe "kanban_comment" do
    test "appends comment" do
      task = insert_task(%{status: "running"})

      result =
        KanbanTool.handle_comment(%{"task_id" => task.id, "body" => "progress note"}, %{})

      assert result["success"] == true
      assert result["task_id"] == task.id
      assert is_binary(result["comment_id"])

      comments =
        Repo.all(
          from(c in "kanban_comments",
            where: c.task_id == ^task.id,
            select: %{id: c.id, task_id: c.task_id, author: c.author, body: c.body, inserted_at: c.inserted_at}
          )
        )
      assert Enum.any?(comments, &(&1.body == "progress note"))
    end

    test "missing body returns error" do
      task = insert_task(%{})

      assert KanbanTool.handle_comment(%{"task_id" => task.id}, %{}) == %{
               "success" => false,
               "error" => "body is required"
             }

      assert KanbanTool.handle_comment(%{"task_id" => task.id, "body" => ""}, %{}) == %{
               "success" => false,
               "error" => "body is required"
             }
    end
  end

  describe "kanban_link" do
    test "creates parent-child link and promotes child to ready" do
      parent = insert_task(%{status: "todo"})
      child = insert_task(%{status: "todo"})

      result =
        KanbanTool.handle_link(%{"parent_id" => parent.id, "child_id" => child.id}, %{})

      assert result == %{
               "success" => true,
               "parent_id" => parent.id,
               "child_id" => child.id
             }

      links = Repo.all(from l in "kanban_links", where: l.child_id == ^child.id, select: l.parent_id)
      assert links == [parent.id]

      # The child stays todo because parent is not done.
      assert Repo.get(Task, child.id).status == "todo"

      # Complete parent, then create a new sibling child that should be promoted.
      KanbanTool.handle_complete(%{"task_id" => parent.id, "summary" => "done"}, %{})

      promoted = insert_task(%{status: "todo"})
      KanbanTool.handle_link(%{"parent_id" => parent.id, "child_id" => promoted.id}, %{})

      assert Repo.get(Task, promoted.id).status == "ready"
    end

    test "rejects self-link" do
      task = insert_task(%{})

      assert KanbanTool.handle_link(%{"parent_id" => task.id, "child_id" => task.id}, %{}) == %{
               "success" => false,
               "error" => "self-link is not allowed"
             }
    end
  end

  describe "edge cases" do
    test "create with whitespace-only title or assignee is rejected" do
      assert KanbanTool.handle_create(
               %{"title" => "   ", "assignee" => "alice"},
               %{}
             ) == %{
               "success" => false,
               "error" => "title is required"
             }

      assert KanbanTool.handle_create(
               %{"title" => "Build", "assignee" => "   "},
               %{}
             ) == %{
               "success" => false,
               "error" => "assignee is required"
             }
    end

    test "block requires running or ready status" do
      task = insert_task(%{status: "done"})

      assert KanbanTool.handle_block(%{"task_id" => task.id, "reason" => "reason"}, %{}) == %{
               "success" => false,
               "error" => "task must be running or ready to block"
             }
    end

    test "unblock requires blocked status" do
      task = insert_task(%{status: "todo"})

      assert KanbanTool.handle_unblock(%{"task_id" => task.id}, %{}) == %{
               "success" => false,
               "error" => "task must be blocked to unblock"
             }
    end

    test "complete requires at least summary or result" do
      task = insert_task(%{status: "running"})

      assert KanbanTool.handle_complete(%{"task_id" => task.id}, %{}) == %{
               "success" => false,
               "error" => "provide at least one of summary or result"
             }
    end
  end
end
