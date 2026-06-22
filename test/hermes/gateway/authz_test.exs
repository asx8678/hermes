defmodule Hermes.Gateway.AuthzTest do
  @moduledoc """
  Tests for `Hermes.Gateway.Authz`.

  Verifies allowlist behaviour and the approval request/response flow.
  """

  use ExUnit.Case, async: false

  alias Hermes.Gateway.Authz
  alias Phoenix.PubSub

  setup do
    old_config = Application.get_env(:hermes, :gateway, [])

    Application.put_env(:hermes, :gateway,
      allowlist: [],
      approval_required: [:send_message, :execute_tool, :file_write],
      streaming_throttle_ms: 500
    )

    on_exit(fn ->
      Application.put_env(:hermes, :gateway, old_config)
    end)

    PubSub.subscribe(Hermes.PubSub, "gateway:approvals")

    :ok
  end

  describe "is_allowed?/2" do
    test "empty allowlist allows everyone" do
      assert Authz.is_allowed?(:telegram, "user-1")
      assert Authz.is_allowed?(:telegram, "user-2")
      assert Authz.is_allowed?(:unknown, "anyone")
    end

    test "specific user in allowlist is allowed" do
      Application.put_env(:hermes, :gateway,
        allowlist: ["user-1"],
        approval_required: [:send_message, :execute_tool, :file_write],
        streaming_throttle_ms: 500
      )

      assert Authz.is_allowed?(:telegram, "user-1")
      assert Authz.is_allowed?(:discord, "user-1")
    end

    test "user not in allowlist is denied" do
      Application.put_env(:hermes, :gateway,
        allowlist: ["user-1"],
        approval_required: [:send_message, :execute_tool, :file_write],
        streaming_throttle_ms: 500
      )

      refute Authz.is_allowed?(:telegram, "user-2")
      refute Authz.is_allowed?(:telegram, "intruder")
    end

    test "\"*\" in allowlist allows everyone" do
      Application.put_env(:hermes, :gateway,
        allowlist: ["*"],
        approval_required: [:send_message, :execute_tool, :file_write],
        streaming_throttle_ms: 500
      )

      assert Authz.is_allowed?(:telegram, "anyone")
    end

    test "connector-specific allowlist overrides global empty list" do
      Application.put_env(:hermes, :gateway,
        allowlist: [],
        connector_allowlist: [telegram: ["user-1"]],
        approval_required: [:send_message, :execute_tool, :file_write],
        streaming_throttle_ms: 500
      )

      assert Authz.is_allowed?(:telegram, "user-1")
      refute Authz.is_allowed?(:discord, "user-1")
    end
  end

  describe "requires_approval?/2" do
    test "default dangerous actions require approval" do
      assert Authz.requires_approval?(:telegram, :send_message)
      assert Authz.requires_approval?(:telegram, :execute_tool)
      assert Authz.requires_approval?(:telegram, :file_write)
    end

    test "unknown actions do not require approval" do
      refute Authz.requires_approval?(:telegram, :noop)
      refute Authz.requires_approval?(:telegram, :read_file)
    end

    test "connector-specific approval list is respected" do
      Application.put_env(:hermes, :gateway,
        allowlist: [],
        approval_required: [],
        connector_approval: [telegram: [:custom_action]],
        streaming_throttle_ms: 500
      )

      refute Authz.requires_approval?(:discord, :custom_action)
      assert Authz.requires_approval?(:telegram, :custom_action)
    end
  end

  describe "approval flow" do
    test "request_approval blocks until approved" do
      session_id = "session-approve"

      task =
        Task.async(fn ->
          Authz.request_approval(session_id, :file_write, %{path: "/tmp/x"})
        end)

      assert_receive {:approval_request, approval_id, ^session_id, :file_write, _details}, 1_000
      assert :ok = Authz.respond_to_approval(approval_id, true)
      assert {:ok, ^approval_id} = Task.await(task)
    end

    test "request_approval returns denied when rejected" do
      session_id = "session-deny"

      task =
        Task.async(fn ->
          Authz.request_approval(session_id, :file_write, %{path: "/tmp/x"})
        end)

      assert_receive {:approval_request, approval_id, ^session_id, :file_write, _details}, 1_000
      assert :ok = Authz.respond_to_approval(approval_id, false)
      assert {:denied, "approval denied"} = Task.await(task)
    end

    test "respond_to_approval returns not_found for unknown id" do
      assert {:error, :not_found} = Authz.respond_to_approval("does-not-exist", true)
    end
  end
end
