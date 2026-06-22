# DECISIONS — Human-Gated Decision Log

> Every genuinely ambiguous keep/cut call, every place the audit defers to a human, and
> every concern about a *locked* architecture decision. Resolve these before or during the
> relevant milestone. Nothing here was decided silently in the audit.

Status legend: **OPEN** (needs a human call) · **RECOMMENDED** (audit has a recommendation, confirm) · **WATCH** (proceed, revisit if assumption breaks).

---

## #providers — Provider adapters: which to port, and the "dead code" question — RECOMMENDED
Only 4 transports are registered (`anthropic`, `codex`, `bedrock`, `chat_completions`;
`agent/transports/__init__.py:54-66`). Standalone files `agent/gemini_native_adapter.py`
and `gemini_cloudcode_adapter.py` exist; Antigravity routes through `chat_completions` +
OAuth (`agent/antigravity_*`, `agent/google_*`) and is **actively developed** (recent
commits add native Antigravity OAuth). **Recommendation:** treat all provider paths as
**live, port incrementally** (Anthropic first); do **not** cut gemini/antigravity as "dead
code." **Open question for a human:** is there a single must-have launch provider beyond
Anthropic (e.g. an OpenRouter/`chat_completions` umbrella) that should be in Milestone A
rather than deferred?

## #connectors — Kept connector set — RECOMMENDED
Audit picks **7 Tier-1**: telegram, discord, slack, whatsapp, signal, email, feishu
(`05§E`). LOC/maturity are `INFERRED` (no usage telemetry was available). **Human call:**
confirm the keep-set against real install/usage data. Notable judgment calls: **Feishu** is
kept (very large, mature — 7.5K LOC) but is China-market; **iMessage/BlueBubbles** is in the
long tail despite user demand (Mac-only bridge). Should iMessage be promoted to Tier-1?

## #storage — SQLite FTS5 vs Postgres+pgvector — RECOMMENDED
Core recall is keyword-only FTS5 (verified zero embeddings). Audit recommends **SQLite
FTS5** for Phase 1 (`05§D`). **Two triggers to revisit, for a human to weigh:**
(1) does the product roadmap intend the learning loop to use **semantic/embedding** recall
(today plugin-only)? If yes soon → consider Postgres+pgvector earlier.
(2) **Server mode** (multi-tenant VPS gateway) may want **one shared Postgres** for
operational reasons (backups, concurrent writers across sessions) independent of vectors —
this could split storage by delivery mode (SQLite desktop / Postgres server). Decide whether
to accept that split or standardize on one.

## #curator-llm — Curator LLM consolidation default — OPEN
The umbrella-building LLM consolidation pass is **off by default** today
(`curator.consolidate=false`, `agent/curator.py`). The deterministic prune
(active→stale→archived) is the part that actually runs everywhere. **Human call:** in the
rewrite, should LLM consolidation be **on by default** (it is arguably the most
differentiated half of the loop), or remain opt-in? This changes how central the curator's
Oban job is.

## #curator-recall — Wire recall into the curator? — OPEN
`session_search` (FTS recall) exists but the background-review prompt does **not** currently
mandate multi-session recall (`UNVERIFIED` whether it's ever invoked during review). The
loop "closes" without it, but wiring recall → curator would make skill improvement
evidence-driven across history. **Human call:** is closing this gap in-scope for Phase-1
parity, or a deliberate enhancement for later?

## #acp — ACP IDE adapter timing — OPEN
ACP (`acp_adapter/`, VS Code/Zed/JetBrains) instantiates `AIAgent` **directly in-process**
today (not via any gateway). In the target it becomes **another Channels client**. Audit
**DEFERs** it past Phase 1. **Human call:** is IDE integration a launch requirement (pull it
into Milestone B/C) or genuinely post-Phase-1?

## #liveview — Web dashboard depth — RECOMMENDED
The Python dashboard is large (`hermes_cli/web_server.py` ~12.9K LOC + `web/` SPA). Target
is **LiveView**. Audit recommends a **basic** LiveView (sessions/status) in Milestone C and
defers feature-parity. **Human call:** confirm minimal-dashboard-first; identify any
must-have dashboard feature (billing? analytics? kanban board?) that forces earlier depth.

## #kanban — Kanban subsystem fate — OPEN
Kanban is an entire subsystem: 9 agent tools (`tools/kanban_tools.py`) + ~11K LOC CLI/DB
(`hermes_cli/kanban_db.py`, `kanban.py`) + dashboard. It powers multi-agent coordination.
Audit marks it **DEFER**. **Human call:** is kanban core to the intended product (→ keep,
port as Elixir/Ecto + LiveView) or a power-user feature (→ plugin/later)?

## #desktop — Dropping Electron — RECOMMENDED (confirm)
Audit **CUTs** the Electron desktop (`apps/desktop`) and bootstrap installer, replaced by
the Rust host + ratatui + first-run extraction. This is a **product decision**: today's
desktop is a GUI window app; the target "desktop mode" is a single binary that opens a TUI.
**Human call:** is losing the GUI desktop window (in favor of a terminal UI binary)
acceptable for the desktop audience? If a GUI is required, that's a LiveView-in-a-webview
decision to add to scope.

## #tokenizer — CJK FTS parity risk — WATCH
The trigram tokenizer (`hermes_state.py:641-664`) plus a unicode61 table and a LIKE fallback
for 1–2 char CJK tokens is subtle. **Watch:** verify `ecto_sqlite3`/`exqlite` expose FTS5
trigram and that query behavior matches the Python ranking (BM25 + temporal sort). Capture
golden CJK queries as parity tests. Escalate if the Elixir SQLite binding lacks trigram.

## #loop-port — Faithful turn-loop port — WATCH
`agent/conversation_loop.py` is ~4K LOC with many edge cases (codex ack loops, thinking-only
recovery, compression retries, budget grace call). **Watch / risk:** plan golden-transcript
tests from the Python agent to prove parity; treat any silently-dropped edge case as a
defect, not a simplification. Some behaviors (e.g. `copilot-acp` special-casing) are
provider-specific and may be deferred with the provider.

## #single-binary-new — Packaging is greenfield — WATCH
Hermes ships today as uv/pip + Docker + Nix + Homebrew — **no compiled single binary
exists** (no PyInstaller/Nuitka/PEX). The Rust-host-embeds-BEAM model is **new work**, not a
port. **Watch:** budget real time for the per-(OS,arch) matrix, ERTS/NIF native builds,
zstd-embed, extraction/versioning, and code-signing (Milestones B + E).

## #research-tooling — Where cut tooling goes — RECOMMENDED
`batch_runner.py`, `mini_swe_runner.py`, `trajectory_compressor.py`,
`toolset_distributions.py`, `datagen-config-examples/` are eval/training tooling, **cut from
the runtime**. **Recommendation:** don't delete upstream — relocate to a separate
`scripts/eval/` or repo so the Nous training/eval workflows survive. Confirm no CI depends on
them in place.

## Locked-architecture concerns (none are vetoes — raised per the rules)
- **WATCH — sidecar overhead:** routing `terminal`/`execute_code` to sidecars adds IPC
  latency vs in-VM calls. Correct for safety, but measure; a high-frequency `terminal` may
  want a persistent sidecar pool rather than spawn-per-call.
- **WATCH — SQLite single-writer under the gateway:** many concurrent sessions writing one
  SQLite file (server mode) stresses the single-writer model; the per-session GenServer
  serializes per session but not across sessions. This reinforces **#storage** (Postgres for
  server mode).
- No locked decision is assessed as *wrong*; the above are risks to manage, not deviations.
