# 01 — Discovery & Inventory

> Evidence-based map of the Hermes source tree (`hermes-agent/`). Every claim cites
> `path:line` where verifiable. Items I could not confirm are tagged `UNVERIFIED` or
> `INFERRED`. This phase makes **no keep/cut judgments**.

---

## 0. Headline corrections to the Prior Context

| Prior belief | Reality (verified) | Evidence |
|---|---|---|
| Implementation stack unspecified / assumed TS | **Python-dominant core (~1.16M LOC Python, 2,470 files)**; Node/TS only at the edges | `find . -name '*.py' \| wc -l` → 2,470; `cli.py` 689KB, `run_agent.py` 246KB, `hermes_state.py` 218KB |
| "single core spanning multiple surfaces" | **Confirmed.** One `AIAgent` core; CLI/TUI/gateway/ACP/desktop/web all drive it | `pyproject.toml:296-299` three entry points; `run_agent.py` `AIAgent` |
| "~29 platform connectors" | **~31 connectors** (11 built-in + 20 plugin) — close | `gateway/platforms/*.py` + `plugins/platforms/*/` (20 dirs) |
| "~6 core tools" (narrow waist) | **48 always-on tools** (`_HERMES_CORE_TOOLS`), 64 registered total; cluster into ~10 capability *families* | `toolsets.py:31-74`; registry total via `tools/registry.py` |
| "Ink terminal UI / Electron desktop / web dashboard / ACP adapter" | **All confirmed present** as Node/TS surfaces over the Python core | `ui-tui/` (Ink+React), `apps/desktop/` (Electron), `web/` (Vite), `acp_adapter/` |
| "closed learning loop: self-created skills + curator + telemetry + FTS recall + pluggable memory" | **Confirmed and load-bearing** | `agent/curator.py` (1,916 LOC), `tools/skill_usage.py`, `hermes_state.py` FTS5, `plugins/memory/` (8 backends) |
| Built by Nous Research | **Confirmed** | `package.json` repo `NousResearch/Hermes-Agent`; `pyproject.toml:21` |

---

## 1. Languages, build, packaging, distribution

- **Core language:** Python `>=3.11,<3.14` (`pyproject.toml:20`). Packaged with `setuptools` (`pyproject.toml:4-6`); deps **exact-pinned** as a supply-chain control (`pyproject.toml:24-48`, hardened after the Mini Shai-Hulud worm). Lockfiles: `uv.lock` (628KB), `package-lock.json` (675KB).
- **Edge language:** TypeScript/React across npm workspaces (`package.json` `workspaces: apps/*, ui-tui, ui-tui/packages/*, web`). Node `>=20`.
- **Entry points** (`pyproject.toml:296-299`):
  - `hermes = hermes_cli.main:main` — the CLI (and default chat REPL)
  - `hermes-agent = run_agent:main` — the agent runner
  - `hermes-acp = acp_adapter.entry:main` — the ACP IDE adapter
- **Distribution today (NOT a single compiled binary):**
  - **Docker** — multi-stage (uv+python3.13, node22, debian13) `Dockerfile:1-40`; server/gateway delivery.
  - **Nix flake** — full derivations `nix/packages.nix`, `nix/desktop.nix`, `nix/tui.nix`, `nix/web.nix`, `nix/nixosModules.nix`; `flake.nix`.
  - **Homebrew** — `packaging/homebrew/`.
  - **Install scripts** — `hermes_cli/scripts/install.sh`, `install.ps1`; `setup-hermes.sh` (root).
  - No PyInstaller/Nuitka/PEX/shiv anywhere → the **Rust-host single binary embedding a BEAM release is a brand-new packaging model**, not a port of an existing one. (Carry into Decision Log.)

---

## 2. Surfaces present (each with entry point)

| Surface | Stack | Entry point | Connects to core via |
|---|---|---|---|
| **CLI / chat REPL** | Python (argparse) | `hermes_cli/main.py` → `cli.py:main` (`cli.py:14588`) | in-process `AIAgent` |
| **Messaging gateway** | Python asyncio | `gateway/run.py:start_gateway` (`GatewayRunner`) | in-process `AIAgent` per session (thread pool), per-platform async tasks |
| **Ink TUI** | TypeScript, Ink 6 + React 19 | `ui-tui/src/entry.tsx:51` | **`tui_gateway/` broker**: stdio JSON-RPC (spawned) or WebSocket (attached) — `ui-tui/src/gatewayClient.ts:340-413,683-737` |
| **TUI gateway broker** | Python (~12K LOC) | `tui_gateway/entry.py:263-348` | spawns `AIAgent` per session; `server.py` dispatcher |
| **Web dashboard** | TypeScript, Vite + React 19 + Router 7 | `web/src/main.tsx:15` | HTTP REST + WebSocket to `hermes_cli/web_server.py` (12.9K LOC) |
| **Electron desktop** | Electron 31 + React | `apps/desktop/electron/main.cjs` | spawns Python backend; WebSocket via `apps/shared/src/json-rpc-gateway.ts` |
| **Bootstrap installer** | Vite + React | `apps/bootstrap-installer/src/main.tsx:10` | first-run wizard; shells out to `hermes` CLI |
| **ACP IDE adapter** | Python asyncio (ACP) | `acp_adapter/entry.py:212-262` (`hermes-acp`) | **direct in-process `AIAgent`** (NOT via tui_gateway); registry `acp_registry/agent.json` |

**Key wire-protocol finding:** the existing TUI↔core protocol is **JSON-RPC 2.0** over **stdio (spawned) or WebSocket (attached)** with a `GatewayEvent` union (~30 event types, `ui-tui/src/gatewayTypes.ts:610-649`). The target architecture replaces this with **Phoenix Channels over localhost WebSocket**. ACP and the web dashboard each speak their own JSON-RPC/REST today — the rewrite unifies all of them onto Channels.

---

## 3. Platform connectors (full list)

**Built-in** (`gateway/platforms/`): signal (1,701), whatsapp_cloud (1,956), weixin (2,358), yuanbao (5,358), qqbot (3,196+helpers), bluebubbles (1,038), api_server (4,535), webhook (1,022), msgraph_webhook (421). Shared: base.py (5,152), helpers.py (278).

**Plugin** (`plugins/platforms/<name>/`, 20): discord (7,517), telegram (7,581), feishu (7,537), slack (4,114), matrix (4,376), google_chat (4,018), wecom (2,435), dingtalk (1,710), line (1,655), simplex (1,316), whatsapp/green (1,395), teams (1,446), email (1,025), photon (3,120), mattermost (1,271), irc (974), sms (496), homeassistant (580), ntfy (596), raft (785).

*(LOC are `INFERRED` from per-agent measurement; treat as relative complexity signals, not exact.)* Registration: `gateway/platform_registry.py` `PlatformEntry` + `register()`; plugins self-register via `PluginContext.register_platform()` (`hermes_cli/plugins.py:817`); built-ins via if/elif in `gateway/run.py:_create_adapter`.

---

## 4. The core loop (where a turn happens)

Trace (one turn), all in `agent/` + `run_agent.py`:

1. **Turn setup / system prompt** — `agent/turn_context.py:64` `build_turn_context()`
2. **Memory READ (prefetch)** — `agent/turn_context.py:383,392` (`memory_manager.on_turn_start` / `prefetch_all`)
3. **Agentic loop** — `agent/conversation_loop.py:589` `while api_call_count < max_iterations and budget.remaining > 0` (default `max_iterations=90`, `run_agent.py:356`; budget `agent/iteration_budget.py`)
4. **LLM call** — `agent/chat_completion_helpers.py:interruptible_api_call` (build kwargs `:555`); transport chosen by `api_mode`
5. **Tool dispatch** — `agent/conversation_loop.py:4045` `_execute_tool_calls` → `agent/agent_runtime_helpers.py:1733` `invoke_tool()` → registry / built-ins; `model_tools.handle_function_call`
6. **Turn finalize** — `agent/turn_finalizer.py:30` `finalize_turn()`
7. **Memory WRITE + next-turn prefetch** — `run_agent.py:3127-3135` (`_sync_external_memory_for_turn`, `queue_prefetch_all`)

**LLM provider transports (registered):** `agent/transports/` → `anthropic` (anthropic_messages), `codex` (codex_responses; Copilot/xAI/Codex), `bedrock` (bedrock_converse), `chat_completions` (OpenAI-compatible: OpenRouter, OpenAI, Mistral, Nous, Qwen, Kimi, DeepSeek, LM Studio, Ollama, …). **Antigravity & Google/Gemini are LIVE provider paths** routed through `chat_completions` + OAuth adapters (`agent/antigravity_*`, `agent/google_*`, `agent/transports/chat_completions.py`), not dead code — recent commits actively develop Antigravity. Standalone adapter files `agent/gemini_native_adapter.py` / `gemini_cloudcode_adapter.py` exist; whether each is currently wired is `UNVERIFIED` (flagged in DECISIONS).

---

## 5. The learning loop (the differentiator)

| Stage | Where | Evidence |
|---|---|---|
| **Skill creation** | background-review agent → `skill_manage(action=create)` writes `~/.hermes/skills/<name>/SKILL.md` | `agent/background_review.py:45-148`, `tools/skill_manager_tool.py:301+` |
| **Usage telemetry** | `.usage.json` sidecar; `bump_use/bump_view/bump_patch` | `tools/skill_usage.py` (e.g. `:460-530`), `agent/skill_commands.py:546` |
| **Curator** | auto state transitions active→stale(30d)→archived(90d); opt-in LLM consolidation (umbrella merge) | `agent/curator.py:276-331` (transitions), `:365-503` (LLM prompt), `:1898-1916` (`maybe_run_curator`) |
| **Trigger** | **inactivity-based at session start**, NOT cron; interval 168h, min-idle 2h | `agent/curator.py:219-269` |
| **Recall (FTS)** | `session_search` over SQLite FTS5 (keyword) | `tools/session_search_tool.py`, `hermes_state.py:612-664` |

**Closure verdict:** the loop **closes** for the deterministic prune (create→use→telemetry→curate→next-session sees mutated skills). The **LLM consolidation pass is opt-in** (`curator.consolidate=false` default). Wiring of multi-session *recall into the curator* is `UNVERIFIED` (session_search exists but the review prompt does not mandate it).

---

## 6. Memory / state / search

- **State store:** `hermes_state.py` → SQLite `state.db`. Tables: `sessions`, `messages`, `state_meta`, `compression_locks` (`hermes_state.py:519-592`).
- **Search:** **SQLite FTS5**, two virtual tables — `messages_fts` (unicode61) + `messages_fts_trigram` (trigram, **CJK-aware**), BM25 + optional temporal sort, LIKE fallback (`hermes_state.py:612-664, 3466-3715`).
- **Recall is 100% keyword/FTS5 — NO embeddings in core** (`session_search_tool.py`, `hermes_state.py`: zero `embedding/vector/cosine/faiss` hits).
- **Pluggable memory (8 backends):** `plugins/memory/` — holographic (local HRR vectors), byterover (local CLI), and 6 external-SaaS semantic backends (mem0, hindsight, honcho, retaindb, supermemory, openviking). Abstraction: `agent/memory_provider.py` (one external provider max), managed by `agent/memory_manager.py`.

---

## 7. Dependency sketch — load-bearing vs leaf

**Load-bearing (many inbound refs; core cannot run without):**
`run_agent.py` (`AIAgent`), `agent/conversation_loop.py`, `agent/turn_context.py`, `agent/turn_finalizer.py`, `agent/chat_completion_helpers.py`, `agent/transports/*`, `agent/agent_runtime_helpers.py` (`invoke_tool`), `agent/iteration_budget.py`, `agent/memory_manager.py`, `tools/registry.py` + `model_tools.py` (tool orchestration), `hermes_state.py`, `toolsets.py`, `hermes_constants.py`, `hermes_cli/main.py` + `cli.py` (CLI surface), `gateway/run.py` + `gateway/platforms/base.py` (gateway).

**Leaf / isolated (droppable without breaking the core):**
`apps/desktop`, `apps/bootstrap-installer`, `web` (dashboard), `acp_adapter` (one of N channels), most individual `plugins/platforms/*`, most `plugins/*` features (spotify, google_meet, teams_pipeline, hermes-achievements, …), `batch_runner.py`, `mini_swe_runner.py`, `trajectory_compressor.py`, `datagen-config-examples/`, eval `scripts/*`.

**Research/eval tooling (not agent runtime):** `batch_runner.py` (57KB), `mini_swe_runner.py` (28KB), `trajectory_compressor.py` (69KB), `toolset_distributions.py` (synthetic-data sampling), `datagen-config-examples/`. Imported only by each other / data-prep scripts, never by `cli.py`/gateway. `model_tools.py` is **NOT** in this bucket — it is core tool orchestration (imported by `cli.py`, `run_agent.py`).

---

## 8. Subsystem size table (Python LOC, `INFERRED`)

| Subsystem | Files | ~LOC | Role |
|---|---|---|---|
| `hermes_cli/` | 181 | 140,952 | CLI commands, dashboard server, auth, kanban, config |
| `plugins/` | 167 | 94,227 | platforms (20), memory (8), backend categories, features |
| `tools/` | 104 | 81,206 | the 64 registered tools |
| `agent/` | 122 | 78,145 | the agent core: loop, transports, curator, memory, context |
| `gateway/` | 62 | 68,033 | messaging gateway runtime + built-in connectors |
| `tui_gateway/` | 8 | 12,306 | Ink-TUI ↔ core JSON-RPC broker |
| `skills/` | 34 | 10,091 | bundled skill library |
| `cron/` | 9 | 5,660 | scheduled routines |
| `acp_adapter/` | 11 | 5,188 | ACP IDE server |
| root monoliths | — | — | `cli.py` (15,089), `run_agent.py`, `hermes_state.py`, `model_tools.py`, `toolsets.py`, `trajectory_compressor.py`, `batch_runner.py` |

> Next: `02-core-tools.md` (the narrow waist), `03-feature-scores.md`, then keep/cut/defer and the architecture map.
