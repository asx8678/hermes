defmodule Hermes.Curator.Report do
  @moduledoc """
  Per-run curator report writer.

  Ported from `agent/curator.py:1029-1218` (`_write_run_report` and
  `_render_report_markdown`). After each consolidation run writes two files
  under `~/.hermes/curator_reports/<timestamp>/`:

    * `run.json` — machine-readable record
    * `REPORT.md` — human-readable summary

  Writing is best-effort: failures are logged but do not fail the curator run.
  """

  alias Hermes.Skills.Telemetry

  require Logger

  @type report_input :: %{
          started_at: DateTime.t(),
          elapsed_seconds: float(),
          candidates_before: [map()],
          llm_meta: map()
        }

  @doc """
  Writes the per-run report for a consolidation pass.
  """
  @spec write_run_report(report_input()) :: String.t() | nil
  def write_run_report(%{
        started_at: started_at,
        elapsed_seconds: elapsed_seconds,
        candidates_before: candidates_before,
        llm_meta: llm_meta
      }) do
    run_dir = ensure_run_dir(started_at)

    if run_dir do
      candidates_after =
        Telemetry.list_skills_by_state(:stale) ++
          Telemetry.list_skills_by_state(:archived)

      payload =
        build_payload(started_at, elapsed_seconds, candidates_before, candidates_after, llm_meta)

      try do
        File.write!(Path.join(run_dir, "run.json"), Jason.encode!(payload, pretty: true) <> "\n")
        File.write!(Path.join(run_dir, "REPORT.md"), render_markdown(payload))
        run_dir
      rescue
        e ->
          Logger.debug("Curator report write failed: #{inspect(e)}")
          nil
      end
    end
  end

  defp ensure_run_dir(started_at) do
    root = Path.join(System.user_home!(), ".hermes/curator_reports")

    case File.mkdir_p(root) do
      :ok ->
        stamp = Calendar.strftime(started_at, "%Y%m%d-%H%M%S")
        run_dir = Path.join(root, stamp)

        case mkdir_unique(run_dir, 1) do
          {:ok, path} ->
            path

          {:error, e} ->
            Logger.debug("Curator run dir create failed: #{inspect(e)}")
            nil
        end

      {:error, e} ->
        Logger.debug("Curator reports dir create failed: #{inspect(e)}")
        nil
    end
  end

  defp mkdir_unique(path, suffix) when suffix <= 99 do
    candidate = if suffix == 1, do: path, else: "#{path}-#{suffix}"

    case File.mkdir(candidate) do
      :ok -> {:ok, candidate}
      {:error, :eexist} -> mkdir_unique(path, suffix + 1)
      {:error, _} = err -> err
    end
  end

  defp mkdir_unique(_path, _suffix), do: {:error, :too_many_collisions}

  defp build_payload(started_at, elapsed_seconds, before, after_candidates, llm_meta) do
    before_by_name = Map.new(before, fn c -> {c.name, c} end)
    after_by_name = Map.new(after_candidates, fn c -> {c.name, c} end)

    before_names = Map.keys(before_by_name) |> Enum.sort()
    after_names = Map.keys(after_by_name) |> Enum.sort()

    removed = before_names -- after_names
    added = after_names -- before_names

    transitions =
      after_names
      |> Enum.filter(&(&1 in before_names))
      |> Enum.map(fn name ->
        b = Map.get(before_by_name, name)
        a = Map.get(after_by_name, name)

        if b.state != a.state do
          %{name: name, from: b.state, to: a.state}
        end
      end)
      |> Enum.reject(&is_nil/1)

    tool_calls = Map.get(llm_meta, "tool_calls", [])
    tc_counts = Enum.frequencies_by(tool_calls, &Map.get(&1, "name", "unknown"))

    %{
      started_at: DateTime.to_iso8601(started_at),
      duration_seconds: Float.round(elapsed_seconds / 1, 2),
      model: Map.get(llm_meta, "model", ""),
      provider: Map.get(llm_meta, "provider", ""),
      counts: %{
        before: length(before_names),
        after: length(after_names),
        delta: length(after_names) - length(before_names),
        archived_this_run: length(removed),
        added_this_run: length(added),
        consolidated_this_run: 0,
        pruned_this_run: length(removed),
        state_transitions: length(transitions),
        cron_jobs_rewritten: 0,
        tool_calls_total: Enum.sum(Map.values(tc_counts))
      },
      tool_call_counts: tc_counts,
      archived: removed,
      consolidated: [],
      pruned: Enum.map(removed, &%{name: &1}),
      pruned_names: removed,
      added: added,
      state_transitions: transitions,
      cron_rewrites: %{rewrites: [], jobs_updated: 0, jobs_scanned: 0},
      llm_final: Map.get(llm_meta, "final", ""),
      llm_summary: Map.get(llm_meta, "summary", ""),
      llm_error: Map.get(llm_meta, "error"),
      tool_calls: tool_calls
    }
  end

  defp render_markdown(p) do
    lines = []
    lines = ["# Curator run report\n" | lines]

    started = Map.get(p, "started_at", "unknown")
    duration = Map.get(p, "duration_seconds", 0)
    lines = ["**Started**: #{started}  \n**Duration**: #{duration}s\n" | lines]

    counts = Map.get(p, "counts", %{})
    lines = ["## Summary\n" | lines]
    lines = ["- Skills before: #{Map.get(counts, "before", 0)}" | lines]
    lines = ["- Skills after: #{Map.get(counts, "after", 0)}" | lines]
    lines = ["- Archived this run: #{Map.get(counts, "archived_this_run", 0)}" | lines]
    lines = ["- State transitions: #{Map.get(counts, "state_transitions", 0)}" | lines]
    lines = ["- Tool calls: #{Map.get(counts, "tool_calls_total", 0)}\n" | lines]

    consolidated = Map.get(p, "consolidated", [])

    lines =
      render_section(lines, "Consolidated into umbrella skills", consolidated, fn e ->
        name = Map.get(e, "name", "?")
        into = Map.get(e, "into", "?")
        reason = Map.get(e, "reason", "")
        line = "- `#{name}` → `#{into}`"
        if reason != "", do: line <> " — #{reason}", else: line
      end)

    pruned = Map.get(p, "pruned", [])

    lines =
      render_section(lines, "Pruned — archived for staleness", pruned, fn e ->
        name = if is_map(e), do: Map.get(e, "name", "?"), else: e
        reason = if is_map(e), do: Map.get(e, "reason", ""), else: ""
        line = "- `#{name}`"
        if reason != "", do: line <> " — #{reason}", else: line
      end)

    added = Map.get(p, "added", [])
    lines = render_simple_list(lines, "New skills this run", added)

    transitions = Map.get(p, "state_transitions", [])

    lines =
      if Enum.empty?(transitions) do
        lines
      else
        lines = ["### State transitions (#{length(transitions)})\n" | lines]

        lines =
          Enum.reduce(transitions, lines, fn t, acc ->
            ["- `#{Map.get(t, "name")}`: #{Map.get(t, "from")} → #{Map.get(t, "to")}" | acc]
          end)

        ["" | lines]
      end

    llm_final = String.trim(Map.get(p, "llm_final", ""))
    llm_summary = String.trim(Map.get(p, "llm_summary", ""))

    lines =
      if llm_final != "" do
        ["## LLM final summary\n" | lines]
        |> then(&[&1 | String.split(llm_final, "\n")])
        |> then(&["" | &1])
      else
        if llm_summary != "" do
          ["## LLM summary\n" | lines]
          |> then(&[&1 | String.split(llm_summary, "\n")])
          |> then(&["" | &1])
        else
          lines
        end
      end

    lines = ["## Recovery\n" | lines]
    lines = ["- Restore an archived skill: `hermes curator restore <name>`" | lines]

    lines = [
      "- All archives live under `~/.hermes/skills/.archive/` and are recoverable by `mv`."
      | lines
    ]

    lines = ["- See `run.json` in this directory for the full machine-readable record.\n" | lines]

    lines
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp render_section(lines, _title, [], _formatter), do: lines

  defp render_section(lines, title, items, formatter) do
    lines = ["### #{title} (#{length(items)})\n" | lines]

    lines =
      items
      |> Enum.take(50)
      |> Enum.reduce(lines, fn item, acc -> [formatter.(item) | acc] end)

    lines =
      if length(items) > 50 do
        ["- … and #{length(items) - 50} more (see `run.json`)\n" | lines]
      else
        ["" | lines]
      end

    lines
  end

  defp render_simple_list(lines, _title, []), do: lines

  defp render_simple_list(lines, title, items) do
    lines = ["### #{title} (#{length(items)})\n" | lines]
    lines = Enum.reduce(items, lines, fn item, acc -> ["- `#{item}`" | acc] end)
    ["" | lines]
  end
end
