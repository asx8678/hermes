defmodule Hermes.Repo.Migrations.CreateCatalogTables do
  @moduledoc """
  Creates the `providers` and `models` tables that back the model/provider
  manager.

  These tables store CUSTOM (user-added) providers/models and OVERRIDES of the
  built-in catalog. The built-in catalog itself is defined in code
  (`Hermes.Catalog`), so the system resolves providers correctly even with
  empty tables — these rows are additive.
  """

  use Ecto.Migration

  def change do
    create table(:providers, primary_key: false) do
      add :name, :string, primary_key: true
      add :label, :string
      add :kind, :string, null: false, default: "openai"
      add :base_url, :string
      add :api_key, :string
      add :api_key_env, :string
      add :is_default, :integer, null: false, default: 0

      timestamps()
    end

    create table(:models) do
      add :provider_name, :string, null: false
      add :model_id, :string, null: false
      add :label, :string
      add :context_window, :integer
      add :max_output_tokens, :integer
      add :supports_tools, :integer, null: false, default: 1
      add :supports_reasoning, :integer, null: false, default: 0
      add :is_default, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:models, [:provider_name, :model_id], name: :idx_models_provider_model)
    create index(:models, [:provider_name], name: :idx_models_provider)
  end
end
