defmodule Hermes.Repo.Migrations.CreateSessionsTables do
  @moduledoc """
  Creates the sessions, messages, state_meta, and compression_locks tables,
  plus FTS5 virtual tables and triggers for full-text search.

  Ported from the Python source:
  - `hermes_state.py:518-600` (schema and indexes)
  - `hermes_state.py:611-664` (FTS5 virtual tables and triggers)
  """

  use Ecto.Migration

  def up do
    create table(:sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :source, :string, null: false
      add :user_id, :string
      add :model, :string
      add :model_config, :string
      add :system_prompt, :string
      add :parent_session_id, :string
      add :started_at, :float, null: false
      add :ended_at, :float
      add :end_reason, :string
      add :message_count, :integer, default: 0
      add :tool_call_count, :integer, default: 0
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :cache_read_tokens, :integer, default: 0
      add :cache_write_tokens, :integer, default: 0
      add :reasoning_tokens, :integer, default: 0
      add :cwd, :string
      add :billing_provider, :string
      add :billing_base_url, :string
      add :billing_mode, :string
      add :estimated_cost_usd, :float
      add :actual_cost_usd, :float
      add :cost_status, :string
      add :cost_source, :string
      add :pricing_version, :string
      add :title, :string
      add :api_call_count, :integer, default: 0
      add :handoff_state, :string
      add :handoff_platform, :string
      add :handoff_error, :string
      add :rewind_count, :integer, null: false, default: 0
      add :archived, :integer, null: false, default: 0
    end

    create table(:messages) do
      add :session_id, :string, null: false
      add :role, :string, null: false
      add :content, :string
      add :tool_call_id, :string
      add :tool_calls, :string
      add :tool_name, :string
      add :timestamp, :float, null: false
      add :token_count, :integer
      add :finish_reason, :string
      add :reasoning, :string
      add :reasoning_content, :string
      add :reasoning_details, :string
      add :codex_reasoning_items, :string
      add :codex_message_items, :string
      add :platform_message_id, :string
      add :observed, :integer, default: 0
      add :active, :integer, null: false, default: 1
      add :compacted, :integer, null: false, default: 0
    end

    create table(:state_meta, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string
    end

    create table(:compression_locks, primary_key: false) do
      add :session_id, :string, primary_key: true
      add :holder, :string, null: false
      add :acquired_at, :float, null: false
      add :expires_at, :float, null: false
    end

    create index(:sessions, [:source], name: :idx_sessions_source)
    create index(:sessions, [:source, :id], name: :idx_sessions_source_id)
    create index(:sessions, [:parent_session_id], name: :idx_sessions_parent)
    create index(:sessions, ["started_at DESC"], name: :idx_sessions_started)
    create index(:messages, [:session_id, :timestamp], name: :idx_messages_session)

    create index(:messages, [:session_id, :active, :timestamp],
             name: :idx_messages_session_active
           )

    create index(:compression_locks, [:expires_at], name: :idx_compression_locks_expires)

    execute("""
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
      content
    );
    """)

    execute("""
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts_trigram USING fts5(
      content,
      tokenize='trigram'
    );
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS messages_fts_insert AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts(rowid, content) VALUES (
        new.id,
        COALESCE(new.content, '') || ' ' || COALESCE(new.tool_name, '') || ' ' || COALESCE(new.tool_calls, '')
      );
    END;
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS messages_fts_delete AFTER DELETE ON messages BEGIN
      DELETE FROM messages_fts WHERE rowid = old.id;
    END;
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS messages_fts_update AFTER UPDATE ON messages BEGIN
      DELETE FROM messages_fts WHERE rowid = old.id;
      INSERT INTO messages_fts(rowid, content) VALUES (
        new.id,
        COALESCE(new.content, '') || ' ' || COALESCE(new.tool_name, '') || ' ' || COALESCE(new.tool_calls, '')
      );
    END;
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS messages_fts_trigram_insert AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts_trigram(rowid, content) VALUES (
        new.id,
        COALESCE(new.content, '') || ' ' || COALESCE(new.tool_name, '') || ' ' || COALESCE(new.tool_calls, '')
      );
    END;
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS messages_fts_trigram_delete AFTER DELETE ON messages BEGIN
      DELETE FROM messages_fts_trigram WHERE rowid = old.id;
    END;
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS messages_fts_trigram_update AFTER UPDATE ON messages BEGIN
      DELETE FROM messages_fts_trigram WHERE rowid = old.id;
      INSERT INTO messages_fts_trigram(rowid, content) VALUES (
        new.id,
        COALESCE(new.content, '') || ' ' || COALESCE(new.tool_name, '') || ' ' || COALESCE(new.tool_calls, '')
      );
    END;
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS messages_fts_trigram_update;")
    execute("DROP TRIGGER IF EXISTS messages_fts_trigram_delete;")
    execute("DROP TRIGGER IF EXISTS messages_fts_trigram_insert;")
    execute("DROP TRIGGER IF EXISTS messages_fts_update;")
    execute("DROP TRIGGER IF EXISTS messages_fts_delete;")
    execute("DROP TRIGGER IF EXISTS messages_fts_insert;")

    execute("DROP TABLE IF EXISTS messages_fts_trigram;")
    execute("DROP TABLE IF EXISTS messages_fts;")

    drop table(:compression_locks)
    drop table(:state_meta)
    drop table(:messages)
    drop table(:sessions)
  end
end
