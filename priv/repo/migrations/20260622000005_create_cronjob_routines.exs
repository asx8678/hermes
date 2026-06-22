defmodule Hermes.Repo.Migrations.CreateCronjobRoutines do
  @moduledoc """
  Creates the cronjob_routines table used by the cronjob tool.

  Stores the source of truth for agent-scheduled recurring routines.
  Execution is handled by Oban jobs referencing these rows.
  """

  use Ecto.Migration

  def up do
    create table(:cronjob_routines) do
      add :name, :string, null: false
      add :cron, :string, null: false
      add :prompt, :text, null: false
      add :session_id, :string
      add :enabled, :boolean, default: true, null: false

      timestamps()
    end

    create unique_index(:cronjob_routines, [:name])
  end

  def down do
    drop index(:cronjob_routines, [:name])
    drop table(:cronjob_routines)
  end
end
