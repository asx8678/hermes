defmodule Hermes.Kanban.Task do
  @moduledoc """
  Ecto schema for `kanban_tasks`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "kanban_tasks" do
    field :title, :string
    field :body, :string
    field :assignee, :string
    field :status, :string, default: "todo"
    field :priority, :integer, default: 0
    field :created_by, :string
    field :tenant, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :workspace_kind, :string, default: "scratch"
    field :workspace_path, :string
    field :claim_lock, :string
    field :claim_expires, :integer
    field :result, :string
    field :metadata, :string
    field :skills, :string
    field :current_run_id, :string
    field :session_id, :string

    timestamps()
  end

  @optional [
    :body,
    :assignee,
    :tenant,
    :started_at,
    :completed_at,
    :workspace_kind,
    :workspace_path,
    :claim_lock,
    :claim_expires,
    :result,
    :metadata,
    :skills,
    :current_run_id,
    :session_id
  ]

  @doc """
  Builds a changeset for a kanban task.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(task, attrs) do
    task
    |> cast(attrs, [:id, :title, :status, :priority | @optional])
    |> validate_required([:id, :title, :status])
    |> validate_inclusion(
      :status,
      ~w(triage todo scheduled ready running blocked review done archived)
    )
    |> validate_inclusion(:workspace_kind, ~w(scratch dir worktree))
  end
end
