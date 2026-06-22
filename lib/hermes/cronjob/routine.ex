defmodule Hermes.Cronjob.Routine do
  @moduledoc """
  Ecto schema for the `cronjob_routines` table.

  Stores scheduled cron routines created via the `cronjob` tool.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "cronjob_routines" do
    field :name, :string
    field :cron, :string
    field :prompt, :string
    field :session_id, :string
    field :enabled, :boolean, default: true

    timestamps()
  end

  @required_fields [:name, :cron, :prompt]
  @optional_fields [:session_id, :enabled]

  @doc """
  Builds a changeset for a cronjob routine.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(routine, attrs) do
    routine
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
