defmodule Hermes.Tools.CronjobTool do
  @moduledoc """
  Cronjob tool: schedule/list/delete recurring routines via Oban.

  Ports `tools/cronjob_tools.py:945` for the Elixir rewrite. Each routine is
  stored as a row in `cronjob_routines`; an Oban worker fires the routine and
  schedules the next occurrence from the routine's cron expression.
  """

  import Ecto.Query

  alias Hermes.Cronjob.Routine
  alias Hermes.Cronjob.Worker
  alias Hermes.Repo

  @type context :: %{}

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "cronjob",
        toolset: "cronjob",
        schema: cronjob_schema(),
        handler: &invoke/2,
        check_fn: &always_available/0
      }
    ]
  end

  @doc """
  Dispatches a cronjob action and returns a JSON-encodable result.
  """
  @spec invoke(map(), context()) :: map()
  def invoke(args, _context) do
    action = Map.get(args, "action", "list")

    case action do
      "schedule" -> schedule(args)
      "list" -> list()
      "delete" -> delete(args)
      _other -> %{"success" => false, "error" => "Unknown cron action: #{action}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  defp schedule(args) do
    name = Map.get(args, "name")
    cron = Map.get(args, "cron")
    prompt = Map.get(args, "prompt")
    session_id = Map.get(args, "session_id")

    with :ok <- validate_required(name, "name"),
         :ok <- validate_required(cron, "cron"),
         :ok <- validate_required(prompt, "prompt"),
         {:ok, expression} <- parse_cron(cron),
         {:ok, routine} <- create_routine(name, cron, prompt, session_id),
         :ok <- schedule_first_job(routine, expression) do
      %{
        "success" => true,
        "routine_id" => routine.id,
        "name" => routine.name,
        "cron" => routine.cron,
        "next_run_at" => next_run_iso(expression),
        "message" => "Cron routine '#{routine.name}' scheduled."
      }
    else
      {:error, reason} -> %{"success" => false, "error" => reason}
    end
  end

  defp list do
    routines = Repo.all(from r in Routine, order_by: [asc: r.inserted_at])

    %{
      "success" => true,
      "count" => length(routines),
      "routines" => Enum.map(routines, &format_routine/1)
    }
  end

  defp delete(args) do
    id_or_name = Map.get(args, "id") || Map.get(args, "name")

    if is_nil(id_or_name) do
      %{"success" => false, "error" => "id or name is required for delete"}
    else
      case find_routine(id_or_name) do
        nil ->
          %{
            "success" => false,
            "error" =>
              "Routine '#{id_or_name}' not found. Use cronjob(action='list') to inspect routines."
          }

        routine ->
          cancel_pending_jobs(routine.id)
          Repo.delete!(routine)

          %{
            "success" => true,
            "message" => "Cron routine '#{routine.name}' removed.",
            "routine_id" => routine.id
          }
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_routine(name, cron, prompt, session_id) do
    %Routine{}
    |> Routine.changeset(%{
      name: name,
      cron: cron,
      prompt: prompt,
      session_id: session_id,
      enabled: true
    })
    |> Repo.insert()
    |> case do
      {:ok, routine} ->
        {:ok, routine}

      {:error, changeset} ->
        {:error, "Failed to create routine: #{format_changeset_errors(changeset)}"}
    end
  end

  defp schedule_first_job(routine, expression) do
    case Oban.Cron.Expression.next_at(expression, DateTime.utc_now()) do
      :unknown ->
        {:error, "Could not compute next run time for cron expression"}

      next_at ->
        job = Worker.new(%{routine_id: routine.id}, scheduled_at: next_at)

        case Oban.insert(Oban, job) do
          {:ok, _job} ->
            :ok

          {:error, changeset} ->
            {:error, "Failed to schedule job: #{format_changeset_errors(changeset)}"}
        end
    end
  end

  defp parse_cron(cron) do
    {:ok, Oban.Cron.Expression.parse!(cron)}
  rescue
    _error -> {:error, "Invalid cron expression: #{cron}"}
  end

  defp next_run_iso(expression) do
    case Oban.Cron.Expression.next_at(expression, DateTime.utc_now()) do
      :unknown -> nil
      dt -> DateTime.to_iso8601(dt)
    end
  end

  defp find_routine(id_or_name) when is_binary(id_or_name) do
    case Integer.parse(id_or_name) do
      {id, ""} -> Repo.get(Routine, id)
      _ -> Repo.get_by(Routine, name: id_or_name)
    end
  end

  defp find_routine(id) when is_integer(id), do: Repo.get(Routine, id)

  defp cancel_pending_jobs(routine_id) do
    Oban.Job
    |> where([j], j.queue == "cron")
    |> where([j], j.state in ["scheduled", "retryable"])
    |> Repo.all()
    |> Enum.filter(fn job -> job.args["routine_id"] == routine_id end)
    |> Enum.each(&Oban.cancel_job(&1.id))
  end

  defp format_routine(routine) do
    %{
      "id" => routine.id,
      "name" => routine.name,
      "cron" => routine.cron,
      "prompt" => routine.prompt,
      "session_id" => routine.session_id,
      "enabled" => routine.enabled,
      "inserted_at" => NaiveDateTime.to_iso8601(routine.inserted_at)
    }
  end

  defp validate_required(nil, field), do: {:error, "#{field} is required"}

  defp validate_required(value, _field) when is_binary(value) and value != "",
    do: :ok

  defp validate_required(_value, field), do: {:error, "#{field} is required"}

  defp format_changeset_errors(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {msg, _opts}} -> "#{field}: #{msg}" end)
    |> Enum.join(", ")
  end

  defp always_available, do: true

  # ---------------------------------------------------------------------------
  # Schema
  # ---------------------------------------------------------------------------

  defp cronjob_schema do
    %{
      name: "cronjob",
      description: """
      Manage scheduled cron routines.

      Use action='schedule' to create a recurring routine from a prompt and cron expression.
      Use action='list' to inspect routines.
      Use action='delete' to remove a routine by id or name.

      To stop a routine: first action='list' to find the id, then action='delete' with id or name.
      Routines run autonomously; prompts must be self-contained.
      """,
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["schedule", "list", "delete"],
            description: "Action to perform on cron routines."
          },
          name: %{
            type: "string",
            description: "Human-friendly name for the routine. Required for schedule."
          },
          cron: %{
            type: "string",
            description: "Cron expression, e.g. '0 9 * * *'. Required for schedule."
          },
          prompt: %{
            type: "string",
            description: "Prompt to run on each trigger. Required for schedule."
          },
          session_id: %{
            type: "string",
            description:
              "Optional target session id. If omitted, a new session is created per run."
          },
          id: %{
            type: "string",
            description: "Routine id. Required for delete if name is not provided."
          }
        },
        required: ["action"]
      }
    }
  end
end
