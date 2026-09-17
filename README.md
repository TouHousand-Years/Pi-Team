# pi-subagent

> Turn the [Pi CLI](https://pi.dev) (`@earendil-works/pi-coding-agent`) into a **programmable coding sub-agent** that any MCP host (ZCode, Claude Code, Cursor, …) can delegate tasks to and track runs.

`pi-subagent` is a thin MCP server that wraps `pi -p --mode json` into two structured tools: `pi_delegate` to dispatch a task and `pi_status` to harvest its result. Process-isolated, fully session-based, sync/async dual-mode.

## Why

Pi is a minimal terminal coding agent. Rather than teaching Pi *methodology*, this project treats Pi as a **delegatable worker**: a host agent (ZCode / Claude Code) decides *when* to delegate, fires off a self-contained task, and harvests the result. One Pi process = one isolated sub-agent run.

- **Process isolation** — each delegation spawns one `pi -p` child process. A Pi crash only affects that run.
- **Fully session-based** — every task binds to a named session (e.g. `feat-auth`); subsequent calls auto-continue.
- **Sync / async** — `pi_delegate` defaults to `async` at the tool level; the skill layer drives `mode:"sync"` first and keeps async plus bounded long-poll collection as an explicit fallback.
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
| `pi_status` | Harvest a run's result (long-poll) |

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
- `PI_BIN` — override the pi executable (used by tests)

## Test

```bash
npm test           # full suite
npm run test:fast  # dot reporter
```

Tests use a fake pi (`test/fixtures/fake-pi.sh`) and cover: async/sync, timeout, session-create-failure, multi-waiter, progress cap, registry persistence, redaction, etc.

## Project layout

```
src/
├── types.ts                 # all shared types + error codes
├── errors.ts                # ToolError helpers
├── runner/                  # parse.ts, argv.ts, spawn.ts, process-table.ts
├── registry/                # session.ts, run.ts, persist.ts, redact.ts
├── tools/                   # delegate, status
└── server.ts                # MCP entry (stdio)
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
