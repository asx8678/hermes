# 05 — Architecture Map (Surviving Features → Target Layers)

> Each KEEP (and likely-keep DEFER) is assigned an **owning layer** consistent with the
> locked target architecture, with a one-line rationale and **migration risk**.
> NIF-vs-sidecar is applied per the safety rule: **NIFs are short pure compute on dirty
> schedulers; anything heavy or crash-prone is a Rust port/sidecar, never a NIF.**

## Layer legend

- **Elixir-core** — Phoenix/OTP brain (GenServers, Ecto, Oban, PubSub). Runs headless.
- **Rust-host** — outer binary: CLI entry, ratatui TUI, BEAM supervision, first-run extraction.
- **Rustler-NIF** — short, pure, CPU-bound compute on dirty schedulers.
- **Rust-port-sidecar** — heavy/crash-prone work in a separate OS process (port).
- **LiveView** — Phoenix web surface (peer to the TUI on the same PubSub).

---

## A. Core loop & runtime → **Elixir-core**

| Feature | Layer | Rationale | Risk |
|---|---|---|---|
| Agentic turn loop | Elixir-core | Session = `GenServer` under `DynamicSupervisor`; the loop is its `handle_*` | **High** — porting `conversation_loop.py` (~4K LOC) faithfully |
| Iteration budget | Elixir-core | Plain state in the session GenServer | Low |
| Tool dispatch (`invoke_tool`) | Elixir-core | Dispatch map → tool modules; concurrent tools = `Task.async_stream` | Med |
| Provider transport abstraction | Elixir-core | One behaviour per `api_mode`; HTTP via Finch/Req | Med — streaming + provider quirks |
| Sub-agent delegation | Elixir-core | Child session = another supervised `GenServer`; **maps natively to OTP** | Med |
| Context compression / engine | Elixir-core | Pure-ish transform; calls LLM | Med |
| Prompt caching | Elixir-core | Header/marker injection | Low |
| Error classifier / retry-fallback | Elixir-core | `with`/supervisor restarts; fallback chain in config | Low |
| Credential pool / sources | Elixir-core (Ecto) | Encrypted at rest; pooled checkout | Med — OAuth flows |
| Streaming (deltas) | Elixir-core → PubSub | Deltas broadcast on PubSub; TUI + LiveView subscribe | Med |
| **Tokenization / token-counting** | **Rustler-NIF** | Short, pure, hot (called per turn) — ideal dirty-scheduler NIF | Low |
| **Trigram/text normalization for FTS** | **Rustler-NIF** | Tiny pure compute if profiling shows need | Low |

---

## B. Tools (the waist) → mixed, by crash-risk

| Tool family | Layer | Rationale | Risk |
|---|---|---|---|
| Filesystem (read/write/patch/search) | Elixir-core | Native `File`/`Path`; patch = pure string compute (NIF only if hot) | Low |
| `todo`, `memory`, `session_search`, `clarify`, `skills_*` | Elixir-core (Ecto/FTS) | Pure data ops over the store | Low |
| **`terminal` / `process`** | **Rust-port-sidecar** | Long-lived OS processes, PTY, kill/monitor → **must not block a scheduler or crash the VM** | **High** |
| **`execute_code` sandbox** | **Rust-port-sidecar** (or Modal/Docker) | Arbitrary user code = crash-prone & long → isolated process, never a NIF | **High** |
| **Browser automation** (DEFER) | **Rust/Node-port-sidecar** | Playwright/CDP is heavy + external; port boundary | High |
| Vision / image / video / TTS (DEFER) | Elixir-core → provider HTTP | Provider-backed I/O; thin clients | Low |
| `cronjob` | Elixir-core (Oban) | Scheduling is Oban's job | Low |
| Kanban / Home Assistant / computer_use / x_search (DEFER) | Elixir-core or sidecar | Per-tool; HA/x_search = HTTP; computer_use = sidecar | Med |

> **NIF discipline restated:** `terminal`, `execute_code`, and `browser` are the three that engineers might be tempted to NIF for speed — **do not**. They are long-running and can segfault/hang; a NIF panic kills the BEAM and a long NIF blocks a scheduler. They are **ports/sidecars**. Only tokenization/embeddings/trigram-style pure math are NIF-eligible.

---

## C. Learning loop (differentiator) → **Elixir-core + Oban**

| Feature | Layer | Rationale | Risk |
|---|---|---|---|
| Self-authored skills (create) | Elixir-core | Skills = files + Ecto rows; `skill_manage` write-path | Med |
| Skill usage telemetry | Elixir-core (`:telemetry` + Ecto) | First-class `:telemetry` events → durable counters | Low |
| **Curator** | **Oban job** | Durable, retryable, observable — replaces the inactivity-timer trigger | Med |
| Background review (auto extraction) | Oban job (or post-turn Task) | Async skill extraction after a turn | Med |
| Skill provenance / eligibility | Elixir-core (Ecto) | Provenance columns | Low |
| Bundled skill library | Elixir-core (seed) | Seed data on first run | Low |
| **Embeddings** (only if loop needs semantic recall) | **Rustler-NIF or sidecar** | Embedding = pure CPU → dirty-scheduler NIF; model load = sidecar | Med |

The curator moving from an **inactivity timer** (`agent/curator.py:219-269`) to an **Oban job** is a strict upgrade (durability + observability) and is explicitly endorsed by the target architecture.

---

## D. Memory / state / search → **Elixir-core (Ecto)** + the storage decision

| Feature | Layer | Rationale | Risk |
|---|---|---|---|
| Session/message store | Elixir-core (Ecto) | The state spine | Med — schema port |
| FTS5 recall (CJK trigram) | Elixir-core | See decision below | Med |
| Built-in memory (profile/notes) | Elixir-core (Ecto) | Rows + system-prompt block | Low |
| Memory provider abstraction | Elixir-core (behaviour) | `MemoryProvider` → Elixir behaviour; one active | Low |
| Conversation compression / locks | Elixir-core | Advisory locks → `GenServer` serialization or Postgres advisory locks | Low |
| External SaaS backends (DEFER) | Elixir-core → HTTP | Thin clients behind the behaviour | Low |

### Memory/search decision — **KEEP SQLite FTS5** for core recall (Phase 1)

**Recommendation: SQLite FTS5, not Postgres+pgvector — for the core conversation recall.**

Evidence (`07`-grade): core recall is **100% keyword/FTS5 with zero embeddings** (`hermes_state.py`, `tools/session_search_tool.py` — no `embedding/vector/cosine/faiss` hits). The CJK-aware **trigram** tokenizer (`hermes_state.py:641-664`) is the only non-trivial requirement, and SQLite FTS5 provides it natively. The learning loop does **not** lean on semantic recall — embeddings live only in optional plugin backends.

- **Phase 1:** SQLite FTS5, embedded, one file per session store — lighter to self-host, fine for keyword recall, works offline, matches today's behavior exactly.
- **Re-evaluate Postgres + pgvector** *only if* a kept memory backend makes embedding/semantic recall part of the **core** loop (today it is plugin-only). If/when the server-mode gateway needs one shared multi-tenant store, Postgres becomes attractive for operational reasons independent of vectors. → tracked in `DECISIONS.md#liveview`/`#storage`.
- **Trade-off noted:** Elixir's SQLite story (`exqlite`/`ecto_sqlite3`) is solid but the single-writer model must be respected — the per-session `GenServer` already serializes writes, so this aligns.

---

## E. Gateway + connectors → **Elixir-core (supervised tree)**

| Feature | Layer | Rationale | Risk |
|---|---|---|---|
| Gateway runtime | Elixir-core | Supervised process tree, one branch per connector | **High** — large port |
| Per-session async isolation | Elixir-core | `GenServer`/session; **the async-task model maps directly to OTP** | Med |
| Platform registry / registration | Elixir-core | Connector behaviour + registry | Low |
| Reconnect/restart watchers | Elixir-core | **Supervisor restart strategies replace the hand-rolled watchers** | Low — net simplification |
| Streaming transports (edit/draft/off) | Elixir-core | Per-connector send strategy | Med |
| Authz / allowlist / approval | Elixir-core | Plug-style guards | Low |

### Kept connector set (Phase 1) — **7 Tier-1**

**telegram, discord, slack, whatsapp (cloud), signal, email, feishu** — the mature, highest-value connectors (`03`/`04`). Each becomes one supervised branch implementing the connector behaviour.

- **DEFER Tier-2** (matrix, google_chat, weixin/wecom, yuanbao, teams) — add once the behaviour is proven.
- **DEFER long-tail (15)** to a community/plugin tier; port on demand.
- Net: Phase-1 gateway ships **7 connectors**, not 31 — the supervised tree + behaviour is the deliverable, connectors are incremental.

---

## F. Surfaces → Rust-host (TUI) + LiveView (web)

| Surface | Layer | Rationale | Risk |
|---|---|---|---|
| CLI entry / binary | **Rust-host** | Owns argv, spawns/supervises BEAM, first-run extraction | Med |
| TUI | **Rust-host (ratatui)** | Owns terminal fd + render loop; **a Channels client, peer to LiveView** | High — reimplement Ink UX in ratatui |
| BEAM supervision | **Rust-host** | spawn → health-check → graceful `:init.stop` | Med |
| Web dashboard (DEFER) | **LiveView** | Peer to TUI on the same PubSub | Med |
| Boundary protocol | Phoenix **Channels over localhost WS** | Replaces stdio/JSON-RPC (`tui_gateway`); **no bespoke stdio protocol** | Med |
| ACP adapter (DEFER) | Elixir-core (Channels client) or thin Rust | Re-add as another Channels client | Med |

The existing `tui_gateway` JSON-RPC handler **semantics** (session.create/resume, send_prompt, approval_respond, slash_exec — `tui_gateway/server.py:898`) are the **functional spec** for the Channels topics. Port the *handlers*, drop the *transport*.

---

## G. Extensibility, cron, MCP

| Feature | Layer | Rationale | Risk |
|---|---|---|---|
| Plugin system | Elixir-core | Behaviours + a registry; OTP apps as plugins | Med |
| Backend-category providers | Elixir-core | Behaviour per category (image/video/browser/tts/web/auth) | Low |
| Cron routines | **Oban** | Durable scheduling; `cron/scheduler.py` tick → Oban cron | Low |
| MCP server (DEFER) | Elixir-core | Expose Hermes over MCP; stdio/HTTP endpoint | Med |
| MCP client (DEFER) | Elixir-core or sidecar | Consume external MCP servers (often stdio subprocesses → port) | Med |

---

## Packaging (both delivery modes)

- **Desktop:** `MIX_ENV=prod mix release` (bundled ERTS) → zstd → embed in the Rust crate (`include_bytes!`/staging build script) → Rust extracts to a versioned cache dir, spawns BEAM, polls until the port binds, opens the TUI over localhost WS; graceful shutdown via `:init.stop`. One binary **per (OS, arch)** — ERTS + NIFs are native → CI matrix; fat binary ~30–80 MB compressed. **Burrito is not used** (it is BEAM-as-host; here Rust is the host).
- **Server (Hetzner VPS):** plain headless BEAM release under **systemd / container** — no Rust host. Same Elixir core, two delivery modes.

---

## NIF-vs-sidecar summary (the safety-critical calls)

| Candidate | Verdict | Why |
|---|---|---|
| Tokenization, token counting | **NIF** (dirty CPU) | short, pure, hot |
| Embeddings (if core needs them) | **NIF** for the math; **sidecar** for model load | pure vector math is NIF-safe; loading a model isn't |
| Trigram/text normalization | **NIF** (if hot) | tiny pure compute |
| `terminal` / `process` | **Sidecar** | long-lived OS procs, can hang/crash |
| `execute_code` | **Sidecar** (or Modal/Docker) | arbitrary code = crash-prone |
| Browser (Playwright/CDP) | **Sidecar** | heavy, external, crash-prone |
| MCP-client stdio servers | **Sidecar** | external subprocess lifecycles |

Everything else is plain Elixir-core. **Fault isolation is preserved: no long or crash-prone work runs as a NIF.**
