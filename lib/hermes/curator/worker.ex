defmodule Hermes.Curator.Worker do
  @moduledoc """
  Oban worker that runs the curator lifecycle prune.

  Replaces the Python inactivity timer (`agent/curator.py:276-331`) with a
  durable, retryable background job. Scheduled via the Oban Cron plugin
  (default every 6 hours).

  Ported from:
    * `agent/curator.py:276-331` (`apply_automatic_transitions`)
    * `agent/curator.py:1428-1530` (`run_curator_review`)
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Hermes.Curator
  alias Hermes.Skills.Telemetry

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    state = Curator.load_state()

    if state.paused do
      Logger.info("Curator skipped: paused")
      :ok
    else
      counts = Telemetry.apply_automatic_transitions()

      if consolidation_enabled?() do
        run_consolidation()
      end

      now = DateTime.utc_now()

      new_state = %{
        state
        | last_run_at: DateTime.to_iso8601(now),
          run_count: state.run_count + 1
      }

      Curator.persist_state(new_state)

      Logger.info("Curator run completed: #{inspect(counts)}")
      :ok
    end
  end

  defp consolidation_enabled? do
    Application.get_env(:hermes, :skills, [])
    |> Keyword.get(:consolidate, false)
  end

  defp run_consolidation do
    cfg = Application.get_env(:hermes, :curator, [])
    provider = Keyword.get(cfg, :provider, Hermes.Providers.Anthropic)
    model = Keyword.get(cfg, :model, "claude-sonnet-4-20250514")

    Hermes.Curator.Consolidation.run(provider: provider, model: model)
  end
end
