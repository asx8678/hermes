# 07 — Rewrite Execution Spec (downstream prompt)

> **Self-contained.** A coding agent can run this without the master prompt or the other
> audit files. It encodes the locked architecture, the KEEP set + layer assignments, the
> CUT/DEFER scope, the connector + storage decisions, the phased plan, and the guardrails.
> Source tree to port from: **`hermes-agent/`** (Python, ~1.16M LOC). Target repo: **this
> folder** (`hermes/`). Work items are tracked in **beads** (`bd ready`, `bd show <id>`).

---

## ROLE

You are implementing the **Rust + Elixir reimplementation of Hermes** — a persistent
personal AI agent with a single core across multiple surfaces (CLI, TUI, messaging
gateway, web). You port behavior faithfully from the Python source, citing `file:line`,
and you **re-verify the source before porting each subsystem**. You preserve Hermes's
differentiator — the **closed learning loop** — at all costs.

## LOCKED TARGET ARCHITECTURE (do not re-derive; flag disagreement in `DECISIONS.md`)

Two delivery modes share **one Elixir core**.

- **Elixir / Phoenix = the orchestration brain (must run headless).**
  - A conversation **session** is a `GenServer` under a `DynamicSupervisor` (per-session fault isolation).
  - The **messaging gateway** is a supervised process tree, one branch per kept connector.
  - **Curator + telemetry** run as **Oban** jobs (durable, retryable, observable). `:telemetry` is first-class.
  - **Memory / skills** persist via **Ecto**.
  - Web surface via **Phoenix + LiveView**.
- **Rust = the outer host (owns the terminal).**
  - The shipped **binary** and **CLI** entry point.
  - The **TUI** via **ratatui**, owning the terminal fd + render loop natively.
  - **Supervises the BEAM child**: spawn, health-check, graceful shutdown.
  - **First-run extraction** of the embedded BEAM release.
- **Boundary protocol = Phoenix Channels over localhost WebSocket.** The Rust TUI is just
  another Channels client, a **peer** to the LiveView browser on the same PubSub.
  **Do not invent a bespoke stdio protocol.** (The Python `tui_gateway` JSON-RPC broker is
  reference-only: port its *handler semantics*, drop its transport.)
- **Rustler NIFs = CPU hot paths only** (embeddings, tokenization, tight loops); use
  **dirty schedulers**. Anything **heavy or crash-prone goes in a separate Rust process
  (port/sidecar), never a NIF** — a NIF panic/segfault kills the VM and a long NIF blocks a
  scheduler. Preserve OTP fault isolation.
- **Memory/search = SQLite FTS5** (decision below).
- **Single-binary packaging (desktop):** `MIX_ENV=prod mix release` (bundled ERTS) →
  zstd → embed in the Rust crate (`include_bytes!`/staging build script) → on startup Rust
  extracts to a versioned cache dir, spawns BEAM, polls until its port binds, opens the TUI
  and connects over localhost WS; graceful shutdown via `:init.stop`.
- **Server mode (Hetzner VPS gateway):** plain headless BEAM release under **systemd /
  container** — no Rust host. Same core, two delivery modes.
- **Caveats:** one binary **per (OS, arch)** (ERTS + NIFs are native → CI matrix per
  target); fat binary ~30–80 MB compressed; **Burrito is NOT used** (it is BEAM-as-host;
  here Rust is the host).
- **CLI and TUI are first-class required surfaces.** Do not deprioritize them.

## SOURCE-OF-TRUTH MAP (port from these; re-verify before each subsystem)

- Turn loop: `agent/conversation_loop.py:589`; iteration budget `agent/iteration_budget.py:17`.
- Tool dispatch: `agent/agent_runtime_helpers.py:1733` (`invoke_tool`); registry `tools/registry.py:57,234`.
- Providers: `agent/transports/{anthropic,codex,bedrock,chat_completions}.py` (4 registered; antigravity/gemini route via `chat_completions` + OAuth adapters — **live, port incrementally**).
- State + FTS: `hermes_state.py:519-592` (schema), `:612-664` (FTS5 unicode61 + **trigram CJK**), `:3466-3715` (query).
- Memory: `agent/memory_provider.py:43-316`, `agent/memory_manager.py`.
- Learning loop: skills `tools/skill_manager_tool.py:301`; telemetry `tools/skill_usage.py:460`; curator `agent/curator.py:276-331,1898`; background review `agent/background_review.py:45`; recall `tools/session_search_tool.py`.
- Gateway: `gateway/run.py` (GatewayRunner), `gateway/platforms/base.py:2078` (per-session tasks), `gateway/platform_registry.py:172`.
- TUI protocol reference: `tui_gateway/server.py:898`; events `ui-tui/src/gatewayTypes.ts:610-649`.
- The default tool surface: `_HERMES_CORE_TOOLS` `toolsets.py:31-74` (48 tools).

---

## KEEP feature set → layer assignments (Phase-1 scope)

**Elixir-core (OTP brain):**
- Agentic turn loop, iteration budget, tool dispatch, provider transport behaviour (start with Anthropic), sub-agent delegation (= child GenServer), context/conversation compression, prompt caching, error-classify/retry-fallback, credential pool, streaming via PubSub.
- Tools — pure/data: filesystem (read/write/patch/search), `todo`, `memory`, `session_search`, `clarify`, `skills_list/view/manage`.
- State: Ecto `sessions`/`messages`/`state_meta`; **SQLite FTS5** recall (unicode61 + trigram).
- Learning loop: self-authored skills, telemetry (`:telemetry`), **curator (Oban)**, background review (Oban/Task), provenance, bundled skill seed.
- Gateway: supervised tree, per-session isolation, registry, reconnect via supervisors, streaming transports, authz/approval.
- Cron routines → **Oban**; plugin system → behaviours + registry.

**Rust-host:** CLI entry, ratatui TUI (Channels client), BEAM supervision, first-run extraction.

**Rust-port-sidecar (never NIF):** `terminal`/`process`, `execute_code` sandbox. (DEFER: browser, MCP-client stdio servers.)

**Rustler-NIF (dirty scheduler, only if profiled):** tokenization/token-counting, trigram/text normalization, embeddings math.

**LiveView (DEFER → C):** web dashboard, peer to the TUI on PubSub.

---

## KEPT CONNECTOR SET (Phase 1)

**telegram, discord, slack, whatsapp (cloud), signal, email, feishu** — 7 Tier-1 connectors,
one supervised branch each, implementing the connector behaviour. Ship **one fully**, then
template the rest. DEFER Tier-2 (matrix, google_chat, weixin/wecom, yuanbao, teams) and the
15-connector long tail to a later community/plugin tier.

## MEMORY / SEARCH DECISION — **SQLite FTS5** (keep)

Core conversation recall is **100% keyword/FTS5, zero embeddings** (verified: no
`embedding/vector/cosine/faiss` in `hermes_state.py` or `session_search_tool.py`). Use
**SQLite FTS5** (unicode61 + **trigram** for CJK) via `ecto_sqlite3`/`exqlite`; the
per-session GenServer serializes writes (respect single-writer). **Do NOT** adopt
Postgres+pgvector in Phase 1. Re-evaluate only if a memory backend makes embeddings part of
the **core** loop, or if server-mode needs one shared multi-tenant store (operational, not
vector-driven) — record any such pivot in `DECISIONS.md`.

## OUT OF SCOPE — CUT (do not port)

Research/eval tooling: `batch_runner.py`, `mini_swe_runner.py`, `trajectory_compressor.py`,
`toolset_distributions.py`, `datagen-config-examples/`. Surfaces: Electron desktop
(`apps/desktop`), bootstrap installer (`apps/bootstrap-installer`), the `tui_gateway`
*transport* (port semantics only). Commands/features: `claw`, `secrets` (Bitwarden),
`migrate`, LSP (`agent/lsp`), `mixture_of_agents`, per-platform sticker/media exotica.
(Each cleared a dependency safety-check — none is referenced by the core loop, gateway, or
CLI core path.)

## DEFER (post-Phase-1, not now)

Tier-2 + long-tail connectors; LiveView depth; ACP adapter (re-add as a Channels client);
MCP server + client; browser automation (sidecar); media tools (image/video/TTS/vision);
kanban; the 8 external memory backends (port the abstraction now, backends later); Home
Assistant / computer_use / x_search / Discord-Yuanbao-Feishu tool actions; observability,
insights, i18n, backup/import/dump, profiles, doctor, update; additional provider adapters
(gemini/antigravity/bedrock/codex specifics — **live, port incrementally, do not cut**).

---

## PHASED PLAN (Done = is the gate)

- **A — Elixir core skeleton (headless).** Session GenServer + DynamicSupervisor, one
  provider, Ecto memory + SQLite FTS5, dispatch for the irreducible-6 tools, Phoenix
  endpoint + a Channel. **Done =** a full multi-tool turn runs headless, persists, is
  reachable over a localhost Channel, and FTS recall returns a prior message.
- **B — Rust host + single binary.** Embed BEAM release; extract → spawn → wait-for-port →
  connect Channels over WS; ratatui TUI; CLI entry. **Done =** one binary boots the BEAM
  child and the TUI drives a full turn; clean shutdown, no orphan BEAM.
- **C — Gateway + learning loop.** Supervised Tier-1 connectors; curator + telemetry as
  Oban jobs; background review; LiveView dashboard (basic). **Done =** a kept-platform
  message completes a turn and replies, an agent-created skill is written, and the curator
  runs as an Oban job recording telemetry.
- **D — Hot paths + sandboxing + memory scale.** Sidecars for terminal/execute_code; NIFs
  for tokenization/embeddings **only where profiling shows need**; pgvector only if the loop
  needs core semantic recall. **Done =** sandboxed execution cannot crash/block the BEAM;
  the hot path meets its latency target without blocking a scheduler.
- **E — Server delivery + packaging matrix.** Headless release under systemd/container for
  the VPS; per-(OS,arch) desktop binary matrix. **Done =** both delivery modes build and
  smoke-test from CI.

**Critical path:** A → (B ∥ C) → D → E. A blocks everything.

---

## IMPLEMENTATION GUARDRAILS

1. **Preserve the closed learning loop** — self-authored skills + telemetry + curator +
   background review + FTS recall. It is the product. Never cut or stub it.
2. **CLI + TUI are first-class.** Build and keep them working every milestone.
3. **NIF discipline:** NIFs are short, pure, CPU-bound, on dirty schedulers. `terminal`,
   `execute_code`, browser, and external stdio subprocesses are **sidecars/ports**. A NIF
   that can hang or crash is a bug.
4. **Never break per-session fault isolation** — one supervised GenServer per session; a
   crash in one session must not take down others or the VM.
5. **Boundary = Phoenix Channels** over localhost WS. No bespoke stdio protocol. TUI and
   LiveView are peers on the same PubSub.
6. **Storage = SQLite FTS5** (unicode61 + trigram) until evidence forces Postgres/pgvector.
7. **Cite source** (`file:line`) in commits/PRs when porting behavior; add golden-transcript
   tests captured from the Python agent to prove parity.
8. **Discovery-first:** before porting any subsystem, re-read the relevant `hermes-agent/`
   source (it changes) and confirm the `file:line` anchors above still hold.
9. **Flag ambiguities to `DECISIONS.md`** — do not silently guess or silently deviate from
   the locked architecture.

## DISCOVERY-FIRST CHECKLIST (run before each subsystem)

```
# Re-verify anchors before porting (example for the turn loop):
grep -n "max_iterations\|iteration_budget\|while" hermes-agent/agent/conversation_loop.py
grep -n "CREATE TABLE\|fts5\|trigram"        hermes-agent/hermes_state.py
grep -n "register\|api_mode"                  hermes-agent/agent/transports/__init__.py
bd ready    # what's unblocked to work on now
```

If an anchor moved, update it and note the drift; if behavior is ambiguous, open a
`DECISIONS.md` entry before coding.
