defmodule Hermes.Repo.Migrations.CreateStateMetaFts do
  @moduledoc """
  Creates an FTS5 virtual table and triggers for full-text search over
  `state_meta` rows, backing the memory tool.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE VIRTUAL TABLE IF NOT EXISTS state_meta_fts USING fts5(
      content
    );
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS state_meta_fts_insert AFTER INSERT ON state_meta BEGIN
      INSERT INTO state_meta_fts(rowid, content) VALUES (
        new.rowid,
        COALESCE(new.key, '') || ' ' || COALESCE(new.value, '')
      );
    END;
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS state_meta_fts_delete AFTER DELETE ON state_meta BEGIN
      DELETE FROM state_meta_fts WHERE rowid = old.rowid;
    END;
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS state_meta_fts_update AFTER UPDATE ON state_meta BEGIN
      DELETE FROM state_meta_fts WHERE rowid = old.rowid;
      INSERT INTO state_meta_fts(rowid, content) VALUES (
        new.rowid,
        COALESCE(new.key, '') || ' ' || COALESCE(new.value, '')
      );
    END;
    """)

    execute("""
    INSERT INTO state_meta_fts(rowid, content)
    SELECT rowid, COALESCE(key, '') || ' ' || COALESCE(value, '')
    FROM state_meta
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS state_meta_fts_update;")
    execute("DROP TRIGGER IF EXISTS state_meta_fts_delete;")
    execute("DROP TRIGGER IF EXISTS state_meta_fts_insert;")
    execute("DROP TABLE IF EXISTS state_meta_fts;")
  end
end
