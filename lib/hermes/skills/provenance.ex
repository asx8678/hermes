defmodule Hermes.Skills.Provenance do
  @moduledoc """
  Skill provenance tracking.

  Ported from `tools/skill_usage.py:177-454`.

  Provenance classifies a skill's origin:

    * `:bundled` — shipped with Hermes (read-only)
    * `:agent`   — created by the agent via `skill_manage` (curator-managed)
    * `:manual`  — created manually by the user (curator respects, does not auto-archive)
    * `:hub`     — installed from the skills hub (read-only)

  Explicit provenance is stored in the `state_meta` table under the key
  `skill_provenance:<name>`. When no explicit value is stored, the module
  falls back to inferring provenance from the filesystem and usage record.
  """

  alias Hermes.Repo
  alias Hermes.Sessions.StateMeta
  alias Hermes.Skills.Telemetry

  @provenance_prefix "skill_provenance:"

  @type provenance :: :bundled | :agent | :manual | :hub

  @doc """
  Returns all known provenance values.
  """
  @spec all() :: [provenance()]
  def all, do: [:bundled, :agent, :manual, :hub]

  @doc """
  Stores the provenance for a skill.
  """
  @spec set(String.t(), provenance()) :: :ok
  def set(skill_name, provenance)
      when is_binary(skill_name) and provenance in [:bundled, :agent, :manual, :hub] do
    key = @provenance_prefix <> skill_name
    value = Atom.to_string(provenance)

    case Repo.get(StateMeta, key) do
      nil ->
        %StateMeta{}
        |> StateMeta.changeset(%{key: key, value: value})
        |> Repo.insert!()

      existing ->
        existing
        |> StateMeta.changeset(%{value: value})
        |> Repo.update!()
    end

    :ok
  end

  @doc """
  Reads the stored provenance for a skill, if any.
  """
  @spec get(String.t()) :: provenance() | nil
  def get(skill_name) when is_binary(skill_name) do
    case Repo.get(StateMeta, @provenance_prefix <> skill_name) do
      nil -> nil
      %StateMeta{value: value} -> parse_provenance(value)
    end
  end

  @doc """
  Classifies the provenance of a skill.

  Preference order:

    1. Explicit stored provenance.
    2. Configured hub list membership (`:hermes, :skills, :hub_skills`).
    3. `:agent` if the usage record marks the skill as `created_by: "agent"`.
    4. `:manual` if the skill exists in the user skills directory.
    5. `:bundled` if the skill exists in the bundled `priv/skills/` directory.
    6. `:manual` as the default.
  """
  @spec classify(String.t()) :: provenance()
  def classify(skill_name) when is_binary(skill_name) do
    user_dir = user_skills_dir()
    bundled_dir = bundled_skills_dir()

    cond do
      stored = get(skill_name) ->
        stored

      hub_skill?(skill_name) ->
        :hub

      agent_created?(skill_name) ->
        :agent

      skill_dir_exists?(user_dir, skill_name) ->
        :manual

      skill_dir_exists?(bundled_dir, skill_name) ->
        :bundled

      true ->
        :manual
    end
  end

  @doc """
  Returns whether a skill is curator-managed (agent-created).

  Mirrors `tools/skill_usage.py:449-453`.
  """
  @spec curator_managed?(String.t()) :: boolean()
  def curator_managed?(skill_name) when is_binary(skill_name) do
    classify(skill_name) == :agent
  end

  @doc """
  Returns whether the skill is read-only (bundled or hub).
  """
  @spec read_only?(String.t()) :: boolean()
  def read_only?(skill_name) when is_binary(skill_name) do
    classify(skill_name) in [:bundled, :hub]
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp parse_provenance("bundled"), do: :bundled
  defp parse_provenance("agent"), do: :agent
  defp parse_provenance("manual"), do: :manual
  defp parse_provenance("hub"), do: :hub
  defp parse_provenance(_), do: nil

  defp agent_created?(skill_name) do
    stats = Telemetry.get_skill_stats(skill_name)
    created_by = Map.get(stats, :created_by)
    created_by == "agent" or created_by == true
  end

  defp hub_skill?(skill_name) do
    hub_skills =
      Application.get_env(:hermes, :skills, [])
      |> Keyword.get(:hub_skills, [])

    skill_name in hub_skills
  end

  defp skill_dir_exists?(dir, name) when is_binary(dir) and is_binary(name) do
    File.dir?(Path.join(dir, name))
  end

  defp user_skills_dir do
    Application.get_env(:hermes, :skills_dir) ||
      Application.app_dir(:hermes, "priv/skills")
  end

  defp bundled_skills_dir do
    Application.app_dir(:hermes, "priv/skills")
  end
end
