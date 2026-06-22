defmodule Hermes.Skills.TelemetryTest do
  @moduledoc """
  Tests for `Hermes.Skills.Telemetry`, `Hermes.Skills.Provenance`, and the
  skill telemetry wiring in `Hermes.Tools.SkillTools`.
  """

  use Hermes.DataCase, async: false

  alias Hermes.Skills.Provenance
  alias Hermes.Skills.Telemetry

  setup do
    # Each test gets its own temporary skills directory.
    tmp_dir =
      Path.join(System.tmp_dir!(), "hermes_skills_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    previous = Application.get_env(:hermes, :skills_dir)
    Application.put_env(:hermes, :skills_dir, tmp_dir)

    # Attach a telemetry handler to observe events.
    test_pid = self()
    ref = make_ref()

    :telemetry.attach_many(
      ref,
      [
        [:hermes, :skill, :view],
        [:hermes, :skill, :use],
        [:hermes, :skill, :create],
        [:hermes, :skill, :transition]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata, ref})
      end,
      nil
    )

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      :telemetry.detach(ref)

      if previous do
        Application.put_env(:hermes, :skills_dir, previous)
      else
        Application.delete_env(:hermes, :skills_dir)
      end
    end)

    {:ok, telemetry_ref: ref, skills_dir: tmp_dir}
  end

  describe "record_view/1 and record_use/1" do
    test "increment counters and timestamps", %{skills_dir: dir} do
      create_skill_file(dir, "viewed-skill")

      assert :ok = Telemetry.record_view("viewed-skill")
      stats = Telemetry.get_skill_stats("viewed-skill")
      assert stats.views == 1
      assert stats.uses == 0
      assert stats.state == :active
      assert stats.pinned == false
      assert stats.last_used_at == nil
      assert stats.last_viewed_at != nil

      assert :ok = Telemetry.record_use("viewed-skill")
      stats = Telemetry.get_skill_stats("viewed-skill")
      assert stats.views == 1
      assert stats.uses == 1
      assert stats.last_used_at != nil
    end

    test "emit :telemetry events", %{telemetry_ref: ref} do
      assert :ok = Telemetry.record_view("telemetry-skill")

      assert_receive {:telemetry, [:hermes, :skill, :view], %{count: 1},
                      %{name: "telemetry-skill"}, ^ref}

      assert :ok = Telemetry.record_use("telemetry-skill")

      assert_receive {:telemetry, [:hermes, :skill, :use], %{count: 1},
                      %{name: "telemetry-skill"}, ^ref}
    end
  end

  describe "record_creation/2" do
    test "marks agent-created skills and emits event", %{telemetry_ref: ref} do
      assert :ok = Telemetry.record_creation("agent-skill", :agent)

      assert_receive {:telemetry, [:hermes, :skill, :create], %{count: 1},
                      %{name: "agent-skill", provenance: :agent}, ^ref}

      stats = Telemetry.get_skill_stats("agent-skill")
      assert stats.created_by == "agent"
      assert Provenance.get("agent-skill") == :agent
    end

    test "stores manual provenance", %{skills_dir: dir} do
      create_skill_file(dir, "manual-skill")
      assert :ok = Telemetry.record_creation("manual-skill", :manual)

      assert Provenance.get("manual-skill") == :manual
      assert Provenance.classify("manual-skill") == :manual
    end
  end

  describe "pin/unpin" do
    test "pinned skills bypass transitions", %{skills_dir: dir} do
      create_skill_file(dir, "precious")
      Telemetry.record_creation("precious", :agent)

      # Simulate a very old last-use date.
      old = DateTime.add(DateTime.utc_now(), -365, :day)
      set_last_used_at("precious", old)

      Telemetry.pin_skill("precious")

      counts = Telemetry.apply_automatic_transitions()
      assert counts.archived == 0
      assert counts.marked_stale == 0
      assert Telemetry.get_skill_state("precious") == :active
      assert Telemetry.get_skill_stats("precious").pinned == true

      Telemetry.unpin_skill("precious")
      counts = Telemetry.apply_automatic_transitions()
      assert counts.archived == 1
      assert Telemetry.get_skill_state("precious") == :archived
      assert Telemetry.get_skill_stats("precious").pinned == false
    end
  end

  describe "archive_skill/1" do
    test "archives a regular skill" do
      Telemetry.record_creation("regular", :agent)
      assert :ok = Telemetry.archive_skill("regular")
      assert Telemetry.get_skill_state("regular") == :archived
    end

    test "refuses to archive protected builtins" do
      assert {:error, :protected} = Telemetry.archive_skill("plan")
      assert Telemetry.get_skill_state("plan") == :active
    end
  end

  describe "apply_automatic_transitions/0" do
    test "active -> stale after stale_after_days", %{skills_dir: dir} do
      create_skill_file(dir, "old-skill")
      Telemetry.record_creation("old-skill", :agent)

      long_ago = DateTime.add(DateTime.utc_now(), -45, :day)
      set_last_used_at("old-skill", long_ago)

      counts = Telemetry.apply_automatic_transitions()
      assert counts.marked_stale == 1
      assert counts.archived == 0
      assert Telemetry.get_skill_state("old-skill") == :stale
    end

    test "stale -> archived after archive_after_days", %{skills_dir: dir} do
      create_skill_file(dir, "ancient")
      Telemetry.record_creation("ancient", :agent)

      super_old = DateTime.add(DateTime.utc_now(), -120, :day)
      set_last_used_at("ancient", super_old)

      counts = Telemetry.apply_automatic_transitions()
      assert counts.archived == 1
      assert Telemetry.get_skill_state("ancient") == :archived

      assert_receive {:telemetry, [:hermes, :skill, :transition], %{count: 1},
                      %{name: "ancient", state: :archived}, _}
    end

    test "protected builtins are never archived", %{skills_dir: dir} do
      create_skill_file(dir, "plan")
      Telemetry.record_creation("plan", :agent)

      super_old = DateTime.add(DateTime.utc_now(), -500, :day)
      set_last_used_at("plan", super_old)

      counts = Telemetry.apply_automatic_transitions()
      assert counts.archived == 0
      assert counts.marked_stale == 0
      assert Telemetry.get_skill_state("plan") == :active
    end

    test "manual skills are not auto transitioned", %{skills_dir: dir} do
      create_skill_file(dir, "manual")
      Telemetry.record_creation("manual", :manual)

      super_old = DateTime.add(DateTime.utc_now(), -365, :day)
      set_last_used_at("manual", super_old)

      counts = Telemetry.apply_automatic_transitions()
      assert counts.checked == 0
      assert counts.archived == 0
      assert counts.marked_stale == 0
    end

    test "stale skill reactivates on recent use", %{skills_dir: dir} do
      create_skill_file(dir, "revived")
      Telemetry.record_creation("revived", :agent)

      recent = DateTime.utc_now()
      set_last_used_at("revived", recent)
      Telemetry.archive_skill("revived")
      # Archive sets state to archived; recent use should not reactivate archived skills.
      counts = Telemetry.apply_automatic_transitions()
      assert counts.reactivated == 0

      # Now set state to stale with recent use -> should reactivate.
      mutate_record("revived", fn rec ->
        rec
        |> Map.put("state", "stale")
        |> Map.put("archived_at", nil)
      end)

      counts = Telemetry.apply_automatic_transitions()
      assert counts.reactivated == 1
      assert Telemetry.get_skill_state("revived") == :active

      assert_receive {:telemetry, [:hermes, :skill, :transition], %{count: 1},
                      %{name: "revived", state: :active}, _}
    end

    test "fresh skill without activity is not immediately archived", %{skills_dir: dir} do
      create_skill_file(dir, "fresh")
      Telemetry.record_creation("fresh", :agent)

      counts = Telemetry.apply_automatic_transitions()
      assert counts.archived == 0
      assert counts.marked_stale == 0
      assert Telemetry.get_skill_state("fresh") == :active
    end
  end

  describe "list_skills_by_state/1" do
    test "returns skills filtered by state" do
      Telemetry.record_creation("alpha", :agent)
      Telemetry.archive_skill("alpha")
      Telemetry.record_creation("beta", :agent)

      archived = Telemetry.list_skills_by_state(:archived)
      assert length(archived) == 1
      assert hd(archived).name == "alpha"

      active = Telemetry.list_skills_by_state(:active)
      assert Enum.any?(active, &(&1.name == "beta"))
      refute Enum.any?(active, &(&1.name == "alpha"))
    end
  end

  describe "SkillTools telemetry wiring" do
    test "skill_view records a view", %{skills_dir: dir} do
      create_skill_file(dir, "tool-viewed")
      alias Hermes.Tools.SkillTools

      result = SkillTools.invoke("skill_view", %{"name" => "tool-viewed"})
      assert result["success"] == true

      assert_receive {:telemetry, [:hermes, :skill, :view], %{count: 1}, %{name: "tool-viewed"},
                      _}

      stats = Telemetry.get_skill_stats("tool-viewed")
      assert stats.views == 1
    end

    test "skill_manage create records creation", %{telemetry_ref: ref} do
      alias Hermes.Tools.SkillTools

      result =
        SkillTools.invoke("skill_manage", %{
          "action" => "create",
          "name" => "tool-created",
          "content" => "# Tool Created\n"
        })

      assert result["success"] == true

      assert_receive {:telemetry, [:hermes, :skill, :create], %{count: 1},
                      %{name: "tool-created", provenance: :agent}, ^ref}

      assert Provenance.get("tool-created") == :agent
      stats = Telemetry.get_skill_stats("tool-created")
      assert stats.created_by == "agent"
    end
  end

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp create_skill_file(dir, name) do
    skill_dir = Path.join(dir, name)
    File.mkdir_p!(skill_dir)

    content = """
    ---
    name: #{name}
    description: test skill
    ---

    # #{name}
    """

    File.write!(Path.join(skill_dir, "SKILL.md"), content)
  end

  defp set_last_used_at(skill_name, %DateTime{} = dt) do
    mutate_record(skill_name, fn rec ->
      Map.put(rec, "last_used_at", DateTime.to_iso8601(dt))
    end)
  end

  defp mutate_record(skill_name, mutator) do
    alias Hermes.Repo
    alias Hermes.Sessions.StateMeta

    key = "skill_usage:" <> skill_name

    case Repo.get(StateMeta, key) do
      nil ->
        record =
          Telemetry.empty_record()
          |> mutator.()

        %StateMeta{}
        |> StateMeta.changeset(%{key: key, value: Jason.encode!(record)})
        |> Repo.insert!()

      existing ->
        record =
          existing.value
          |> Telemetry.merge_defaults()
          |> mutator.()

        existing
        |> StateMeta.changeset(%{value: Jason.encode!(record)})
        |> Repo.update!()
    end
  end
end
