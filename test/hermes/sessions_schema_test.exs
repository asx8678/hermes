defmodule Hermes.SessionsSchemaTest do
  @moduledoc """
  Tests for the sessions, messages, state_meta, and compression_locks Ecto
  schemas, plus FTS5 virtual tables and triggers.

  Ported from the Python source:
  - `hermes_state.py:518-600` (schema)
  - `hermes_state.py:611-664` (FTS5)
  """

  use Hermes.DataCase, async: false

  alias Hermes.Repo
  alias Hermes.Sessions.CompressionLock
  alias Hermes.Sessions.Message
  alias Hermes.Sessions.Session
  alias Hermes.Sessions.StateMeta

  describe "Session schema" do
    test "inserts and queries a session with all fields" do
      session_id = "sess_#{System.unique_integer([:positive])}"

      attrs = %{
        id: session_id,
        source: "test_source",
        user_id: "user_123",
        model: "claude-sonnet-4-20250514",
        model_config: "{\"temperature\": 0.7}",
        system_prompt: "You are a helpful assistant.",
        parent_session_id: nil,
        started_at: 1_718_000_000.0,
        ended_at: nil,
        end_reason: nil,
        message_count: 5,
        tool_call_count: 2,
        input_tokens: 100,
        output_tokens: 50,
        cache_read_tokens: 10,
        cache_write_tokens: 5,
        reasoning_tokens: 20,
        cwd: "/tmp",
        billing_provider: "anthropic",
        billing_base_url: "https://api.anthropic.com",
        billing_mode: "token",
        estimated_cost_usd: 0.0123,
        actual_cost_usd: 0.0100,
        cost_status: "estimated",
        cost_source: "provider",
        pricing_version: "v1",
        title: "Test Session",
        api_call_count: 3,
        handoff_state: nil,
        handoff_platform: nil,
        handoff_error: nil,
        rewind_count: 1,
        archived: 0
      }

      assert {:ok, inserted} =
               %Session{}
               |> Session.changeset(attrs)
               |> Repo.insert()

      queried = Repo.get!(Session, session_id)

      assert queried.id == session_id
      assert queried.source == "test_source"
      assert queried.user_id == "user_123"
      assert queried.model == "claude-sonnet-4-20250514"
      assert queried.model_config == "{\"temperature\": 0.7}"
      assert queried.system_prompt == "You are a helpful assistant."
      assert queried.parent_session_id == nil
      assert queried.started_at == 1_718_000_000.0
      assert queried.ended_at == nil
      assert queried.message_count == 5
      assert queried.tool_call_count == 2
      assert queried.input_tokens == 100
      assert queried.output_tokens == 50
      assert queried.cache_read_tokens == 10
      assert queried.cache_write_tokens == 5
      assert queried.reasoning_tokens == 20
      assert queried.cwd == "/tmp"
      assert queried.billing_provider == "anthropic"
      assert queried.billing_base_url == "https://api.anthropic.com"
      assert queried.billing_mode == "token"
      assert queried.estimated_cost_usd == 0.0123
      assert queried.actual_cost_usd == 0.0100
      assert queried.cost_status == "estimated"
      assert queried.cost_source == "provider"
      assert queried.pricing_version == "v1"
      assert queried.title == "Test Session"
      assert queried.api_call_count == 3
      assert queried.rewind_count == 1
      assert queried.archived == 0

      assert inserted.id == session_id
    end

    test "validates required fields" do
      changeset = Session.changeset(%Session{}, %{source: "missing_id"})
      assert %{started_at: ["can't be blank"], id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "Message schema" do
    test "inserts and queries messages for a session" do
      session_id = "sess_msg_#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               %Session{}
               |> Session.changeset(%{
                 id: session_id,
                 source: "test_source",
                 started_at: 1_718_000_000.0
               })
               |> Repo.insert()

      msg_attrs = %{
        session_id: session_id,
        role: "user",
        content: "Hello, assistant!",
        timestamp: 1_718_000_001.0,
        token_count: 3,
        observed: 0,
        active: 1,
        compacted: 0
      }

      assert {:ok, inserted} =
               %Message{}
               |> Message.changeset(msg_attrs)
               |> Repo.insert()

      queried = Repo.get!(Message, inserted.id)

      assert queried.session_id == session_id
      assert queried.role == "user"
      assert queried.content == "Hello, assistant!"
      assert queried.timestamp == 1_718_000_001.0
      assert queried.token_count == 3
      assert queried.observed == 0
      assert queried.active == 1
      assert queried.compacted == 0
      assert is_integer(queried.id)

      assistant_attrs = %{
        session_id: session_id,
        role: "assistant",
        content: "Hi there!",
        tool_calls: "[{\"id\": \"call_1\"}]",
        tool_name: "greet",
        timestamp: 1_718_000_002.0,
        finish_reason: "stop"
      }

      assert {:ok, _} =
               %Message{}
               |> Message.changeset(assistant_attrs)
               |> Repo.insert()

      messages =
        Message
        |> where(session_id: ^session_id)
        |> order_by(asc: :timestamp)
        |> Repo.all()

      assert length(messages) == 2
      assert Enum.at(messages, 0).role == "user"
      assert Enum.at(messages, 1).role == "assistant"
      assert Enum.at(messages, 1).tool_calls == "[{\"id\": \"call_1\"}]"
      assert Enum.at(messages, 1).tool_name == "greet"
      assert Enum.at(messages, 1).finish_reason == "stop"
    end

    test "validates required fields" do
      changeset = Message.changeset(%Message{}, %{content: "missing session"})

      assert %{
               session_id: ["can't be blank"],
               role: ["can't be blank"],
               timestamp: ["can't be blank"]
             } =
               errors_on(changeset)
    end
  end

  describe "StateMeta schema" do
    test "inserts and queries by key" do
      attrs = %{key: "last_checkpoint", value: "checkpoint_42"}

      assert {:ok, inserted} =
               %StateMeta{}
               |> StateMeta.changeset(attrs)
               |> Repo.insert()

      queried = Repo.get!(StateMeta, "last_checkpoint")
      assert queried.key == "last_checkpoint"
      assert queried.value == "checkpoint_42"
      assert inserted.key == "last_checkpoint"

      # Upsert semantics via replace_all
      assert {:ok, _} =
               %StateMeta{}
               |> StateMeta.changeset(%{key: "last_checkpoint", value: "checkpoint_43"})
               |> Repo.insert(
                 on_conflict: [set: [value: "checkpoint_43"]],
                 conflict_target: :key
               )

      assert Repo.get!(StateMeta, "last_checkpoint").value == "checkpoint_43"
    end
  end

  describe "CompressionLock schema" do
    test "inserts and queries a compression lock" do
      session_id = "sess_lock_#{System.unique_integer([:positive])}"

      attrs = %{
        session_id: session_id,
        holder: "worker_1",
        acquired_at: 1_718_000_000.0,
        expires_at: 1_718_000_300.0
      }

      assert {:ok, inserted} =
               %CompressionLock{}
               |> CompressionLock.changeset(attrs)
               |> Repo.insert()

      queried = Repo.get!(CompressionLock, session_id)
      assert queried.session_id == session_id
      assert queried.holder == "worker_1"
      assert queried.acquired_at == 1_718_000_000.0
      assert queried.expires_at == 1_718_000_300.0
      assert inserted.session_id == session_id
    end
  end

  describe "FTS5 virtual tables and triggers" do
    test "messages_fts is populated by insert trigger" do
      session_id = "sess_fts_#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               %Session{}
               |> Session.changeset(%{
                 id: session_id,
                 source: "test_source",
                 started_at: 1_718_000_000.0
               })
               |> Repo.insert()

      assert {:ok, _} =
               %Message{}
               |> Message.changeset(%{
                 session_id: session_id,
                 role: "user",
                 content: "hello world",
                 timestamp: 1_718_000_001.0
               })
               |> Repo.insert()

      assert {:ok, %{rows: [[1]], num_rows: 1}} =
               Repo.query("SELECT COUNT(*) FROM messages_fts WHERE content MATCH 'hello'")

      assert {:ok, %{rows: [[1]], num_rows: 1}} =
               Repo.query("SELECT COUNT(*) FROM messages_fts_trigram WHERE content MATCH 'world'")
    end

    test "messages_fts includes tool_name and tool_calls in indexed text" do
      session_id = "sess_fts_tools_#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               %Session{}
               |> Session.changeset(%{
                 id: session_id,
                 source: "test_source",
                 started_at: 1_718_000_000.0
               })
               |> Repo.insert()

      assert {:ok, message} =
               %Message{}
               |> Message.changeset(%{
                 session_id: session_id,
                 role: "assistant",
                 content: "",
                 tool_name: "search_tool",
                 tool_calls: "[{\"query\": \"elixir fts5\"}]",
                 timestamp: 1_718_000_002.0
               })
               |> Repo.insert()

      message_id = message.id

      assert {:ok, %{rows: rows, num_rows: 1}} =
               Repo.query(
                 "SELECT rowid, content FROM messages_fts WHERE content MATCH 'search_tool'"
               )

      assert [[^message_id, _content]] = rows

      assert {:ok, %{rows: _, num_rows: 1}} =
               Repo.query("SELECT rowid FROM messages_fts_trigram WHERE content MATCH 'elixir'")
    end

    test "delete trigger removes rows from messages_fts" do
      session_id = "sess_fts_delete_#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               %Session{}
               |> Session.changeset(%{
                 id: session_id,
                 source: "test_source",
                 started_at: 1_718_000_000.0
               })
               |> Repo.insert()

      assert {:ok, message} =
               %Message{}
               |> Message.changeset(%{
                 session_id: session_id,
                 role: "user",
                 content: "temporary message",
                 timestamp: 1_718_000_003.0
               })
               |> Repo.insert()

      assert {:ok, %{rows: [[1]], num_rows: 1}} =
               Repo.query("SELECT COUNT(*) FROM messages_fts WHERE content MATCH 'temporary'")

      Repo.delete!(message)

      assert {:ok, %{rows: [[0]], num_rows: 1}} =
               Repo.query("SELECT COUNT(*) FROM messages_fts WHERE content MATCH 'temporary'")
    end
  end
end
