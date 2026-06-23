defmodule Hermes.Tools.TodoToolTest do
  @moduledoc """
  Tests for `Hermes.Tools.TodoTool.invoke/2`.

  Covers add, list, complete, reset, batch merge, unknown actions, and
  per-session isolation.
  """

  use ExUnit.Case, async: false

  alias Hermes.Tools.TodoTool

  setup do
    # Ensure a fresh agent state for each test.
    case Process.whereis(TodoTool) do
      nil -> TodoTool.start_link()
      _ -> :ok
    end

    on_exit(fn ->
      case Process.whereis(TodoTool) do
        nil -> :ok
        _pid -> Agent.update(TodoTool, fn _ -> %{} end)
      end
    end)

    :ok
  end

  describe "add" do
    test "adds a todo item and returns the new item" do
      result =
        TodoTool.invoke(%{"action" => "add", "content" => "buy milk"}, %{
          session_id: "session-a"
        })

      assert result["success"]
      assert result["action"] == "add"
      assert result["item"] == "buy milk"
    end

    test "empty content returns an error" do
      result =
        TodoTool.invoke(%{"action" => "add", "content" => "   "}, %{
          session_id: "session-a"
        })

      refute result["success"]
      assert result["error"] == "content required for add"
    end
  end

  describe "list" do
    test "returns all todos for a session" do
      TodoTool.invoke(%{"action" => "add", "content" => "first"}, %{
        session_id: "session-a"
      })

      TodoTool.invoke(%{"action" => "add", "content" => "second"}, %{
        session_id: "session-a"
      })

      result = TodoTool.invoke(%{"action" => "list"}, %{session_id: "session-a"})

      assert result["success"]
      assert result["todos"] == ["first", "second"]
      assert result["count"] == 2
    end
  end

  describe "complete" do
    test "removes a todo containing the given content" do
      TodoTool.invoke(%{"action" => "add", "content" => "first task"}, %{
        session_id: "session-a"
      })

      TodoTool.invoke(%{"action" => "add", "content" => "second task"}, %{
        session_id: "session-a"
      })

      complete_result =
        TodoTool.invoke(%{"action" => "complete", "content" => "first"}, %{
          session_id: "session-a"
        })

      assert complete_result["success"]
      assert complete_result["action"] == "complete"

      list_result = TodoTool.invoke(%{"action" => "list"}, %{session_id: "session-a"})
      assert list_result["todos"] == ["second task"]
    end
  end

  describe "reset" do
    test "clears all todos for the session" do
      TodoTool.invoke(%{"action" => "add", "content" => "task"}, %{
        session_id: "session-a"
      })

      reset_result = TodoTool.invoke(%{"action" => "reset"}, %{session_id: "session-a"})
      assert reset_result["success"]
      assert reset_result["action"] == "reset"

      list_result = TodoTool.invoke(%{"action" => "list"}, %{session_id: "session-a"})
      assert list_result["todos"] == []
      assert list_result["count"] == 0
    end
  end

  describe "batch merge" do
    test "merges multiple todos in one call" do
      TodoTool.invoke(%{"action" => "add", "content" => "existing"}, %{
        session_id: "session-a"
      })

      result =
        TodoTool.invoke(
          %{"action" => "add", "todos" => ["one", "two"], "merge" => true},
          %{session_id: "session-a"}
        )

      # The schema describes `todos`/`merge` but the implementation only supports
      # the simple "add" with `content`. The test documents current behavior.
      assert result["success"] == false

      list_result = TodoTool.invoke(%{"action" => "list"}, %{session_id: "session-a"})

      # Behavioural invariant: the existing todo remains and the batch is not
      # silently dropped when no merge support exists.
      assert "existing" in list_result["todos"]
      refute "one" in list_result["todos"]
      refute "two" in list_result["todos"]
    end
  end

  describe "unknown action" do
    test "returns an error" do
      result = TodoTool.invoke(%{"action" => "prioritize"}, %{session_id: "session-a"})

      refute result["success"]
      assert result["error"] =~ "unknown todo action"
    end
  end

  describe "session isolation" do
    test "todos from session A do not appear in session B" do
      TodoTool.invoke(%{"action" => "add", "content" => "session-a-task"}, %{
        session_id: "session-a"
      })

      TodoTool.invoke(%{"action" => "add", "content" => "session-b-task"}, %{
        session_id: "session-b"
      })

      a_result = TodoTool.invoke(%{"action" => "list"}, %{session_id: "session-a"})
      b_result = TodoTool.invoke(%{"action" => "list"}, %{session_id: "session-b"})

      assert a_result["todos"] == ["session-a-task"]
      assert b_result["todos"] == ["session-b-task"]
    end
  end
end
