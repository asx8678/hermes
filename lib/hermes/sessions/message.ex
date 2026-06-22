defmodule Hermes.Sessions.Message do
  @moduledoc """
  Ecto schema for the `messages` table.

  Ported from the Python source `hermes_state.py:560-580`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :integer, autogenerate: false, read_after_writes: true}
  schema "messages" do
    field :session_id, :string
    field :role, :string
    field :content, :string
    field :tool_call_id, :string
    field :tool_calls, :string
    field :tool_name, :string
    field :timestamp, :float
    field :token_count, :integer
    field :finish_reason, :string
    field :reasoning, :string
    field :reasoning_content, :string
    field :reasoning_details, :string
    field :codex_reasoning_items, :string
    field :codex_message_items, :string
    field :platform_message_id, :string
    field :observed, :integer, default: 0
    field :active, :integer, default: 1
    field :compacted, :integer, default: 0
  end

  @required_fields [:session_id, :role, :timestamp]
  @optional_fields [
    :content,
    :tool_call_id,
    :tool_calls,
    :tool_name,
    :token_count,
    :finish_reason,
    :reasoning,
    :reasoning_content,
    :reasoning_details,
    :codex_reasoning_items,
    :codex_message_items,
    :platform_message_id,
    :observed,
    :active,
    :compacted
  ]

  @doc """
  Builds a changeset for a message.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
