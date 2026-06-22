defmodule Hermes.Curator.WorkerTest do
  @moduledoc """
  Tests for `Hermes.Curator.Worker`, `Hermes.Curator`, and
  `Hermes.Curator.BackgroundReview`.
  """

  use Hermes.DataCase, async: false

  alias Hermes.Curator
  alias Hermes.Curator.BackgroundReview
  alias Hermes.Curator.Worker
  alias Hermes.Providers.Types.NormalizedResponse
  alias Hermes.Sessions
  alias Hermes.Skills.Telemetry
  alias Hermes.Test.MockProvider
  alias Hermes.Tools.Registry

  setup do
    ensure_registry()
    start_supervised!(MockProvider)
    MockProvider.reset()

    tmp_dir =
      Path.join(System.tmp_dir!(), "hermes_skills_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    previous = Application.get_env(:hermes, :skills_dir)
    Application.put_env(:hermes, :skills_dir, tmp_dir)

    previous_skills_config = Application.get_env(:hermes, :skills, [])

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.put_env(:hermes, :skills_dir, previous)
      Application.put_env(:hermes, :skills, previous_skills_config)
    end)

    {:ok, skills_dir: tmp_dir}
  end

  describe "Worker.perform/1" do
    test "runs apply_automatic_transitions and updates curator state" do
      skill_name = "staleable_skill"
      create_skill(skill_name)

      # Force the skill to be active but older than the stale threshold.
      Telemetry.record_use(skill_name)

      Application.put_env(:hermes, :skills,
        stale_after_days: 0,
        archive_after_days: 90,
        consolidate: false,
        prune_builtins: false,
        hub_skills: []
      )

      assert Curator.get_state().run_count == 0

      assert :ok = Worker.perform(%Oban.Job{args: %{}})

      state = Curator.get_state()
      assert state.run_count == 1
      assert is_binary(state.last_run_at)
      assert state.paused == false

      stats = Telemetry.get_skill_stats(skill_name)
      assert stats.state == :stale
    end

    test "skips work when the curator is paused" do
      :ok = Curator.pause()
      on_exit(fn -> Curator.resume() end)

      assert :ok = Worker.perform(%Oban.Job{args: %{}})

      state = Curator.get_state()
      assert state.run_count == 0
      assert state.paused == true
    end
  end

  describe "Curator public API" do
    test "get_state/0 returns the default state" do
      state = Curator.get_state()
      assert state.last_run_at == nil
      assert state.run_count == 0
      assert state.paused == false
    end

    test "pause/0 and resume/0 toggle the paused flag" do
      assert :ok = Curator.pause()
      assert Curator.get_state().paused == true

      assert :ok = Curator.resume()
      assert Curator.get_state().paused == false
    end

    test "run_now/0 enqueues a curator Oban job" do
      assert :ok = Curator.run_now()

      assert [%Oban.Job{worker: "Hermes.Curator.Worker"}] =
               Hermes.Repo.all(Oban.Job)
    end
  end

  describe "BackgroundReview.spawn_review/3" do
    test "is non-blocking and emits a spawn telemetry event" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach_many(
        ref,
        [
          [:hermes, :curator, :background_review, :spawned],
          [:hermes, :curator, :background_review, :completed]
        ],
        fn event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, metadata, ref})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ref) end)

      MockProvider.enqueue(%NormalizedResponse{
        content: "Nothing to save.",
        finish_reason: "stop"
      })

      assert :ok =
               BackgroundReview.spawn_review(
                 "session_#{System.unique_integer([:positive])}",
                 [],
                 []
               )

      assert_receive {:telemetry, [:hermes, :curator, :background_review, :spawned], _meta, ^ref},
                     500

      assert_receive {:telemetry, [:hermes, :curator, :background_review, :completed], _meta,
                      ^ref},
                     1_000
    end
  end

  describe "integration with SessionServer" do
    test "background review is triggered after a turn completes" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        ref,
        [:hermes, :curator, :background_review, :spawned],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:review_spawned, metadata, ref})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ref) end)

      MockProvider.enqueue(%NormalizedResponse{
        content: "Hello, world!",
        finish_reason: "stop"
      })

      # The foreground turn consumes the first response; the background review
      # fork consumes a second response.
      MockProvider.enqueue(%NormalizedResponse{
        content: "Nothing to save.",
        finish_reason: "stop"
      })

      {:ok, pid, session_id} =
        Sessions.start_session(
          provider: Hermes.Test.MockProvider,
          model: "mock-model",
          api_mode: "mock"
        )

      on_exit(fn -> Sessions.stop_session(pid) end)

      :ok = Sessions.run_turn_async(session_id, "hi")

      # Wait for the turn to finish.
      assert_eventually(fn -> Sessions.get_session(pid).status == :idle end, 2_000)

      assert_receive {:review_spawned, %{session_id: ^session_id}, ^ref}, 2_000
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ensure_registry do
    case Registry.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Registry.register_builtins()
  end

  defp create_skill(name) do
    Hermes.Tools.SkillTools.invoke("skill_manage", %{
      "action" => "create",
      "name" => name,
      "content" => "# #{name}\n\nTest skill for curator transitions.\n"
    })
  end

  defp assert_eventually(check_fn, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(check_fn, deadline)
  end

  defp do_assert_eventually(check_fn, deadline) do
    if check_fn.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition never became true")
      else
        Process.sleep(10)
        do_assert_eventually(check_fn, deadline)
      end
    end
  end
end
