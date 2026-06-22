defmodule Hermes.Sessions.Session do
  @moduledoc """
  Ecto schema for the `sessions` table.

  Ported from the Python source `hermes_state.py:518-600`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "sessions" do
    field :source, :string
    field :user_id, :string
    field :model, :string
    field :model_config, :string
    field :system_prompt, :string
    field :parent_session_id, :string
    field :started_at, :float
    field :ended_at, :float
    field :end_reason, :string
    field :message_count, :integer, default: 0
    field :tool_call_count, :integer, default: 0
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cache_read_tokens, :integer, default: 0
    field :cache_write_tokens, :integer, default: 0
    field :reasoning_tokens, :integer, default: 0
    field :cwd, :string
    field :billing_provider, :string
    field :billing_base_url, :string
    field :billing_mode, :string
    field :estimated_cost_usd, :float
    field :actual_cost_usd, :float
    field :cost_status, :string
    field :cost_source, :string
    field :pricing_version, :string
    field :title, :string
    field :api_call_count, :integer, default: 0
    field :handoff_state, :string
    field :handoff_platform, :string
    field :handoff_error, :string
    field :rewind_count, :integer, default: 0
    field :archived, :integer, default: 0
  end

  @required_fields [:id, :source, :started_at]
  @optional_fields [
    :user_id,
    :model,
    :model_config,
    :system_prompt,
    :parent_session_id,
    :ended_at,
    :end_reason,
    :message_count,
    :tool_call_count,
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :reasoning_tokens,
    :cwd,
    :billing_provider,
    :billing_base_url,
    :billing_mode,
    :estimated_cost_usd,
    :actual_cost_usd,
    :cost_status,
    :cost_source,
    :pricing_version,
    :title,
    :api_call_count,
    :handoff_state,
    :handoff_platform,
    :handoff_error,
    :rewind_count,
    :archived
  ]

  @doc """
  Builds a changeset for a session.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
