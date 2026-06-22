defmodule Hermes.Skills.SkillManager do
  @moduledoc """
  Public lifecycle facade for skills.

  This module sits between the tool layer (`Hermes.Tools.SkillTools`) and the
  lower-level telemetry/provenance modules. It re-exports the lifecycle
  operations that tools and orchestrators need.

  Ported from `tools/skill_usage.py:587-725` and `agent/curator.py:276-331`.
  """

  alias Hermes.Skills.Provenance
  alias Hermes.Skills.Telemetry

  defdelegate record_view(skill_name), to: Telemetry
  defdelegate record_use(skill_name), to: Telemetry
  defdelegate record_creation(skill_name, provenance), to: Telemetry
  defdelegate get_skill_state(skill_name), to: Telemetry
  defdelegate list_skills_by_state(state), to: Telemetry
  defdelegate get_skill_stats(skill_name), to: Telemetry
  defdelegate apply_automatic_transitions(), to: Telemetry
  defdelegate archive_skill(skill_name), to: Telemetry
  defdelegate pin_skill(skill_name), to: Telemetry
  defdelegate unpin_skill(skill_name), to: Telemetry
  defdelegate protected_builtin?(skill_name), to: Telemetry

  defdelegate set_provenance(skill_name, provenance), to: Provenance, as: :set
  defdelegate get_provenance(skill_name), to: Provenance, as: :get
  defdelegate classify_provenance(skill_name), to: Provenance, as: :classify
  defdelegate curator_managed?(skill_name), to: Provenance
  defdelegate read_only?(skill_name), to: Provenance
end
