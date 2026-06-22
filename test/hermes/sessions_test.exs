defmodule Hermes.SessionsTest do
  use ExUnit.Case, async: true

  alias Hermes.Sessions

  describe "start_session/0 and start_session/1" do
    test "starts a session with default initial state" do
      assert {:ok, pid, session_id} = Sessions.start_session()
      assert is_pid(pid)
      assert is_binary(session_id)

      state = Sessions.get_session(pid)

      assert state.session_id == session_id
      assert state.messages == []
      assert state.model == "claude-sonnet-4-20250514"
      assert state.provider == :anthropic
      assert state.api_mode == "anthropic_messages"
      assert state.max_iterations == 90
      assert state.iteration_budget_used == 0
      assert state.budget_grace_call == false
      assert state.status == :idle
    end

    test "accepts overrides for model, provider, and max_iterations" do
      assert {:ok, pid, _session_id} =
               Sessions.start_session(
                 model: "gpt-4o",
                 provider: :openai,
                 api_mode: "openai_chat",
                 max_iterations: 10
               )

      state = Sessions.get_session(pid)
      assert state.model == "gpt-4o"
      assert state.provider == :openai
      assert state.api_mode == "openai_chat"
      assert state.max_iterations == 10
    end
  end

  describe "add_message/2 and set_status/2" do
    test "appends messages to the session state" do
      assert {:ok, pid, _session_id} = Sessions.start_session()

      assert :ok = Sessions.add_message(pid, %{role: "user", content: "hello"})
      assert :ok = Sessions.add_message(pid, %{role: "assistant", content: "hi"})

      state = Sessions.get_session(pid)
      assert length(state.messages) == 2
      assert Enum.at(state.messages, 0) == %{role: "user", content: "hello"}
      assert Enum.at(state.messages, 1) == %{role: "assistant", content: "hi"}
    end

    test "updates session status" do
      assert {:ok, pid, _session_id} = Sessions.start_session()

      assert :ok = Sessions.set_status(pid, :running)
      assert Sessions.get_session(pid).status == :running

      assert :ok = Sessions.set_status(pid, :stopped)
      assert Sessions.get_session(pid).status == :stopped
    end
  end

  describe "fault isolation" do
    test "crashing one session does not kill another session" do
      assert {:ok, pid1, _id1} = Sessions.start_session()
      assert {:ok, pid2, _id2} = Sessions.start_session()

      Process.exit(pid1, :kill)
      refute Process.alive?(pid1)

      # Give the supervisor a moment to react, then confirm the other session
      # remains alive and accessible.
      assert Process.alive?(pid2)
      assert %{provider: :anthropic} = Sessions.get_session(pid2)
    end

    test "crashing turn task returns session to idle" do
      assert {:ok, pid, session_id} = Sessions.start_session(max_iterations: -1)
      assert :ok = Sessions.run_turn_async(session_id, "hello")

      # The invalid max_iterations causes IterationBudget.new(-1) to raise
      # inside TurnLoop.run before its own try/catch. The wrapper around
      # run_turn_in_task must cast :turn_finished with ok: false so the
      # session transitions back to idle instead of staying stuck in :running.
      assert wait_for_status(pid, :idle, 100)
      assert Sessions.get_session(pid).status == :idle
    end
  end

  describe "stop_session/1" do
    test "stops a session cleanly" do
      assert {:ok, pid, _session_id} = Sessions.start_session()
      assert Process.alive?(pid)

      assert :ok = Sessions.stop_session(pid)
      refute Process.alive?(pid)

      assert {:error, :not_found} = Sessions.stop_session(pid)
    end
  end

  # Wait up to `retries * 10ms` for the session to reach `status`.
  defp wait_for_status(pid, status, retries) do
    if Sessions.get_session(pid).status == status do
      true
    else
      if retries > 0 do
        Process.sleep(10)
        wait_for_status(pid, status, retries - 1)
      else
        false
      end
    end
  end
end
