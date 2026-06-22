# 03 — Feature Audit & Scoring

> **95 scored features** (prior estimate ~89 — the real count is reported here).
> Each is scored **1–5** per dimension; the weighted score drives Phase 3 keep/cut/defer.
> Dimension scores are expert judgment **grounded in the Phase 0/1 evidence** (`file:line`
> in the Evidence column) — they are `INFERRED` assessments, not measured telemetry.

## Method

`W = 0.30·Centrality + 0.20·UserValue + 0.20·Differentiation + 0.15·ReimplEase + 0.10·LowCoupling + 0.05·StrategicFit`

- **ReimplEase** = inverted reimplementation cost (5 = trivial to rebuild, 1 = very costly).
- **LowCoupling** = inverted coupling (5 = isolated, 1 = deeply entangled).
- Columns: **C** V **D** R(ease) K(low-coupling) **S** → **W**.

**Bloat signal codes:** `DEAD` unreferenced · `SURFACE` tied to a surface being dropped · `DUP` redundant · `SPEC` speculative/unused · `MAINT` disproportionate maintenance vs usage · `TAIL` low-usage connector · `RESEARCH` eval/training tooling.

---

## Master table (sorted by weighted score, high → low)

| Feature | Area | Evidence (`file:line`) | C | V | D | R | K | S | **W** | Bloat |
|---|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|---|
| SQLite session/message store | Memory | `hermes_state.py:519-592` | 5 | 5 | 3 | 4 | 3 | 5 | **4.25** | — |
| Self-authored skills (creation) | Learn | `tools/skill_manager_tool.py:301` | 4 | 5 | 5 | 3 | 3 | 5 | **4.20** | — |
| Filesystem tools (read/write/patch/search) | Tools | `tools/file_tools.py:1735` | 5 | 5 | 2 | 4 | 4 | 5 | **4.15** | — |
| Iteration budget / loop control | Core | `agent/iteration_budget.py:17-63` | 5 | 3 | 3 | 5 | 4 | 5 | **4.10** | — |
| FTS5 recall (CJK trigram) | Memory | `hermes_state.py:612-664` | 4 | 5 | 4 | 3 | 4 | 5 | **4.10** | — |
| Conversation/agentic turn loop | Core | `agent/conversation_loop.py:589` | 5 | 5 | 4 | 2 | 2 | 5 | **4.05** | — |
| Built-in memory (profile/notes) | Memory | `tools/memory_tool.py:1040` | 4 | 4 | 3 | 4 | 4 | 5 | **3.85** | — |
| Tool dispatch (`invoke_tool`) | Core | `agent/agent_runtime_helpers.py:1733` | 5 | 4 | 3 | 3 | 2 | 5 | **3.80** | — |
| `todo` planning | Tools | `tools/todo_tool.py:300` | 4 | 4 | 2 | 5 | 4 | 5 | **3.80** | — |
| Terminal tool | Tools | `tools/terminal_tool.py:2738` | 5 | 5 | 2 | 2 | 3 | 5 | **3.75** | — |
| Gateway runtime (sessions/adapters) | Gateway | `gateway/run.py` GatewayRunner | 4 | 5 | 4 | 2 | 2 | 5 | **3.75** | — |
| Chat REPL (`cli.py`) | CLI | `cli.py:14588` | 5 | 5 | 3 | 2 | 1 | 5 | **3.75** | — |
| Skill usage telemetry (`.usage.json`) | Learn | `tools/skill_usage.py:460-530` | 3 | 3 | 5 | 4 | 3 | 5 | **3.65** | — |
| Provider transport abstraction | Core | `agent/transports/__init__.py:21-66` | 5 | 4 | 2 | 3 | 3 | 4 | **3.65** | — |
| Web search/extract | Tools | `tools/web_tools.py:1356` | 4 | 5 | 1 | 4 | 4 | 5 | **3.65** | — |
| Per-session async isolation + agent LRU cache | Gateway | `gateway/run.py:2604`, `platforms/base.py:2078` | 4 | 4 | 3 | 3 | 3 | 5 | **3.60** | — |
| Sub-agent delegation runtime | Core | `tools/delegate_tool.py:3160` | 4 | 4 | 4 | 2 | 2 | 5 | **3.55** | — |
| Curator (transitions + LLM consolidation) | Learn | `agent/curator.py:276-331` | 3 | 4 | 5 | 2 | 3 | 5 | **3.55** | — |
| `clarify` (human-in-loop) | Tools | `tools/clarify_tool.py:181` | 3 | 4 | 2 | 5 | 4 | 5 | **3.50** | — |
| Cron scheduled routines | Cron | `cron/scheduler.py`, `cron/jobs.py` | 3 | 4 | 4 | 3 | 3 | 5 | **3.50** | — |
| Background review (auto skill extraction) | Learn | `agent/background_review.py:45-148` | 3 | 4 | 5 | 2 | 2 | 5 | **3.45** | — |
| Platform registry / plugin registration | Gateway | `gateway/platform_registry.py:172` | 3 | 4 | 3 | 4 | 3 | 5 | **3.45** | — |
| Connectors Tier-1 (tg/discord/slack/wa/signal/email/feishu) | Gateway | `plugins/platforms/*`, `gateway/platforms/*` | 3 | 5 | 3 | 2 | 4 | 5 | **3.45** | — |
| Context compression / context engine | Core | `agent/context_engine.py:32`, `context_compressor.py` | 4 | 4 | 3 | 2 | 3 | 4 | **3.40** | — |
| `execute_code` sandbox | Tools | `tools/code_execution_tool.py:1837` | 4 | 5 | 3 | 1 | 2 | 5 | **3.40** | — |
| `cronjob` tool | Tools | `tools/cronjob_tools.py:945` | 3 | 4 | 3 | 4 | 3 | 4 | **3.40** | — |
| Conversation compression/summarization | Memory | `agent/conversation_compression.py:281` | 4 | 4 | 3 | 2 | 3 | 4 | **3.40** | — |
| Plugin system (loader + PluginContext) | Ext | `hermes_cli/plugins.py:315-900` | 3 | 4 | 4 | 3 | 2 | 5 | **3.40** | — |
| Error classifier / retry-fallback | Core | `agent/error_classifier.py` | 4 | 4 | 2 | 3 | 3 | 4 | **3.35** | — |
| Authz / user allowlist / approval | Gateway | `gateway/authz_mixin.py`, `slash_access.py` | 4 | 4 | 2 | 3 | 3 | 4 | **3.35** | — |
| Command framework (argparse) | CLI | `hermes_cli/_parser.py:84`, `main.py:11794` | 4 | 4 | 1 | 4 | 3 | 5 | **3.35** | — |
| Streaming (deltas → consumer) | Core | `gateway/stream_consumer.py:79` | 4 | 4 | 2 | 3 | 3 | 4 | **3.35** | — |
| Prompt caching (cache_control) | Core | `agent/conversation_loop.py:817` | 3 | 4 | 2 | 4 | 4 | 4 | **3.30** | — |
| Model fallback chains | Core | `hermes_cli` fallback cmd | 3 | 4 | 2 | 4 | 4 | 4 | **3.30** | — |
| Credential pool / sources | Core | `agent/credential_pool.py`, `credential_sources.py` | 4 | 4 | 2 | 3 | 3 | 3 | **3.30** | — |
| Bundled skill library (34 categories) | Learn | `skills/` | 2 | 4 | 3 | 4 | 5 | 4 | **3.30** | — |
| Memory provider abstraction (pluggable) | Memory | `agent/memory_provider.py:43-316` | 3 | 3 | 4 | 3 | 3 | 4 | **3.25** | — |
| `setup` wizard | CLI | `hermes_cli/subcommands/setup.py` | 3 | 5 | 2 | 3 | 3 | 4 | **3.25** | — |
| `sessions` (list/resume) | CLI | `hermes_cli/main.py:12259` | 3 | 4 | 2 | 4 | 3 | 5 | **3.25** | — |
| tools/skills/plugins/mcp pickers | CLI | `hermes_cli/subcommands/*` | 3 | 4 | 2 | 4 | 3 | 5 | **3.25** | — |
| model/provider picker | CLI | `hermes_cli/model_setup_flows.py` | 3 | 5 | 2 | 3 | 2 | 4 | **3.15** | — |
| Vision analyze | Tools | `tools/vision_tools.py:1220` | 3 | 4 | 1 | 4 | 4 | 4 | **3.10** | — |
| Skill provenance / eligibility | Learn | `tools/skill_provenance.py` | 2 | 3 | 4 | 4 | 3 | 4 | **3.10** | — |
| Streaming transports (edit/draft/off) | Gateway | `gateway/stream_dispatch.py` | 3 | 4 | 3 | 2 | 3 | 4 | **3.10** | — |
| Reconnect/restart watchers | Gateway | `gateway/run.py:5896`, `restart.py` | 3 | 4 | 2 | 3 | 3 | 5 | **3.10** | — |
| `config` management | CLI | `hermes_cli/config.py` | 4 | 4 | 1 | 3 | 2 | 4 | **3.05** | — |
| Message sanitization | Core | `agent/message_sanitization.py` | 4 | 2 | 1 | 4 | 4 | 3 | **2.95** | — |
| `auth` / credentials (OAuth flows) | CLI | `hermes_cli/auth.py` | 4 | 4 | 2 | 1 | 2 | 4 | **2.95** | MAINT |
| Ink TUI | Surface | `ui-tui/src/entry.tsx:51` | 2 | 5 | 2 | 2 | 3 | 5 | **2.85** | SURFACE→ratatui |
| Skills hub (catalog/install) | Learn | `hermes_cli/skills_hub.py` | 2 | 3 | 3 | 3 | 4 | 3 | **2.80** | — |
| `doctor` diagnostics | CLI | `hermes_cli/subcommands/doctor.py` | 2 | 4 | 1 | 4 | 4 | 4 | **2.80** | — |
| Backend-category providers (image/video/browser/tts/web/auth) | Ext | `plugins/{image_gen,video_gen,browser,...}` | 2 | 3 | 3 | 3 | 3 | 4 | **2.75** | — |
| MCP client (consume external tools) | Ext | `tools/mcp_tool.py`, `tools/tool_search.py` | 2 | 4 | 2 | 3 | 3 | 4 | **2.75** | — |
| `profile` isolation | CLI | `hermes_cli/profiles.py` | 2 | 3 | 2 | 4 | 3 | 4 | **2.70** | — |
| Compression locks (concurrency) | Memory | `hermes_state.py` compression_locks | 3 | 2 | 2 | 3 | 3 | 4 | **2.65** | — |
| Browser automation (12 tools) | Tools | `tools/browser_tool.py:3919` | 3 | 4 | 2 | 1 | 2 | 3 | **2.60** | — |
| `update` (self-update) | CLI | `hermes_cli/subcommands/update.py` | 2 | 4 | 1 | 3 | 4 | 3 | **2.60** | — |
| `logs` | CLI | `hermes_cli/subcommands/logs.py` | 2 | 3 | 1 | 4 | 4 | 4 | **2.60** | — |
| ACP IDE adapter | Surface | `acp_adapter/entry.py:212` | 2 | 3 | 2 | 3 | 4 | 3 | **2.60** | DEFER |
| MCP server (`mcp_serve`) | Ext | `mcp_serve.py:204-444` | 2 | 3 | 2 | 3 | 4 | 3 | **2.60** | — |
| Kanban multi-agent tools | Tools | `tools/kanban_tools.py:1465` | 2 | 3 | 3 | 2 | 2 | 4 | **2.50** | — |
| `tui_gateway` broker (JSON-RPC) | Surface | `tui_gateway/server.py:898` | 3 | 3 | 2 | 2 | 2 | 2 | **2.50** | DUP→Channels |
| Insights (session analytics) | Learn | `hermes_cli/subcommands/insights.py` | 1 | 3 | 2 | 4 | 4 | 3 | **2.45** | — |
| Connectors Tier-2 (matrix/gchat/weixin/yuanbao/teams) | Gateway | `plugins/platforms/*` | 2 | 3 | 2 | 2 | 4 | 3 | **2.45** | — |
| Image generation | Tools | `tools/image_generation_tool.py:1550` | 2 | 3 | 1 | 3 | 4 | 3 | **2.40** | — |
| Web dashboard (→ LiveView) | Surface | `web/src/main.tsx`, `hermes_cli/web_server.py` | 1 | 4 | 2 | 2 | 4 | 4 | **2.40** | SURFACE→LiveView |
| dashboard server (`web_server.py`) | CLI | `hermes_cli/web_server.py` (12.9K) | 2 | 4 | 2 | 1 | 2 | 3 | **2.30** | SURFACE→LiveView |
| Observability plugins (langfuse/nemo) | Ext | `plugins/observability/*` | 1 | 3 | 1 | 4 | 4 | 4 | **2.30** | — |
| i18n (18 locales) | Ext | `locales/*.yaml`, `agent/i18n.py` | 2 | 3 | 1 | 3 | 3 | 3 | **2.30** | — |
| External SaaS memory backends (6) | Memory | `plugins/memory/{mem0,hindsight,...}` | 1 | 3 | 2 | 3 | 4 | 2 | **2.25** | — |
| backup/import/dump | CLI | `hermes_cli/subcommands/{backup,import_cmd,dump}.py` | 1 | 3 | 1 | 4 | 4 | 3 | **2.25** | MAINT |
| TTS tool | Tools | `tools/tts_tool.py:2835` | 1 | 3 | 1 | 3 | 4 | 2 | **2.05** | — |
| Home Assistant tools | Tools | `tools/homeassistant_tool.py:479` | 1 | 2 | 1 | 4 | 4 | 2 | **2.00** | TAIL |
| `migrate` (model retirement) | CLI | `hermes_cli/main.py:11881` | 1 | 2 | 1 | 4 | 4 | 2 | **2.00** | MAINT |
| `x_search` | Tools | `tools/x_search_tool.py:516` | 1 | 2 | 1 | 4 | 4 | 2 | **2.00** | — |
| kanban DB + TUI (CLI subsystem, 11K LOC) | CLI | `hermes_cli/kanban_db.py`, `kanban.py` | 1 | 3 | 3 | 1 | 2 | 3 | **2.00** | MAINT |
| datagen-config-examples | Research | `datagen-config-examples/` | 1 | 1 | 1 | 5 | 5 | 1 | **2.00** | RESEARCH |
| mixture_of_agents | Tools | `tools/mixture_of_agents_tool.py:533` | 1 | 2 | 2 | 3 | 3 | 2 | **1.95** | SPEC |
| Holographic memory (local HRR) | Memory | `plugins/memory/holographic/` | 1 | 2 | 3 | 1 | 4 | 2 | **1.95** | — |
| `secrets` (Bitwarden) | CLI | `hermes_cli/main.py:11843` | 1 | 2 | 1 | 3 | 4 | 2 | **1.85** | MAINT |
| Feature plugins (spotify/meet/teams/achievements) | Ext | `plugins/{spotify,google_meet,...}` | 1 | 2 | 1 | 3 | 4 | 2 | **1.85** | — |
| Video generation | Tools | `tools/video_generation_tool.py:552` | 1 | 2 | 1 | 3 | 4 | 2 | **1.85** | — |
| computer_use | Tools | `tools/computer_use_tool.py:19` | 1 | 3 | 2 | 1 | 3 | 2 | **1.85** | — |
| Bootstrap installer | Surface | `apps/bootstrap-installer/` | 1 | 2 | 1 | 3 | 4 | 1 | **1.80** | SURFACE |
| Relay (external connector transport) | Gateway | `gateway/relay/` | 1 | 2 | 2 | 2 | 3 | 2 | **1.80** | — |
| `claw` (legacy OpenClaw migration) | CLI | `hermes_cli/subcommands/claw.py` | 1 | 1 | 1 | 4 | 4 | 1 | **1.75** | DEAD/MAINT |
| Electron desktop | Surface | `apps/desktop/` | 1 | 3 | 1 | 2 | 3 | 1 | **1.75** | SURFACE |
| toolset_distributions (synthetic sampling) | Research | `toolset_distributions.py` | 1 | 1 | 1 | 4 | 4 | 1 | **1.75** | RESEARCH |
| Connectors long-tail (15: dingtalk/line/simplex/mattermost/irc/sms/ntfy/raft/photon/bluebubbles/qqbot/ha/api_server/webhook/msgraph) | Gateway | `plugins/platforms/*`, `gateway/platforms/*` | 1 | 2 | 1 | 2 | 4 | 2 | **1.70** | TAIL |
| Discord/Yuanbao/Feishu tool actions | Tools | `tools/{discord,yuanbao,feishu_*}_tool.py` | 1 | 2 | 1 | 3 | 2 | 2 | **1.65** | TAIL |
| batch_runner (eval/datagen) | Research | `batch_runner.py` | 1 | 1 | 1 | 3 | 4 | 1 | **1.60** | RESEARCH |
| mini_swe_runner (SWE eval) | Research | `mini_swe_runner.py` | 1 | 1 | 1 | 3 | 4 | 1 | **1.60** | RESEARCH |
| LSP integration | Tools | `agent/lsp/` | 1 | 2 | 1 | 2 | 3 | 2 | **1.60** | SPEC |
| Sticker/media per-platform | Gateway | `gateway/sticker_cache.py`, `*_sticker.py` | 1 | 2 | 1 | 2 | 2 | 2 | **1.50** | TAIL |
| trajectory_compressor (SFT/RL data) | Research | `trajectory_compressor.py` | 1 | 1 | 1 | 2 | 4 | 1 | **1.45** | RESEARCH |

---

## Read-out

- **Top quartile (W ≥ 3.40, ~27 features):** the core loop, the tool waist, the learning loop, memory/FTS, the gateway runtime + Tier-1 connectors, the CLI chat REPL + command framework, plugin system, cron. **This is the Phase-1 rewrite scope.**
- **Mid (2.4–3.4):** valuable but stage-2 — secondary connectors, browser, media tools, dashboard/LiveView, ACP, MCP, profiles, backups. Mostly **DEFER**.
- **Bottom (W < 2.0, ~15 features):** research/eval tooling, legacy migrations (`claw`), the Electron desktop, the long-tail connectors, niche tools. Mostly **CUT** (see `04`).
- **Differentiation (D=5) cluster:** self-authored skills, curator, telemetry, background review — all top-quartile. The differentiator is healthy and survives. **Do not cut.**
