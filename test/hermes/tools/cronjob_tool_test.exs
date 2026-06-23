defmodule Hermes.Tools.CronjobToolTest do
  @moduledoc """
  Tests for `Hermes.Tools.CronjobTool.invoke/2`.

  Covers schedule, list, delete, and error paths. Uses `Hermes.DataCase` because
  the tool persists routines through Ecto/Oban.
  """

  use Hermes.DataCase, async: false

  alias Hermes.Cronjob.Routine
  alias Hermes.Repo
  alias Hermes.Tools.CronjobTool

  describe "schedule" do
    test "valid cron expression schedules a routine and returns its id" do
      result =
        CronjobTool.invoke(%{
          "action" => "schedule",
          "name" => "morning-summary",
          "cron" => "0 9 * * *",
          "prompt" => "Summarize yesterday",
          "session_id" => "session-a"
        }, %{})

      assert result["success"]
      assert is_integer(result["routine_id"])
      assert result["name"] == "morning-summary"
      assert result["cron"] == "0 9 * * *"
      assert result["message"] =~ "scheduled"
      assert is_binary(result["next_run_at"])

      assert %Routine{name: "morning-summary"} = Repo.get(Routine, result["routine_id"])
    end

    test "invalid cron expression returns an error" do
      result =
        CronjobTool.invoke(%{
          "action" => "schedule",
          "name" => "broken",
          "cron" => "not a cron",
          "prompt" => "nope",
          "session_id" => "session-a"
        }, %{})

      refute result["success"]
      assert result["error"] =~ "Invalid cron expression"
    end
  end

  describe "list" do
    test "returns all scheduled routines" do
      CronjobTool.invoke(%{
        "action" => "schedule",
        "name" => "routine-a",
        "cron" => "0 10 * * *",
        "prompt" => "A"
      }, %{"session_id" => "session-a"})

      CronjobTool.invoke(%{
        "action" => "schedule",
        "name" => "routine-b",
        "cron" => "0 11 * * *",
        "prompt" => "B"
      }, %{"session_id" => "session-b"})

      result = CronjobTool.invoke(%{"action" => "list"}, %{"session_id" => "session-a"})

      assert result["success"]
      assert result["count"] == 2
      names = Enum.map(result["routines"], & &1["name"])
      assert "routine-a" in names
      assert "routine-b" in names
    end
  end

  describe "delete" do
    test "deletes a routine by id" do
      schedule_result =
        CronjobTool.invoke(%{
          "action" => "schedule",
          "name" => "to-delete-by-id",
          "cron" => "0 12 * * *",
          "prompt" => "delete me"
        }, %{})

      id = schedule_result["routine_id"]

      delete_result =
        CronjobTool.invoke(%{
          "action" => "delete",
          "id" => to_string(id)
        }, %{})

      assert delete_result["success"]
      assert delete_result["routine_id"] == id
      assert delete_result["message"] =~ "removed"
      assert Repo.get(Routine, id) == nil
    end

    test "deletes a routine by name" do
      CronjobTool.invoke(%{
        "action" => "schedule",
        "name" => "to-delete-by-name",
        "cron" => "0 13 * * *",
        "prompt" => "delete me"
      }, %{})

      delete_result =
        CronjobTool.invoke(%{
          "action" => "delete",
          "name" => "to-delete-by-name"
        }, %{})

      assert delete_result["success"]
      assert delete_result["message"] =~ "removed"

      assert Repo.get_by(Routine, name: "to-delete-by-name") == nil
    end
  end

  describe "unknown action" do
    test "returns an error for an unsupported action" do
      result = CronjobTool.invoke(%{"action" => "dance"}, %{"session_id" => "session-a"})

      refute result["success"]
      assert result["error"] =~ "Unknown cron action"
    end
  end
end
