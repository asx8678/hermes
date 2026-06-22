defmodule Hermes.ApprovalsTest do
  use ExUnit.Case, async: false

  alias Hermes.Approvals

  describe "required?/1" do
    test "file-modifying tools require approval (config :file_write)" do
      assert Approvals.required?("write_file")
      assert Approvals.required?("patch")
    end

    test "read-only tools do not require approval" do
      refute Approvals.required?("read_file")
      refute Approvals.required?("session_search")
    end
  end

  describe "request/respond round trip" do
    setup do
      session_id = "appr-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Hermes.PubSub, "session:#{session_id}")
      %{session_id: session_id}
    end

    test "an approved response unblocks the requester with :approved", %{session_id: sid} do
      task = Task.async(fn -> Approvals.request(sid, "write_file", %{}, timeout: 2_000) end)

      assert_receive {:approval_request, %{approval_id: id, tool: "write_file"}}, 1_000
      Approvals.respond(id, true)

      assert Task.await(task) == :approved
    end

    test "a rejected response yields :denied", %{session_id: sid} do
      task = Task.async(fn -> Approvals.request(sid, "patch", %{}, timeout: 2_000) end)

      assert_receive {:approval_request, %{approval_id: id}}, 1_000
      Approvals.respond(id, false)

      assert Task.await(task) == :denied
    end

    test "no response within the timeout denies by default", %{session_id: sid} do
      assert Approvals.request(sid, "write_file", %{}, timeout: 100) == :denied
    end
  end
end
