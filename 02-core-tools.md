# 02 — The Core Tools (Narrow Waist)

> Phase 1 asked for the **~6 core tools**. The real number is different, and saying so
> is the point: the narrow waist is **48 always-on tools** (`_HERMES_CORE_TOOLS`,
> `toolsets.py:31-74`) out of **64 registered** — but they collapse into **~10
> capability families**, and an **irreducible ~6 that make Hermes *Hermes***. All three
> framings are below, with evidence.

---

## How tools are defined & dispatched (so "core" is meaningful)

- **Registration:** module-level `registry.register(name, toolset, schema, handler, check_fn, …)` with AST auto-discovery of `tools/*.py` (`tools/registry.py:57-74`, `:234-306`). A `ToolEntry` carries `check_fn` (runtime gating, TTL-cached 30s) and `dynamic_schema_overrides`.
- **Selection:** a session resolves an `enabled_toolsets` list → tool names (`toolsets.py:resolve_toolset`, ~`:630-701`) → schemas filtered by `check_fn()` (`model_tools.py:272-536`). 57 toolsets exist, incl. 19 `hermes-<platform>` profiles that **all share `_HERMES_CORE_TOOLS`**.
- **Dispatch:** `invoke_tool()` (`agent/agent_runtime_helpers.py:1733`) → registry handler (or built-in special-cases: `todo`, `memory`, `skill_manage`, `delegate_task`).

So "core" = **in `_HERMES_CORE_TOOLS` AND ungated** (always present in every default session, every platform).

---

## Framing A — The real always-on set: **48 tools** (`_HERMES_CORE_TOOLS`)

The default toolset shared by the CLI and all 19 messaging platforms. Several are **`check_fn`-gated** (only appear in specific contexts), so the *universal* subset is smaller.

| Family | Tools | Gated? |
|---|---|---|
| Web | `web_search`, `web_extract` | no |
| Terminal/process | `terminal`, `process`, `read_terminal` | `read_terminal` gated on `HERMES_DESKTOP` |
| File I/O | `read_file`, `write_file`, `patch`, `search_files` | no |
| Vision/image | `vision_analyze`, `image_generate` | no |
| **Skills** | `skills_list`, `skill_view`, `skill_manage` | no |
| Browser | `browser_navigate/snapshot/click/type/scroll/back/press/get_images/vision/console/cdp/dialog` (12) | no (deps lazy) |
| TTS | `text_to_speech` | no |
| **Planning/memory** | `todo`, `memory`, `session_search` | no |
| Interaction | `clarify` | no |
| **Code/delegation** | `execute_code`, `delegate_task` | no |
| Scheduling | `cronjob` | no |
| Smart home | `ha_list_entities/get_state/list_services/call_service` (4) | gated on `HASS_TOKEN` |
| Kanban | `kanban_show/list/complete/block/heartbeat/comment/create/link/unblock` (9) | gated on `HERMES_KANBAN_TASK`/profile |
| Computer use | `computer_use` | gated on cua-driver |

The other **16 registered (non-core)** tools — `discord`, `discord_admin`, `x_search`, `mixture_of_agents`, `video_analyze`, `video_generate`, Yuanbao (5), Feishu (5) — are opt-in / platform-specific, **not** in the waist.

---

## Framing B — The **~10 capability families** (the "narrow waist" as designed)

This is the honest mapping of the prior "~6 core tools" hypothesis — Hermes thinks in *capabilities*, each backed by 1–12 concrete tools:

1. **Filesystem** — read/write/patch/search
2. **Shell/Process** — terminal + process registry
3. **Code execution & sub-agents** — `execute_code` (sandbox) + `delegate_task`
4. **Web** — search + extract (+ browser automation as a heavier sibling)
5. **Skills** — list/view/**manage** (create/patch/retire)
6. **Memory** — `memory` (profile/notes) + `session_search` (FTS recall)
7. **Planning** — `todo`
8. **Multimedia** — vision/image/video/TTS
9. **Scheduling** — `cronjob`
10. **Coordination** — kanban (multi-agent), clarify (human-in-loop)

---

## Framing C — The **irreducible 6** that make Hermes *Hermes*

If you stripped Hermes to the smallest set that preserves its identity (general autonomous agent + the closed learning loop), it is these six. **These are the non-negotiable Phase-1 core.**

| # | Tool | `file:line` | Why irreducible (what depends on it) |
|---|---|---|---|
| 1 | **`terminal`** | `tools/terminal_tool.py:2738` | The agent's hands on the OS; nearly every task and most skills shell out. |
| 2 | **File I/O** (`read_file`/`write_file`/`patch`/`search_files`) | `tools/file_tools.py:1735-1737` | Reading/editing files; **skills are files on disk** — the learning loop's substrate. |
| 3 | **`execute_code`** | `tools/code_execution_tool.py:1837` | Sandboxed Python + tool composition; the agent's general compute. |
| 4 | **`skill_manage`** (+`skills_list`/`skill_view`) | `tools/skill_manager_tool.py:1217` | **Self-authored skills** — the differentiator's write path; curator mutates via this. |
| 5 | **`memory`** + **`session_search`** | `tools/memory_tool.py:1040`, `tools/session_search_tool.py:779` | Persistent profile + **FTS recall** across sessions — the loop's read path. |
| 6 | **`delegate_task`** | `tools/delegate_tool.py:3160` | Spawns isolated sub-agents; maps directly to the target's per-session `GenServer` fault isolation. |

> **Reported count vs prior:** the prior estimate of "~6 core tools" is *directionally right at the family/identity level* (Framing C) but *literally wrong at the tool level* — the always-on default is **48** (Framing A). All three numbers are real; the rewrite must port **Framing A as the default surface** while treating **Framing C as the must-not-break core**.

---

## Notes for the rewrite

- **`terminal` + `execute_code` + `delegate_task`** are the highest-risk ports: they own process lifecycles, sandboxing, and concurrency → these are where the Elixir/Rust boundary matters most (see `05-architecture-map.md`). Sandboxed/concurrent execution and OS process control are crash-prone → **Rust port/sidecar or OS-isolated, never a NIF**.
- **`skill_manage`, `memory`, `session_search`** are pure-ish data ops over SQLite/files → **Elixir core (Ecto)**; FTS recall stays SQLite FTS5 (see `04`/`05`).
- The 16 non-core + the gated families (Home Assistant, computer-use, kanban) are **DEFER** — port the registry mechanism, add the long-tail tools later.
- No duplicate tool names exist (registry enforces uniqueness). `tools/*.py` also contains ~10 **internal helper modules** (ansi_strip, path_security, fuzzy_match, …) that are not tools.
