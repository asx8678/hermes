defmodule Hermes.Sessions.StateMeta do
  @moduledoc """
  Ecto schema for the `state_meta` table.

  Ported from the Python source `hermes_state.py:582-585`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:key, :string, autogenerate: false}
  schema "state_meta" do
    field :value, :string
  end

  @required_fields [:key, :value]

  @doc """
  Builds a changeset for a state_meta entry.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(state_meta, attrs) do
    state_meta
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
  end
end
