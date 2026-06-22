defmodule Hermes.Catalog.Model do
  @moduledoc """
  Ecto schema for a custom or overridden model in the catalog.

  A model belongs to a provider (`provider_name`) and carries the metadata the
  runtime needs: the `model_id` sent on the wire, the `context_window` (used to
  drive context compression), `max_output_tokens`, and capability flags.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "models" do
    field :provider_name, :string
    field :model_id, :string
    field :label, :string
    field :context_window, :integer
    field :max_output_tokens, :integer
    field :supports_tools, :integer, default: 1
    field :supports_reasoning, :integer, default: 0
    field :is_default, :integer, default: 0

    timestamps()
  end

  @castable [
    :provider_name,
    :model_id,
    :label,
    :context_window,
    :max_output_tokens,
    :supports_tools,
    :supports_reasoning,
    :is_default
  ]

  @doc """
  Builds a changeset for a model.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(model, attrs) do
    model
    |> cast(attrs, @castable)
    |> validate_required([:provider_name, :model_id])
    |> validate_number(:context_window, greater_than: 0)
    |> validate_number(:max_output_tokens, greater_than: 0)
    |> unique_constraint([:provider_name, :model_id], name: :idx_models_provider_model)
  end
end
