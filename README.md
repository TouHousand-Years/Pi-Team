# pi-subagent

> Turn the [Pi CLI](https://pi.dev) (`@earendil-works/pi-coding-agent`) into a **programmable coding sub-agent** that any MCP host (ZCode, Claude Code, Cursor, …) can delegate tasks to and track runs.

`pi-subagent` is a thin MCP server that wraps `pi -p --mode json` into two structured tools: `pi_delegate` to dispatch a task and `pi_status` to harvest its result. Process-isolated, fully session-based, sync/async dual-mode.

## Why

Pi is a minimal terminal coding agent. Rather than teaching Pi *methodology*, this project treats Pi as a **delegatable worker**: a host agent (ZCode / Claude Code) decides *when* to delegate, fires off a self-contained task, and harvests the result. One Pi process = one isolated sub-agent run.

- **Process isolation** — each delegation spawns one `pi -p` child process. A Pi crash only affects that run.
- **Fully session-based** — every task binds to a named session (e.g. `feat-auth`); subsequent calls auto-continue.
- **Sync / async** — `pi_delegate` defaults to `async` at the tool level; the skill layer drives `mode:"sync"` first and keeps async plus bounded long-poll collection as an explicit fallback.
- **One Run Window per Run** — an independent read-only window replays and tails each Run's Transcript (Windows).
- **Universal MCP** — any standard MCP client can load it.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  MCP Host (ZCode / Claude Code / Pi / Cursor …)              │
└───────────────────────────┬─────────────────────────────────┘
                            │ MCP (JSON-RPC over stdio)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  pi-subagent-server  (Node/TS)                                │
│  ┌────────────┐  ┌──────────────┐  ┌────────────────────┐   │
│  │ Tool layer │  │ Session      │  │ Pi runner          │   │
│  │ (2 tools)  │─▶│ registry     │─▶│ (spawn pi -p)      │   │
│  │            │  │ + persist    │  │ parse agent_end    │   │
│  └─────┬──────┘  │ + _snapshot  │  │ + tool_execution   │   │
│        │         └──────────────┘  └─────────┬──────────┘   │
│        │                           ┌────────▼─────────┐     │
│        └───────────────────────────│ Run registry     │     │
│                                    │ + process-table  │     │
│                                   └──────────────────┘     │
└─────────────────────────────────────────────────────────────┘
                            │ child_process.spawn({ cwd })
                            ▼
                   ┌─────────────────────┐
                   │  pi CLI (0.77+)     │
                   └─────────────────────┘
```

Three layers with clear boundaries: **Tool layer** (MCP schema + tool dispatch) / **Session registry** (state + persistence + redaction) / **Runner** (spawn pi, parse NDJSON, process table).

## Tools

| Tool | Purpose |
|------|---------|
| `pi_delegate` | Dispatch a task (tool default `async`; new sessions wait for handshake) |
| `pi_status` | Harvest a run's result (long-poll); `openWindow` reopens that Run's window |

### Skill layer

`skills/pi-subagent/` is the strategy layer a host loads on top of those two tools. It states one delegation contract:

- **Sync first** — a bounded objective is one `mode:"sync"` call with `runTimeoutMs` ≤ 240000, so the Run's terminal state returns inside the host's 300-second MCP call limit.
- **Async is the explicit fallback** — used only for fan-out/background work or a verified over-cap objective, and it must state its reason.
- **Monitor Wait collection** — an async Run is collected with non-overlapping `pi_status` waits: up to three at `waitTimeoutMs: 60000`, then waits at `waitTimeoutMs: 180000`.
- **Never auto-redispatch** — a host-reported sync timeout does not stop the Run; the host collects the same `runId` and only re-dispatches by explicit decision.

`test/skill-contract.test.ts` enforces this contract and checks that every installed specialized `pi-*` skill still names only these two tools.

### Session model

- Each session has a human-readable name + Pi's UUID + `cwd` + `goal`.
- First `pi_delegate` creates the session (`goal` required); later calls auto-continue.
- The registry persists to `~/.pi-subagent/registry.json` (atomic write; on restart, interrupted `running` records are corrected to `error`).
- Concurrency cap: **4** running runs; a single session is never run concurrently.

## Install

```bash
git clone <this-repo> && cd pi-subagent
npm install
npm run build      # required: emits dist/, the MCP entry point
```

Prerequisite: the `pi` CLI is installed (`npm i -g @earendil-works/pi-coding-agent`) and on `PATH`.

> **npm 10+ blocks install scripts by default.** If `npm install` prints
> `1 package has install scripts not yet covered by allowScripts` for `esbuild`, run
> `npm install-scripts approve esbuild` — `tsx` (used by the test suite) needs esbuild's
> native binary and will fail to start without it.

## Configure an MCP host

Add to your MCP client config:

```json
{
  "mcpServers": {
    "pi-subagent": {
      "command": "node",
      "args": ["/abs/path/to/pi-subagent/dist/server.js"]
    }
  }
}
```

> **Use the compiled `dist/` entry with plain `node`, and always an absolute path.**
> Do *not* configure `npx tsx src/server.ts`: MCP hosts spawn the server with the *host's*
> working directory (the project being edited), not this repo. From there `npx` cannot resolve
> the locally installed `tsx`, so it falls through to a registry download — on a slow or
> firewalled network that blows past the host's 30s handshake window and the server shows up as
> `CONNECT_TIMEOUT`. Running `dist/server.js` under `node` needs no resolution step and starts in
> ~0.2s from any cwd.
>
> Re-run `npm run build` after pulling changes, since `dist/` is gitignored.

Optional env vars:
- `PI_SUBAGENT_REGISTRY` — registry path (default `~/.pi-subagent/registry.json`)
- `PI_SUBAGENT_TRANSCRIPTS` — Run Transcript root (default `~/.pi-subagent/runs`)
- `PI_SUBAGENT_VIEWER` — set to `off` to disable Run Windows entirely
- `PI_SUBAGENT_POWERSHELL` — PowerShell hosting the window (default `powershell.exe`)
- `PI_SUBAGENT_VIEWER_SCRIPT` — viewer script to launch (default `viewer/run-window.ps1`; the test suite points this at a stand-in)
- `PI_BIN` — override the pi executable (used by tests)

## Run Windows

Every `pi_delegate` — sync or async — opens one **independent read-only window for that Run**
(`viewer/run-window.ps1`, launched by Node in STA mode). Each window replays the Run's Transcript and
then tails it, showing the complete formatted event stream: submitted/effective prompts, launch
metadata, lifecycle boundaries, complete assistant/thinking/tool events, final tool results plus any
intermediate output the final result did not cover, stderr diagnostics, per-message usage, and the
terminal record.

- **Lossless display.** Streaming fragments are withheld while the Run is healthy and reconciled into
  their complete event, so content is never duplicated. Unknown, malformed, foreign-version and
  unmatched content stays visible through explicit fallbacks instead of being dropped or repaired.
  Nothing is summarised or truncated, and there is no raw-events tab.
- **Evidence integrity.** Every transcript line read before the terminal record is hashed and compared
  with the terminal record's `sha256`. Sequence gaps, a trailing partial line, capture errors and
  schema-version mismatches mark the window `INCOMPLETE` instead of claiming success.
- **Completion.** A clean success shows `SUCCEEDED` with one system sound; every failure, protocol
  error or integrity downgrade shows `INCOMPLETE` with one warning sound. The attempt is recorded once
  per Run in `viewer-state.json`, so reopening never replays it. There is no OS toast.
- **Read-only.** Scrolling, selection, copy, select-all, find and a line-wrap toggle. A window can
  never send input, retry, cancel or mutate a Run.
- **Detached from capture.** Closing a window never affects capture or the Run. Completed windows stay
  open until closed by hand, and an open window does not pin its bundle: after replaying a completed
  Run it releases the files, so retention may clean the bundle while the window keeps its in-memory
  content and marks that the source was cleaned.
- **Reopen** with `pi_status` `{ runId, openWindow: true }` — a live window is raised, otherwise a new
  one is created once the previous instance is confirmed gone. Reopening never redispatches work or
  replays sound.

Requirements and limits: the window itself is **Windows-only** (capture, Transcript, `pi_status` and
retention stay cross-platform; elsewhere `pi_status` simply reports `viewer: unavailable`). The window
is a child of the MCP server, so it lives as long as the server does. Any GUI failure — unsupported
platform, missing script, launch error, handshake timeout — is isolated and never blocks a Run.

Standalone verification (no Run needed):

```bash
# Unicode/RTF/font path plus formatter-honesty self test (~1.5s)
powershell -NoProfile -STA -ExecutionPolicy Bypass -File viewer/run-window.ps1 -SelfTest

# Render one transcript bundle to text and print a JSON report
powershell -NoProfile -STA -ExecutionPolicy Bypass -File viewer/run-window.ps1 `
  -Replay -BundleDir ~/.pi-subagent/runs/<runId> -OutPath run.txt
```

## Test

```bash
npm test           # full suite
npm run test:fast  # dot reporter
```

Tests use a fake pi (`test/fixtures/fake-pi.sh`) and cover: async/sync, timeout, session-create-failure, multi-waiter, progress cap, registry persistence, redaction, Transcript schema/fidelity/recovery/retention, Run Window launch/handshake/reopen/containment, and the viewer formatter matrix (driven against real PowerShell on Windows).

## Project layout

```
src/
├── types.ts                 # all shared types + error codes
├── errors.ts                # ToolError helpers
├── runner/                  # parse.ts, argv.ts, spawn.ts, process-table.ts
├── registry/                # session.ts, run.ts, persist.ts, redact.ts
├── transcript/              # schema.ts, writer.ts, reader.ts, recovery.ts, store.ts
├── viewer/                  # manager.ts (launch/reopen), state.ts (viewer seam files)
├── tools/                   # delegate, status
└── server.ts                # MCP entry (stdio)
viewer/run-window.ps1        # the Run Window (separately shipped, Windows-only)
skills/pi-subagent/          # SKILL.md + references (sync-first strategy layer)
test/                        # fixtures/ + *.test.ts
docs/                        # design.md + implementation-plan.md (historical)
```

## Design & process

This project went through collaborative design + 4 rounds of external review before implementation. The spec and plan are committed under `docs/`:

- **[`docs/design.md`](docs/design.md)** — superseded historical design retained for context; it is not the current API contract.
- **[`docs/implementation-plan.md`](docs/implementation-plan.md)** — superseded historical implementation plan retained for context.

Key design decisions, all backed by real probing of `pi -p` output and external review:
- **`cwd` ≠ session storage** — `spawn({ cwd })` controls the working dir; Pi's session files use their default location (doesn't pollute the project).
- **async default + handshake** — new sessions wait for Pi's `session` event before returning (with a `sessionStartTimeoutMs`), so the host always gets a real `piSessionId`.
- **Progress redaction** — tool results are truncated + scrubbed for tokens/keys before being stored.

## Status

Working implementation. Not yet published to npm — clone, `npm install && npm run build`, then point your MCP host at `dist/server.js`.

## License

MIT
