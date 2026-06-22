defmodule Hermes.Curator do
  @moduledoc """
  Public API for the background curator.

  Ported from:
    * `agent/curator.py:56-64` (default thresholds, consolidation off)
    * `agent/curator.py:276-331` (`apply_automatic_transitions`)
    * `agent/curator.py:1428-1530` (`run_curator_review`)

  The curator runs as a durable Oban job. By default it only performs the
  deterministic lifecycle prune (active → stale → archived). The LLM
  consolidation pass is opt-in via `:hermes, :skills, consolidate: true`
  (#curator-llm).

  State is persisted in the `state_meta` table under the key `curator_state`,
  replacing Python's `.curator_state` JSON file.
  """

  alias Hermes.Repo
  alias Hermes.Sessions.StateMeta

  @state_key "curator_state"

  @type state :: %{
          last_run_at: DateTime.t() | nil,
          run_count: non_neg_integer(),
          paused: boolean()
        }

  @doc """
  Returns the current curator state.
  """
  @spec get_state() :: state()
  def get_state do
    load_state()
  end

  @doc """
  Manually trigger a curator run by enqueuing an Oban job.
  """
  @spec run_now() :: :ok
  def run_now do
    %{}
    |> Hermes.Curator.Worker.new()
    |> Oban.insert!()

    :ok
  end

  @doc """
  Pause the curator. Ongoing runs finish, but future scheduled runs are skipped.
  """
  @spec pause() :: :ok
  def pause do
    update_state(&%{&1 | paused: true})
  end

  @doc """
  Resume the curator.
  """
  @spec resume() :: :ok
  def resume do
    update_state(&%{&1 | paused: false})
  end

  @doc false
  def load_state do
    case Repo.get(StateMeta, @state_key) do
      nil ->
        default_state()

      %StateMeta{value: value} ->
        case Jason.decode(value, keys: :atoms) do
          {:ok, %{} = map} -> Map.merge(default_state(), map)
          _ -> default_state()
        end
    end
  end

  @doc false
  def persist_state(%{} = state) do
    value = Jason.encode!(state)

    case Repo.get(StateMeta, @state_key) do
      nil ->
        %StateMeta{}
        |> StateMeta.changeset(%{key: @state_key, value: value})
        |> Repo.insert!()

      existing ->
        existing
        |> StateMeta.changeset(%{value: value})
        |> Repo.update!()
    end

    :ok
  end

  defp update_state(mutator) when is_function(mutator, 1) do
    state = load_state()
    state = mutator.(state)
    persist_state(state)
  end

  defp default_state do
    %{
      last_run_at: nil,
      run_count: 0,
      paused: false
    }
  end
end
