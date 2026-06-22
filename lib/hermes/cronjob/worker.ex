defmodule Hermes.Cronjob.Worker do
  @moduledoc """
  Oban worker that fires a cron routine.

  When a routine fires, the worker delivers its prompt to the target session
  (creating one if necessary) and schedules the next occurrence based on the
  routine's cron expression.
  """

  use Oban.Worker, queue: :cron, max_attempts: 3

  alias Hermes.Cronjob.Routine
  alias Hermes.Repo
  alias Hermes.Sessions.SessionServer
  alias Hermes.Sessions.Supervisor, as: SessionSupervisor

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"routine_id" => routine_id}}) do
    case Repo.get(Routine, routine_id) do
      nil ->
        Logger.warning("Cron routine #{routine_id} not found; skipping")
        :ok

      %{enabled: false} = routine ->
        Logger.info("Cron routine #{routine.id} (#{routine.name}) is disabled; skipping")
        :ok

      routine ->
        run_routine(routine)
        schedule_next(routine)
        :ok
    end
  end

  defp run_routine(routine) do
    session_id = ensure_session(routine.session_id)

    case SessionServer.run_turn_async(session_id, routine.prompt) do
      :ok ->
        Logger.info(
          "Cron routine #{routine.id} (#{routine.name}) triggered session #{session_id}"
        )

      {:error, :not_found} ->
        Logger.error(
          "Cron routine #{routine.id} (#{routine.name}) could not find session #{session_id}"
        )
    end
  rescue
    error ->
      Logger.error(
        "Cron routine #{routine.id} (#{routine.name}) failed to run: #{inspect(error)}"
      )
  end

  defp ensure_session(nil) do
    {:ok, _pid, session_id} = SessionSupervisor.start_session()
    session_id
  end

  defp ensure_session(session_id) do
    case SessionServer.whereis(session_id) do
      nil ->
        {:ok, _pid, _} = SessionSupervisor.start_session(session_id: session_id)
        session_id

      _pid ->
        session_id
    end
  end

  defp schedule_next(routine) do
    cron = Oban.Cron.Expression.parse!(routine.cron)

    case Oban.Cron.Expression.next_at(cron, DateTime.utc_now()) do
      :unknown ->
        Logger.info("Cron routine #{routine.id} (#{routine.name}) has no next occurrence")
        :ok

      next_at ->
        job = new(%{routine_id: routine.id}, scheduled_at: next_at)
        Oban.insert(Oban, job)

        Logger.info(
          "Cron routine #{routine.id} (#{routine.name}) scheduled next at #{DateTime.to_iso8601(next_at)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.error(
        "Cron routine #{routine.id} (#{routine.name}) failed to schedule next run: #{inspect(error)}"
      )

      :ok
  end
end
