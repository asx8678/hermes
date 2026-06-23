defmodule Hermes.Repo.Migrations.CreateKanbanTables do
  @moduledoc """
  Creates the Kanban board tables used by the kanban tool.

  Ported from `hermes-agent/hermes_cli/kanban_db.py` (Task, Run, Comment, Link).
  """

  use Ecto.Migration

  def up do
    create table(:kanban_tasks, primary_key: false) do
      add :id, :string, primary_key: true
      add :title, :string, null: false
      add :body, :text
      add :assignee, :string
      add :status, :string, null: false, default: "todo"
      add :priority, :integer, default: 0
      add :created_by, :string
      add :tenant, :string
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :workspace_kind, :string, default: "scratch"
      add :workspace_path, :text
      add :claim_lock, :string
      add :claim_expires, :integer
      add :result, :text
      add :metadata, :text
      add :skills, :text
      add :current_run_id, :string
      add :session_id, :string

      timestamps()
    end

    create table(:kanban_comments, primary_key: false) do
      add :id, :string, primary_key: true
      add :task_id, :string, null: false
      add :author, :string
      add :body, :text, null: false

      timestamps()
    end

    create table(:kanban_links, primary_key: false) do
      add :parent_id, :string, null: false
      add :child_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:kanban_tasks, [:status])
    create index(:kanban_tasks, [:assignee])
    create index(:kanban_tasks, [:tenant])
    create index(:kanban_comments, [:task_id])
    create unique_index(:kanban_links, [:parent_id, :child_id])
  end

  def down do
    drop table(:kanban_links)
    drop table(:kanban_comments)
    drop table(:kanban_tasks)
  end
end
