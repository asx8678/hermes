defmodule Hermes.Curator.Consolidation do
  @moduledoc """
  LLM consolidation pass for stale/archived skills.

  Ported from `agent/curator.py` (`run_curator_review` with
  `consolidate=True`). When enabled, it collects skills that have
  transitioned to `:stale` or `:archived` and forks a mini TurnLoop
  with a consolidation prompt. The loop can use `skill_view` to read
  candidates and `skill_manage` to create the new consolidated skill
  and archive the old ones.

  The pass is opt-in and off by default (`:skills, :consolidate, false`).
  """

  alias Hermes.Sessions.TurnLoop
  alias Hermes.Skills.Telemetry
  alias Hermes.Tools.Registry
  alias Hermes.Tools.SkillTools

  require Logger

  @tool_whitelist ["skill_manage", "skill_view"]

  @consolidation_prompt_prefix """
  You are Hermes' skill curator. The skills listed below are currently
  marked stale or archived. They may cover similar ground.

  Your task: consolidate overlapping skills into a single, higher-quality
  skill. Use `skill_view` if you need to re-read a candidate, and use
  `skill_manage` to create or patch the consolidated skill. When done, use
  `skill_manage action=delete` to remove the old stale/archived skills.

  If the candidates are not overlapping enough to merge, say so and stop.

  Candidates:
  """

  @doc """
  Runs the consolidation pass if there are at least two stale or archived
  skills.

  `opts` accepts `:provider`, `:model`, `:api_mode`, `:base_url`, `:api_key`,
  `:finch_name`, `:max_iterations`, and `:system_prompt`. Missing values
  are read from `:hermes, :curator` config and finally fall back to the
  same defaults used by `Hermes.Curator.BackgroundReview`.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    candidates =
      Telemetry.list_skills_by_state(:stale) ++
        Telemetry.list_skills_by_state(:archived)

    if length(candidates) >= 2 do
      run_consolidation_loop(candidates, opts)
    else
      :ok
    end
  end

  defp run_consolidation_loop(candidates, opts) do
    opts = normalize_opts(opts)
    session_id = "consolidation-#{System.unique_integer([:positive])}"

    prompt = build_prompt(candidates)
    messages = [%{role: "user", content: prompt}]
    tools = Registry.list_schemas(@tool_whitelist)

    turn_opts = [
      session_id: session_id,
      messages: messages,
      model: opts[:model],
      provider: opts[:provider],
      api_mode: opts[:api_mode],
      base_url: opts[:base_url],
      api_key: opts[:api_key],
      tools: tools,
      max_iterations: opts[:max_iterations],
      budget_grace_call: false,
      finch_name: opts[:finch_name],
      system_prompt: opts[:system_prompt]
    ]

    candidate_names = Enum.map(candidates, & &1.name)

    Logger.debug(
      "Curator consolidation starting for #{length(candidates)} candidate(s): #{inspect(candidate_names)}"
    )

    :telemetry.execute(
      [:hermes, :curator, :consolidation, :started],
      %{count: 1},
      %{session_id: session_id, candidates: candidate_names}
    )

    case TurnLoop.run(turn_opts) do
      {:ok, _result} ->
        Logger.debug("Curator consolidation completed: session_id=#{session_id}")

        :telemetry.execute(
          [:hermes, :curator, :consolidation, :completed],
          %{count: 1},
          %{session_id: session_id}
        )

        :ok

      {:error, _error} ->
        Logger.debug("Curator consolidation failed: session_id=#{session_id}")

        :telemetry.execute(
          [:hermes, :curator, :consolidation, :failed],
          %{count: 1},
          %{session_id: session_id}
        )

        :ok
    end
  end

  defp build_prompt(candidates) do
    sections =
      candidates
      |> Enum.map(fn candidate ->
        name = candidate.name
        content = load_skill_content(name)

        """
        --- Skill: #{name} ---
        #{content}
        """
      end)
      |> Enum.join("\n\n")

    @consolidation_prompt_prefix <> "\n\n" <> sections
  end

  defp load_skill_content(name) do
    case SkillTools.invoke("skill_view", %{"name" => name}) do
      %{"success" => true, "content" => content} when is_binary(content) ->
        content

      _ ->
        "(could not load content for skill '#{name}')"
    end
  end

  defp normalize_opts(opts) do
    app_cfg = Application.get_env(:hermes, :curator, [])

    [
      provider: fetch(opts, app_cfg, :provider, Hermes.Providers.Anthropic),
      model: fetch(opts, app_cfg, :model, "claude-sonnet-4-20250514"),
      api_mode: fetch(opts, app_cfg, :api_mode, "anthropic_messages"),
      base_url: fetch(opts, app_cfg, :base_url, nil),
      api_key: fetch(opts, app_cfg, :api_key, nil),
      finch_name: fetch(opts, app_cfg, :finch_name, Hermes.Finch),
      max_iterations: fetch(opts, app_cfg, :max_iterations, 5),
      system_prompt: fetch(opts, app_cfg, :system_prompt, nil)
    ]
  end

  defp fetch(opts, app_cfg, key, default) do
    Keyword.get(opts, key) ||
      Keyword.get(app_cfg, key) ||
      default
  end
end
