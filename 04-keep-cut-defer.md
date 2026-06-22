# 04 — Keep / Cut / Defer

> Derived from `03-feature-scores.md`. Every **CUT** carries (a) ≥1 bloat signal and
> (b) a **safety check** that nothing load-bearing depends on it. Genuinely ambiguous
> calls go to **DEFER** and `DECISIONS.md`. The closed learning loop is preserved — no
> part of it is cut.

---

## KEEP — Phase-1 scope (best & critical)

Ranked by weighted score. These define the rewrite's first milestones.

| # | Feature | W | Why keep | Evidence |
|---|---|:-:|---|---|
| 1 | SQLite session/message store | 4.25 | The state spine; everything reads/writes it | `hermes_state.py:519-592` |
| 2 | **Self-authored skills** | 4.20 | Differentiator write-path | `tools/skill_manager_tool.py:301` |
| 3 | Filesystem tools | 4.15 | Universal primitive; skill substrate | `tools/file_tools.py:1735` |
| 4 | Iteration budget / loop control | 4.10 | Bounds every turn | `agent/iteration_budget.py:17` |
| 5 | **FTS5 recall (CJK trigram)** | 4.10 | Differentiator read-path; cheap, offline | `hermes_state.py:612-664` |
| 6 | Agentic turn loop | 4.05 | The core loop itself | `agent/conversation_loop.py:589` |
| 7 | Built-in memory (profile/notes) | 3.85 | Persistent identity | `tools/memory_tool.py:1040` |
| 8 | Tool dispatch (`invoke_tool`) | 3.80 | Single dispatch point | `agent/agent_runtime_helpers.py:1733` |
| 9 | `todo` planning | 3.80 | Multi-step state | `tools/todo_tool.py:300` |
| 10 | Terminal tool | 3.75 | The agent's hands | `tools/terminal_tool.py:2738` |
| 11 | Gateway runtime | 3.75 | The messaging brain | `gateway/run.py` |
| 12 | Chat REPL (CLI) | 3.75 | First-class required surface | `cli.py:14588` |
| 13 | Skill usage telemetry | 3.65 | Feeds the curator | `tools/skill_usage.py:460` |
| 14 | Provider transport abstraction | 3.65 | The LLM boundary | `agent/transports/__init__.py` |
| 15 | Web search/extract | 3.65 | External knowledge | `tools/web_tools.py:1356` |
| 16 | Per-session async isolation + agent cache | 3.60 | Maps to per-session `GenServer` | `gateway/run.py:2604` |
| 17 | Sub-agent delegation | 3.55 | Maps to `DynamicSupervisor` | `tools/delegate_tool.py:3160` |
| 18 | **Curator** | 3.55 | Differentiator improve/retire | `agent/curator.py:276` |
| 19 | `clarify` (human-in-loop) | 3.50 | Approval/escalation | `tools/clarify_tool.py:181` |
| 20 | Cron scheduled routines | 3.50 | Self-scheduling agent | `cron/scheduler.py` |
| 21 | **Background review** (auto skill extraction) | 3.45 | Differentiator trigger | `agent/background_review.py:45` |
| 22 | Platform registry / registration | 3.45 | Connector extensibility | `gateway/platform_registry.py:172` |
| 23 | Connectors **Tier-1** (telegram, discord, slack, whatsapp, signal, email, feishu) | 3.45 | The kept connector set | `plugins/platforms/*` |
| 24 | Context compression / context engine | 3.40 | Long-session survival | `agent/context_engine.py:32` |
| 25 | `execute_code` sandbox | 3.40 | General compute | `tools/code_execution_tool.py:1837` |
| 26 | `cronjob` tool | 3.40 | Agent-driven scheduling | `tools/cronjob_tools.py:945` |
| 27 | Conversation compression | 3.40 | Context budget mgmt | `agent/conversation_compression.py:281` |
| 28 | Plugin system (loader + context) | 3.40 | Extensibility backbone | `hermes_cli/plugins.py:315` |
| 29 | Error classifier / retry-fallback | 3.35 | Robustness | `agent/error_classifier.py` |
| 30 | Authz / allowlist / approval | 3.35 | Gateway safety | `gateway/authz_mixin.py` |
| 31 | Command framework (argparse → CLI) | 3.35 | CLI structure | `hermes_cli/_parser.py:84` |
| 32 | Streaming (deltas → consumer) | 3.35 | Live UX over Channels | `gateway/stream_consumer.py:79` |
| 33 | Prompt caching | 3.30 | Cost/latency | `agent/conversation_loop.py:817` |
| 34 | Model fallback chains | 3.30 | Resilience | fallback cmd |
| 35 | Credential pool / sources | 3.30 | Multi-account auth | `agent/credential_pool.py` |
| 36 | Bundled skill library (34 cats) | 3.30 | Cold-start value | `skills/` |
| 37 | Memory provider abstraction | 3.25 | Pluggable backends | `agent/memory_provider.py:43` |
| 38 | `setup` / `config` / `model` / `auth` / `sessions` / pickers | 3.05–3.25 | Required CLI operations | `hermes_cli/subcommands/*` |
| 39 | TUI surface (reimplemented in **ratatui**) | 2.85 | First-class required surface | `ui-tui/` (behavior reference) |

**KEEP totals: ~39 feature clusters → the Phase-1 spec.** The full top quartile plus the required CLI/TUI surfaces and the connector keep-set.

---

## CUT — out of scope for the rewrite (bloat)

Each row: bloat signal + **safety check** (who depends on it → confirmed safe to drop).

| Feature | W | Bloat signal | Safety check (evidence) |
|---|:-:|---|---|
| `batch_runner.py` | 1.60 | RESEARCH | Imported only by `run_agent.py` (trajectory helpers) + `hermes_bootstrap` module list; **not** in `cli.py`/gateway path. Safe → move to `scripts/eval/`. |
| `mini_swe_runner.py` | 1.60 | RESEARCH | Standalone `fire` CLI; only trajectory-format coupling to `run_agent.py`. No runtime importer. Safe. |
| `trajectory_compressor.py` | 1.45 | RESEARCH | Imported only by `scripts/sample_and_compress.py` (data-prep). Not in agent runtime. Safe. |
| `toolset_distributions.py` | 1.75 | RESEARCH | Used by `batch_runner` for synthetic-data sampling only; runtime selects toolsets via `toolsets.py`, not this. Safe. |
| `datagen-config-examples/` | 2.00 | RESEARCH | Example YAML; zero code import. Safe. |
| `claw` (OpenClaw migration) | 1.75 | DEAD/MAINT | One-shot legacy migration subcommand; nothing imports it at runtime. Safe → drop. |
| Electron desktop (`apps/desktop`) | 1.75 | SURFACE | Leaf surface; spawns the Python backend but the backend is self-sufficient (CLI/gateway run without it). Target ships a Rust host + ratatui instead. Safe → drop the Electron shell. |
| Bootstrap installer (`apps/bootstrap-installer`) | 1.80 | SURFACE | Pre-runtime wizard; shells out to CLI. Replaced by Rust first-run extraction. Safe. |
| `tui_gateway/` JSON-RPC broker | 2.50 | DUP | Superseded by Phoenix Channels (target boundary protocol). Behavior is reference-only; nothing in the *new* stack imports it. Safe to not port (port its **handler semantics**, not the transport). |
| Stickers / per-platform media exotica | 1.50 | TAIL | Tied to long-tail connectors being dropped; Tier-1 connectors have their own media paths. Safe. |
| `secrets` (Bitwarden) | 1.85 | MAINT | Single-provider convenience; credentials work via `auth`/env without it. Safe → optional plugin later. |
| `migrate` (xAI model retirement) | 2.00 | MAINT | Time-boxed (retirement date passed/near); not load-bearing. Safe. |
| LSP integration (`agent/lsp`) | 1.60 | SPEC | Niche; no core tool depends on it; coding works via file/terminal tools. Safe → defer/drop. |
| `mixture_of_agents` tool | 1.95 | SPEC | Opt-in ensemble; `delegate_task` covers multi-agent. No core dependency. Safe. |

**CUT discipline:** none of the above is referenced by `agent/conversation_loop.py`, `agent/agent_runtime_helpers.py`, `gateway/run.py`, or `hermes_cli/main.py`'s core command path (verified by grep in Phase 0). The research tooling is genuinely separable — it shares only the *trajectory data format*, which the rewrite does not need.

---

## DEFER — valuable, not Phase 1 (or needs a human call)

| Feature | W | Why defer | Decision ref |
|---|:-:|---|---|
| Connectors **Tier-2** (matrix, google_chat, weixin/wecom, yuanbao, teams) | 2.45 | Add after Tier-1 proves the connector model | `DECISIONS.md#connectors` |
| Connectors **long-tail** (dingtalk, line, simplex, mattermost, irc, sms, ntfy, raft, photon, bluebubbles, qqbot, homeassistant, api_server, webhook, msgraph) | 1.70 | Community/plugin tier; port on demand | `DECISIONS.md#connectors` |
| Web dashboard → **Phoenix LiveView** | 2.40 | Required eventually (peer to TUI on PubSub) but after core | `DECISIONS.md#liveview` |
| ACP IDE adapter | 2.60 | Re-add as a Channels client once boundary is stable | `DECISIONS.md#acp` |
| MCP server + client | 2.60/2.75 | Strategic bridge; stage-2 | — |
| Browser automation (12 tools) | 2.60 | High reimpl cost (Playwright/CDP); port as a Rust/Node sidecar later | `DECISIONS.md#browser` |
| Media tools (image/video gen, TTS, vision) | 1.85–3.10 | Provider-backed; add post-core | — |
| Kanban (tools + 11K-LOC CLI subsystem) | 2.00–2.50 | Whole subsystem; keep as plugin or defer | `DECISIONS.md#kanban` |
| 8 external memory backends | 1.95–2.25 | Pluggable; port abstraction now, backends later | — |
| Home Assistant, computer_use, x_search, Discord/Yuanbao/Feishu tool actions | 1.65–2.00 | Gated/niche tools; port registry, add tools on demand | — |
| Backend-category providers (image/video/browser/tts/web/dashboard_auth) | 2.75 | Follow their tools | — |
| Observability (langfuse/nemo), insights, i18n, backup/import/dump, doctor, update, profiles, logs | 2.25–2.95 | Operational niceties; stage-2 | — |
| Provider adapters beyond the first (gemini/antigravity/bedrock/codex specifics) | n/a | Live, actively developed (see DECISIONS) — port incrementally, **do not cut** | `DECISIONS.md#providers` |

---

## Differentiator preservation statement

The closed learning loop — **self-authored skills (#2 KEEP) → usage telemetry (#13) → curator (#18) → background review (#21) → FTS recall (#5)** — is entirely in KEEP. No element of it appears in CUT. The opt-in LLM consolidation pass and the recall→curator wiring are noted as DEFER-refinements in `DECISIONS.md`, not cuts.
