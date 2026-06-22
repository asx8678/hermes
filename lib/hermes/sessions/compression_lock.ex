defmodule Hermes.Sessions.CompressionLock do
  @moduledoc """
  Ecto schema for the `compression_locks` table.

  Ported from the Python source `hermes_state.py:587-592`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:session_id, :string, autogenerate: false}
  schema "compression_locks" do
    field :holder, :string
    field :acquired_at, :float
    field :expires_at, :float
  end

  @required_fields [:session_id, :holder, :acquired_at, :expires_at]

  @doc """
  Builds a changeset for a compression lock.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(compression_lock, attrs) do
    compression_lock
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
  end
end
