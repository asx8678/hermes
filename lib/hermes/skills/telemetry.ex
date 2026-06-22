defmodule Hermes.Skills.Telemetry do
  @moduledoc """
  Skill usage telemetry and deterministic lifecycle transitions.

  Ported from the Python sources:
    * `tools/skill_usage.py:53-56` (states: active/stale/archived)
    * `tools/skill_usage.py:460-900` (sidecar usage records, counter bumps,
      archive/pin, protected built-ins)
    * `agent/curator.py:56-64` (default stale/archive thresholds)
    * `agent/curator.py:276-331` (`apply_automatic_transitions`)

  The original implementation stores telemetry in a sidecar JSON file
  (`~/.hermes/skills/.usage.json`); this Elixir port stores the same data in
  the `state_meta` table keyed by `skill_usage:<name>`.
  """

  import Ecto.Query

  require Logger

  alias Hermes.Repo
  alias Hermes.Sessions.StateMeta
  alias Hermes.Skills.Provenance

  @states [:active, :stale, :archived]

  @protected_builtins ["plan"]

  @usage_prefix "skill_usage:"
  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns the valid lifecycle states.
  """
  @spec states() :: [atom()]
  def states, do: @states

  @doc """
  Returns whether `skill_name` is a protected built-in that must never be
  archived or transitioned.

  Matches `tools/skill_usage.py:66-78`.
  """
  @spec protected_builtin?(String.t()) :: boolean()
  def protected_builtin?(skill_name) when is_binary(skill_name) do
    skill_name in @protected_builtins
  end

  @doc """
  Record that a skill was viewed (e.g. by `skill_view`).

  Bumps `view_count`, updates `last_viewed_at`, and emits a `:telemetry`
  event. Corresponds to `tools/skill_usage.py:587-596`.
  """
  @spec record_view(String.t()) :: :ok
  def record_view(skill_name) when is_binary(skill_name) do
    mutate(skill_name, fn rec ->
      rec
      |> Map.update("view_count", 1, &(&1 + 1))
      |> Map.put("last_viewed_at", now_iso())
    end)

    :telemetry.execute([:hermes, :skill, :view], %{count: 1}, %{name: skill_name})
    :ok
  end

  @doc """
  Record that a skill was actively used (e.g. loaded into a prompt path).

  Bumps `use_count`, updates `last_used_at`, and emits a `:telemetry`
  event. Corresponds to `tools/skill_usage.py:599-608`.
  """
  @spec record_use(String.t()) :: :ok
  def record_use(skill_name) when is_binary(skill_name) do
    mutate(skill_name, fn rec ->
      rec
      |> Map.update("use_count", 1, &(&1 + 1))
      |> Map.put("last_used_at", now_iso())
    end)

    :telemetry.execute([:hermes, :skill, :use], %{count: 1}, %{name: skill_name})
    :ok
  end

  @doc """
  Record the creation of a skill and its provenance.

  For `:agent` provenance this opts the skill into curator management by
  setting `created_by: "agent"`, matching
  `tools/skill_usage.py:622-630` (`mark_agent_created`).
  """
  @spec record_creation(String.t(), Provenance.provenance()) :: :ok
  def record_creation(skill_name, provenance) when is_binary(skill_name) do
    mutate(skill_name, fn rec ->
      rec =
        if provenance == :agent do
          Map.put(rec, "created_by", "agent")
        else
          rec
        end

      if is_nil(Map.get(rec, "created_at")), do: Map.put(rec, "created_at", now_iso()), else: rec
    end)

    Provenance.set(skill_name, provenance)

    :telemetry.execute(
      [:hermes, :skill, :create],
      %{count: 1},
      %{name: skill_name, provenance: provenance}
    )

    :ok
  end

  @doc """
  Returns the current lifecycle state for a skill.
  """
  @spec get_skill_state(String.t()) :: atom()
  def get_skill_state(skill_name) when is_binary(skill_name) do
    skill_name
    |> get_record()
    |> Map.get("state", "active")
    |> string_to_state()
  end

  @doc """
  Lists all skills currently in the given state.
  """
  @spec list_skills_by_state(atom()) :: [map()]
  def list_skills_by_state(state) when state in @states do
    state_str = Atom.to_string(state)

    @usage_prefix
    |> list_records()
    |> Enum.filter(fn {_name, rec} -> Map.get(rec, "state", "active") == state_str end)
    |> Enum.map(fn {name, rec} -> stats_map(rec, name) end)
  end

  @doc """
  Returns usage stats for a single skill.
  """
  @spec get_skill_stats(String.t()) :: map()
  def get_skill_stats(skill_name) when is_binary(skill_name) do
    skill_name
    |> get_record()
    |> stats_map(skill_name)
  end

  @doc """
  Applies deterministic automatic transitions.

  Walks every curator-managed skill and transitions:
    * active → stale when unused longer than `stale_after_days`
    * stale  → archived when unused longer than `archive_after_days`
    * stale  → active when recently used again

  Pinned skills and protected built-ins are never transitioned.

  Returns a map of counts: `%{checked: n, marked_stale: n, archived: n,
  reactivated: n}`.

  Port of `agent/curator.py:276-331`.
  """
  @spec apply_automatic_transitions() :: map()
  def apply_automatic_transitions do
    now = DateTime.utc_now()
    stale_cutoff = DateTime.add(now, -stale_after_days(), :day)
    archive_cutoff = DateTime.add(now, -archive_after_days(), :day)

    initial = %{checked: 0, marked_stale: 0, archived: 0, reactivated: 0}

    list_records(@usage_prefix)
    |> Enum.reduce(initial, fn {name, rec}, acc ->
      if Provenance.classify(name) == :agent and not protected_builtin?(name) do
        acc = Map.update!(acc, :checked, &(&1 + 1))

        if Map.get(rec, "pinned", false) do
          acc
        else
          transition_record(name, rec, stale_cutoff, archive_cutoff, acc)
        end
      else
        acc
      end
    end)
  end

  @doc """
  Marks a skill as archived.

  Protected built-ins return `{:error, :protected}`.
  """
  @spec archive_skill(String.t()) :: :ok | {:error, :protected}
  def archive_skill(skill_name) when is_binary(skill_name) do
    if protected_builtin?(skill_name) do
      {:error, :protected}
    else
      mutate(skill_name, fn rec ->
        rec
        |> Map.put("state", "archived")
        |> Map.put("archived_at", now_iso())
      end)

      emit_transition(skill_name, :archived)
      :ok
    end
  end

  @doc """
  Pins a skill, opting it out of automatic transitions.
  """
  @spec pin_skill(String.t()) :: :ok
  def pin_skill(skill_name) when is_binary(skill_name) do
    mutate(skill_name, fn rec -> Map.put(rec, "pinned", true) end)
    :ok
  end

  @doc """
  Unpins a skill, allowing automatic transitions again.
  """
  @spec unpin_skill(String.t()) :: :ok
  def unpin_skill(skill_name) when is_binary(skill_name) do
    mutate(skill_name, fn rec -> Map.put(rec, "pinned", false) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp usage_key(skill_name), do: @usage_prefix <> skill_name

  defp mutate(skill_name, mutator) when is_binary(skill_name) and is_function(mutator, 1) do
    if skill_name == "" do
      :ok
    else
      try do
        rec = get_record(skill_name)
        rec = mutator.(rec)
        persist_record(skill_name, rec)
      rescue
        e ->
          Logger.debug("Hermes.Skills.Telemetry.mutate(#{skill_name}) failed: #{inspect(e)}")
          :ok
      end
    end
  end

  defp get_record(skill_name) do
    case Repo.get(StateMeta, usage_key(skill_name)) do
      nil ->
        empty_record()

      %StateMeta{value: value} ->
        merge_defaults(value)
    end
  end

  defp persist_record(skill_name, record) do
    key = usage_key(skill_name)
    value = Jason.encode!(record)

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
  end

  defp list_records(prefix) do
    StateMeta
    |> where([sm], like(sm.key, ^"#{prefix}%"))
    |> select([sm], {sm.key, sm.value})
    |> Repo.all()
    |> Enum.map(fn {key, value} ->
      name = String.replace_prefix(key, prefix, "")
      {name, merge_defaults(value)}
    end)
  end

  @doc false
  def empty_record do
    now = now_iso()

    %{
      "created_by" => nil,
      "use_count" => 0,
      "view_count" => 0,
      "last_used_at" => nil,
      "last_viewed_at" => nil,
      "patch_count" => 0,
      "last_patched_at" => nil,
      "created_at" => now,
      "state" => "active",
      "pinned" => false,
      "archived_at" => nil
    }
  end

  @doc false
  def merge_defaults(value) do
    parsed =
      case Jason.decode(value) do
        {:ok, %{} = map} -> map
        _ -> empty_record()
      end

    Map.merge(empty_record(), parsed)
  end

  defp stats_map(rec, name) do
    %{
      name: name,
      views: Map.get(rec, "view_count", 0),
      uses: Map.get(rec, "use_count", 0),
      patches: Map.get(rec, "patch_count", 0),
      last_used_at: parse_dt(Map.get(rec, "last_used_at")),
      last_viewed_at: parse_dt(Map.get(rec, "last_viewed_at")),
      last_patched_at: parse_dt(Map.get(rec, "last_patched_at")),
      created_at: parse_dt(Map.get(rec, "created_at")),
      created_by: Map.get(rec, "created_by"),
      state: string_to_state(Map.get(rec, "state", "active")),
      pinned: Map.get(rec, "pinned", false)
    }
  end

  defp transition_record(name, rec, stale_cutoff, archive_cutoff, counts) do
    last_activity = latest_activity_dt(rec)
    anchor = last_activity || parse_dt(Map.get(rec, "created_at")) || DateTime.utc_now()
    current = Map.get(rec, "state", "active")

    cond do
      DateTime.compare(anchor, archive_cutoff) != :gt and current != "archived" ->
        mutate(name, fn r ->
          r
          |> Map.put("state", "archived")
          |> Map.put("archived_at", now_iso())
        end)

        emit_transition(name, :archived)
        Map.update!(counts, :archived, &(&1 + 1))

      DateTime.compare(anchor, stale_cutoff) != :gt and current == "active" ->
        mutate(name, fn r -> Map.put(r, "state", "stale") end)
        emit_transition(name, :stale)
        Map.update!(counts, :marked_stale, &(&1 + 1))

      DateTime.compare(anchor, stale_cutoff) == :gt and current == "stale" ->
        mutate(name, fn r -> Map.put(r, "state", "active") end)
        emit_transition(name, :active)
        Map.update!(counts, :reactivated, &(&1 + 1))

      true ->
        counts
    end
  end

  defp latest_activity_dt(rec) do
    ["last_used_at", "last_viewed_at", "last_patched_at"]
    |> Enum.map(&parse_dt(Map.get(rec, &1)))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      dts -> Enum.max_by(dts, &DateTime.to_unix/1)
    end
  end

  defp emit_transition(skill_name, new_state) do
    :telemetry.execute(
      [:hermes, :skill, :transition],
      %{count: 1},
      %{name: skill_name, state: new_state}
    )
  end

  defp string_to_state("active"), do: :active
  defp string_to_state("stale"), do: :stale
  defp string_to_state("archived"), do: :archived
  defp string_to_state(_), do: :active

  defp parse_dt(nil), do: nil

  defp parse_dt(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_dt(%DateTime{} = dt), do: dt
  defp parse_dt(_), do: nil

  defp now_iso do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp stale_after_days do
    Application.get_env(:hermes, :skills, [])
    |> Keyword.get(:stale_after_days, 30)
  end

  defp archive_after_days do
    Application.get_env(:hermes, :skills, [])
    |> Keyword.get(:archive_after_days, 90)
  end
end
