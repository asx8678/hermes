# 06 — Phased Rewrite Plan

> Milestones refined against the audit findings. Each states **scope**, **measurable
> acceptance criteria (Done =)**, **dependencies**, and **risk**. These map 1:1 to the
> beads epics filed in this repo (`bd list`).

---

## Milestone A — Elixir core skeleton (headless)

**Scope.** The OTP brain that runs one full turn headless.
- Session = `GenServer` under a `DynamicSupervisor` (per-session fault isolation).
- Port the turn loop (`agent/conversation_loop.py:589`) + iteration budget (`agent/iteration_budget.py`).
- **One** LLM provider behaviour first (Anthropic Messages, mirroring `agent/transports/anthropic.py`).
- Ecto schemas for `sessions`/`messages`/`state_meta` (`hermes_state.py:519-592`); SQLite FTS5 (unicode61 + trigram) recall (`hermes_state.py:612-664`).
- Dispatch for the **irreducible-6 core tools** (`02`): filesystem, terminal*, execute_code*, skills, memory+session_search, delegate_task. (*terminal/execute_code via sidecar — see Milestone D for hardening; A can shell out minimally.)
- Phoenix endpoint + a Channel.

**Done =** the core loop runs a **full multi-tool turn headless** (input → LLM → ≥1 tool call → memory write → final response), persisted to Ecto, **reachable over a localhost Phoenix Channel**, with FTS recall returning a prior message.

**Dependencies.** None (greenfield).
**Risk.** **High** — faithful port of the ~4K-LOC loop + provider streaming. Mitigate: golden-transcript tests captured from the Python agent.

---

## Milestone B — Rust host + single binary

**Scope.** The outer host that owns the terminal and supervises the BEAM.
- Rust CLI entry (`hermes`), `mix release` with bundled ERTS, zstd-compress, embed via `include_bytes!`/staging script.
- First-run extraction to a versioned cache dir → spawn BEAM → poll until the Channel port binds → connect over localhost WS → graceful shutdown (`:init.stop`).
- ratatui TUI shell as a **Channels client** (peer to LiveView), porting the `tui_gateway` handler semantics (session.create/resume, send_prompt, approval_respond, slash_exec — `tui_gateway/server.py:898`).

**Done =** **one binary** boots the BEAM child, the ratatui TUI connects over Channels, and **drives a full turn end-to-end** from the terminal; clean shutdown leaves no orphan BEAM.

**Dependencies.** A.
**Risk.** Med–High — ratatui reimplementation of the Ink UX; per-(OS,arch) packaging matrix.

---

## Milestone C — Gateway + learning loop

**Scope.** The supervised messaging tree and the differentiator.
- Gateway supervision tree, one branch per **Tier-1 connector**: telegram, discord, slack, whatsapp, signal, email, feishu (`05§E`). Connector behaviour + registry.
- Per-session isolation + agent reuse; streaming to platforms; authz/allowlist/approval.
- Learning loop on **Oban**: background review (auto skill extraction), skill telemetry via `:telemetry`, the **curator** as a durable Oban job (replacing the inactivity timer).
- LiveView dashboard (basic: sessions, status) as a Channels/PubSub peer.

**Done =** a message from a **kept platform** completes a full turn and replies; an agent-created skill is written; the curator **runs as an Oban job and records telemetry**; the LiveView dashboard shows the live session.

**Dependencies.** A (core), B (optional for TUI co-debug).
**Risk.** High — gateway is a large subsystem; per-platform quirks. Mitigate: ship 1 connector fully, then template the rest.

---

## Milestone D — Hot paths, sandboxing & memory scale

**Scope.** Make the crash-prone/CPU-heavy paths correct and fast.
- **Sidecars** for `terminal`/`process` and `execute_code` (OS-isolated; never NIF) — the hardened versions of Milestone A's minimal shell-out.
- **Rustler NIFs** for tokenization/token-counting (and embeddings math) **only where profiling shows need**, on dirty schedulers.
- pgvector / semantic recall **only if** a memory backend makes embeddings part of the *core* loop (today plugin-only → likely deferred).

**Done =** sandboxed code/terminal execution runs in a separate process with enforced limits and **cannot crash or block the BEAM**; the chosen hot path (e.g. token counting) meets its latency target **without blocking a scheduler** (measured); FTS recall latency target met at target corpus size.

**Dependencies.** A, C.
**Risk.** Med — sidecar protocol + supervision; NIF safety discipline.

---

## Milestone E — Server delivery + packaging matrix

**Scope.** Ship both delivery modes from CI.
- **Server mode:** plain headless BEAM release under systemd / container for the Hetzner VPS gateway (no Rust host).
- **Desktop mode:** per-(OS, arch) build matrix producing the fat Rust+BEAM binary (~30–80 MB compressed); ERTS + NIFs are native → matrix built on/for each target. (Burrito **not** used.)

**Done =** **both** delivery modes build and release from CI: a tagged commit produces (1) a server container/systemd release and (2) signed desktop binaries for each target (OS,arch); a smoke test boots each and runs one turn.

**Dependencies.** B (desktop), C (server gateway).
**Risk.** Med — CI matrix, native cross-build, signing.

---

## Sequencing & critical path

```
A ──> B ──> E(desktop)
└──> C ──> D
       └──> E(server)
```

- **A is the critical path** — everything depends on the headless core.
- **B and C can parallelize** after A (B = host/TUI, C = gateway/loop).
- **D hardens** A+C; **E packages** B (desktop) and C (server).

## Cross-cutting guardrails (apply to every milestone)

1. Preserve the **closed learning loop** (skills→telemetry→curator→recall).
2. **CLI + TUI are first-class** — never deprioritized.
3. **NIFs only for short pure compute**; terminal/execute_code/browser = sidecar.
4. Never break **per-session fault isolation** (one GenServer per session).
5. **Cite the Python source** (`file:line`) when porting any behavior.
6. **Re-verify the source before porting** each subsystem (discovery-first).
7. Ambiguities → `DECISIONS.md`, not silent guesses.

## What is explicitly NOT in this plan (from `04` CUT)

Research/eval tooling (batch_runner, mini_swe_runner, trajectory_compressor, toolset_distributions, datagen), the Electron desktop + bootstrap installer, the `tui_gateway` transport (semantics ported, transport dropped), `claw`/`secrets`/`migrate`/LSP/mixture_of_agents. Tier-2 + long-tail connectors, LiveView depth, ACP, MCP, browser, media tools, and the 8 memory backends are **DEFER** (post-Phase-1).
