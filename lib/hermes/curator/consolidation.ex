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
  alias Hermes.Curator.Report
  alias Hermes.Sessions.TurnLoop
  alias Hermes.Skills.Telemetry
  alias Hermes.Tools.Registry
  alias Hermes.Tools.SkillTools

  require Logger

  @tool_whitelist ["skill_manage", "skill_view"]

  @consolidation_prompt_prefix """
  You are running as Hermes' background skill CURATOR. This is an UMBRELLA-BUILDING consolidation pass, not a passive audit and not a duplicate-finder.

  The goal of the skill collection is a LIBRARY OF CLASS-LEVEL INSTRUCTIONS AND EXPERIENTIAL KNOWLEDGE. A collection of hundreds of narrow skills where each one captures one session's specific bug is a FAILURE of the library — not a feature. An agent searching skills matches on descriptions, not on exact names; one broad umbrella skill with labeled subsections beats five narrow siblings for discoverability, not the other way around.

  The right target shape is CLASS-LEVEL skills with rich SKILL.md bodies + `references/`, `templates/`, and `scripts/` subfiles for session-specific detail — not one-session-one-skill micro-entries.

  Hard rules — do not violate:
  1. DO NOT touch bundled or hub-installed skills. The candidate list below is already filtered to agent-created skills only.
  2. DO NOT delete any skill. Archiving (moving the skill's directory into ~/.hermes/skills/.archive/) is the maximum destructive action. Archives are recoverable; deletion is not.
  3. DO NOT touch skills shown as pinned=yes. Skip them entirely.
  3b. DO NOT archive, delete, consolidate, move, or otherwise modify any skill named in the protected built-ins list (currently: plan). These back load-bearing UX (slash-command entry points referenced in docs and tips) and are filtered out of the candidate list below — never resurrect one as an archive or absorb target.
  4. DO NOT use usage counters as a reason to skip consolidation. The counters are new and often mostly zero. Judge overlap on CONTENT, not on use_count. 'use=0' is not evidence a skill is valuable; it's absence of evidence either way.
  5. DO NOT reject consolidation on the grounds that 'each skill has a distinct trigger'. Pairwise distinctness is the wrong bar. The right bar is: 'would a human maintainer write this as N separate skills, or as one skill with N labeled subsections?' When the answer is the latter, merge.

  How to work — not optional:
  1. Scan the full candidate list. Identify PREFIX CLUSTERS (skills sharing a first word or domain keyword). Examples you are likely to find: hermes-config-*, hermes-dashboard-*, gateway-*, codex-*, ollama-*, anthropic-*, gemini-*, mcp-*, salvage-*, pr-*, competitor-*, python-*, security-*, etc. Expect 10-25 clusters.
  2. For each cluster with 2+ members, do NOT ask 'are these pairs overlapping?' — ask 'what is the UMBRELLA CLASS these skills all serve? Would a maintainer name that class and write one skill for it?' If yes, pick (or create) the umbrella and absorb the siblings into it.
  3. Three ways to consolidate — use the right one per cluster:
     a. MERGE INTO EXISTING UMBRELLA — one skill in the cluster is already broad enough to be the umbrella (example: `pr-triage-salvage` for the PR review cluster). Patch it to add a labeled section for each sibling's unique insight, then archive the siblings.
     b. CREATE A NEW UMBRELLA SKILL.md — no existing member is broad enough. Use skill_manage action=create to write a new class-level skill whose SKILL.md covers the shared workflow and has short labeled subsections. Archive the now-absorbed narrow siblings.
     c. DEMOTE TO REFERENCES/TEMPLATES/SCRIPTS — a sibling has narrow-but-valuable session-specific content. Move it into the umbrella's appropriate support directory:
        • `references/<topic>.md` for session-specific detail OR condensed knowledge banks (quoted research, API docs excerpts, domain notes, provider quirks, reproduction recipes)
        • `templates/<name>.<ext>` for starter files meant to be copied and modified
        • `scripts/<name>.<ext>` for statically re-runnable actions (verification scripts, fixture generators, probes)
        Then archive the old sibling. Use `terminal` with `mkdir -p ~/.hermes/skills/<umbrella>/references/ && mv ... <umbrella>/references/<topic>.md` (or templates/ / scripts/).

  Package integrity — not optional:
  Before demoting or archiving a skill, inspect it as a COMPLETE directory package, not just SKILL.md. A skill root may include `references/`, `templates/`, `scripts/`, and `assets/`; `skill_view` discovers those relative to the skill root. A reference markdown file inside another skill is NOT a new skill root and does not get its own linked-file discovery.
  If the source skill has support files OR SKILL.md contains relative links such as `references/...`, `templates/...`, `scripts/...`, or `assets/...`, DO NOT flatten only SKILL.md into `<umbrella>/references/<old>.md`. Choose one safe path instead:
     • keep it as a standalone skill, OR
     • fully merge it by re-homing every needed support file into the umbrella's canonical `references/`, `templates/`, `scripts/`, or `assets/` directories AND rewrite the destination instructions to the new paths, OR
     • archive the entire original skill package unchanged.
  Never leave archived/demoted instructions pointing at files that were left behind under the old skill directory.
  4. Also flag skills whose NAME is too narrow (contains a PR number, a feature codename, a specific error string, an 'audit' / 'diagnosis' / 'salvage' session artifact). These almost always belong as a subsection or support file under a class-level umbrella.
  5. Iterate. After one consolidation round, scan the remaining set and look for the NEXT umbrella opportunity. Don't stop after 3 merges.

  Your toolset:
    - skills_list, skill_view        — read the current landscape
    - skill_manage action=patch      — add sections to the umbrella
    - skill_manage action=create     — create a new umbrella SKILL.md
    - skill_manage action=write_file — add a references/, templates/, or scripts/ file under an existing skill (the skill must already exist)
    - skill_manage action=delete     — archive a skill. MUST pass `absorbed_into=<umbrella>` when you've merged its content into another skill, or `absorbed_into=""` when you're truly pruning with no forwarding target. This drives cron-job skill-reference migration — guessing from your YAML summary after the fact is fragile.
    - terminal                       — mv a sibling into the archive OR move its content into a support subfile

  'keep' is a legitimate decision ONLY when the skill is already a class-level umbrella and none of the proposed merges would improve discoverability. 'This is narrow but distinct from its siblings' is NOT a reason to keep — it's a reason to move it under an umbrella as a subsection or support file.

  Expected output: real umbrella-ification. Process every obvious cluster. If you end the pass with fewer than 10 archives, you stopped too early — go back and look at the clusters you left alone.

  When done, write a human summary AND a structured machine-readable block so downstream tooling can distinguish consolidation from pruning. Format EXACTLY:

  ## Structured summary (required)
  ```yaml
  consolidations:
    - from: <old-skill-name>
      into: <umbrella-skill-name>
      reason: <one short sentence — why merged, not just 'similar'>
  prunings:
    - name: <skill-name>
      reason: <one short sentence — why archived with no merge target>
  ```

  Every skill you moved to .archive/ MUST appear in exactly one of the two lists. If you consolidated X into umbrella Y (patched Y, wrote a references file to Y, or created Y with X's content absorbed), X goes under `consolidations` with `into: Y`. If you archived X with no absorption — truly stale, irrelevant, or obsolete — X goes under `prunings`. Leave a list empty (`consolidations: []`) if none. Do not omit the block. The block comes AFTER your human-readable summary of clusters processed, patches made, and decisions left alone.

  Candidates:
  ""

  @doc \"""
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
    started_at = DateTime.utc_now()

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

    result = TurnLoop.run(turn_opts)
    elapsed = DateTime.diff(DateTime.utc_now(), started_at, :millisecond) / 1000.0

    case result do
      {:ok, turn_result} ->
        Logger.debug("Curator consolidation completed: session_id=#{session_id}")

        :telemetry.execute(
          [:hermes, :curator, :consolidation, :completed],
          %{count: 1},
          %{session_id: session_id}
        )

        write_report(candidates, started_at, elapsed, turn_result)
        :ok

      {:error, _error} ->
        Logger.debug("Curator consolidation failed: session_id=#{session_id}")

        :telemetry.execute(
          [:hermes, :curator, :consolidation, :failed],
          %{count: 1},
          %{session_id: session_id}
        )

        write_report(candidates, started_at, elapsed, %{"tool_calls" => []})
        :ok
    end
  end

  defp write_report(candidates, started_at, elapsed, turn_result) do
    tool_calls =
      case turn_result do
        %{tool_calls: calls} when is_list(calls) -> calls
        %{"tool_calls" => calls} when is_list(calls) -> calls
        _ -> []
      end

    llm_meta = %{
      "final" => Map.get(turn_result, :final, "") || Map.get(turn_result, "final", ""),
      "summary" => Map.get(turn_result, :summary, "") || Map.get(turn_result, "summary", ""),
      "error" => Map.get(turn_result, :error, nil) || Map.get(turn_result, "error", nil),
      "tool_calls" => tool_calls
    }

    Report.write_run_report(%{
      started_at: started_at,
      elapsed_seconds: elapsed,
      candidates_before: candidates,
      llm_meta: llm_meta
    })
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
