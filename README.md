# Pi-Team

Pi-Team turns the [Pi CLI](https://pi.dev) into a coding worker that an MCP host can delegate work to and collect results from. It wraps `pi -p --mode json`, with named sessions, sync/async execution, persistent transcripts, and a read-only window for each Run on Windows.

Derived from **[guyiicn/pi-subagent](https://github.com/guyiicn/pi-subagent)**. Thanks to the original author for the foundation. This version exposes two MCP tools and adds per-Run transcript capture and viewing. The repository is named **Pi-Team**; the package, MCP server identity, skill directory and `PI_SUBAGENT_*` settings retain their `pi-subagent` names for compatibility.

## Current features

- **Two MCP tools:** `pi_delegate` starts work; `pi_status` waits for results and can reopen a Run's window.
- **Named sessions:** the first call creates a Pi session; later calls with the same name continue it in the same working directory.
- **Sync and async:** the API defaults to async. The bundled skill recommends sync for bounded work, with async for background work or parallel delegation.
- **Process isolation:** one Pi process per Run, up to four active Runs per server, and one active Run per session.
- **Execution controls:** choose a model, thinking level and tools, or disable Pi skills and context files through `constraints`.
- **Timeouts:** a 10-minute default Run deadline and stall detection after 5 minutes without recorded tool-result progress. Long thinking periods can trigger the stall limit.
- **Durable transcripts:** capture prompts, launch metadata, stdout/stderr bytes, lifecycle events and terminal integrity information, with recovery after interrupted capture.
- **Windows viewer:** a read-only Run Window with replay, live updates, search, copy and line wrapping.

The public API does not expose the original planning, session-management, kill or task/stage orchestration tools. Internal helpers and historical designs remain in the tree; [`src/server.ts`](src/server.ts) defines the current MCP surface.

## Install

Install Node.js and npm, then install and configure Pi with access to your chosen model provider:

```sh
npm install -g @earendil-works/pi-coding-agent
git clone https://github.com/TouHousand-Years/Pi-Team.git
cd Pi-Team
npm ci
npm run build
```

The `pi` executable must be on the MCP server's `PATH`. Rebuild after pulling changes: `dist/` is not committed. This project is installed from source and is not published to npm.

## Configure an MCP host

Add this server to a host supporting MCP over stdio, replacing the example with your checkout's absolute path:

```json
{
  "mcpServers": {
    "pi-subagent": {
      "command": "node",
      "args": ["/absolute/path/to/Pi-Team/dist/server.js"]
    }
  }
}
```

On Windows, use a JSON path such as `C:/Projects/Pi-Team/dist/server.js`. Use the compiled entry with `node`: a host may start the server from another working directory, where `npx tsx src/server.ts` cannot resolve this project's source and dependencies.

## Tools

### pi_delegate

| Parameter | Behavior |
| --- | --- |
| `prompt` | Required, nonempty task instructions. |
| `session` | Required name; reuse it to continue the Pi session. |
| `cwd` | Required for a new session and must exist. On continuation, an explicit value must match the original. |
| `goal` | Required for a new session. |
| `mode` | `async` (API default) or `sync`. |
| `runTimeoutMs` | Run deadline in milliseconds; default `600000`. |
| `constraints` | Optional per-call Pi configuration. Continuations do not automatically reuse prior constraints. |
| `allowUnknownTools` | Allows names beyond the wrapper's known tools: `read`, `bash`, `edit`, `write`. |

`constraints` accepts `tools` and `excludeTools` arrays, `model`, `thinking` (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`), `noSkills` and `noContextFiles`. These map to Pi CLI flags. The child process shares the user's filesystem permissions; process isolation is not a filesystem sandbox.

Example of a bounded synchronous call:

```json
{
  "prompt": "Read the source and write findings to review.md. Do not modify product code.",
  "session": "review-parser",
  "cwd": "C:/Projects/example",
  "goal": "Review the parser for correctness",
  "mode": "sync",
  "runTimeoutMs": 240000,
  "constraints": { "thinking": "high" }
}
```

After it finishes, continue the same session:

```json
{
  "prompt": "Recheck the first finding against existing tests and update review.md.",
  "session": "review-parser",
  "mode": "sync",
  "runTimeoutMs": 240000
}
```

For background work, set `mode` to `async` and save the returned `runId`. New sessions wait for Pi's session handshake before returning; its timeout is 10 seconds. Sync waits for the Run's terminal result.

### pi_status

```json
{
  "runId": "<runId returned by pi_delegate>",
  "waitTimeoutMs": 60000,
  "openWindow": false
}
```

`runId` is required. `waitTimeoutMs` defaults to `25000`; terminal Runs return immediately, and `0` returns a snapshot without waiting. `openWindow: true` raises or reopens the Windows viewer without dispatching another Run.

Responses include `status` and, when available, `result`, `progress`, `usage`, `error`, `timing`, `transcript` and `viewer`. Run states are `running`, `completed`, `error`, `killed` and `timeout`. A wait returning `running` has only ended the wait; the Run continues.

Common errors include `goal_required`, `cwd_invalid`, `cwd_mismatch`, `session_busy`, `resource_busy`, `not_found` and `run_expired`. Inspect errors before deciding whether to retry.

## Host skill

Load [`skills/pi-subagent/`](skills/pi-subagent/) through your host's skill mechanism to use the bundled delegation strategy:

- Start bounded work with `mode: "sync"` and `runTimeoutMs` at most `240000`.
- Use async explicitly for parallel/background work or work exceeding the sync budget.
- Collect async Runs with non-overlapping Monitor Waits: at most three `60000` ms waits, followed by `180000` ms waits.
- A disconnected sync call does not imply the Run stopped. Collect the same `runId` when available; never automatically redispatch the task.

This schedule assumes a 300-second host tool-call limit. Configure the host accordingly or keep calls below its actual limit. The repository includes the base `pi-subagent` skill; specialized skills mentioned in it are separate installations.

## Storage and retention

Session metadata persists atomically to `~/.pi-subagent/registry.json`. After restart, sessions left marked running become errors; later delegations can continue their Pi sessions. Pi stores its own session files independently of the task's `cwd`.

Run lookup is in memory, retaining at most 128 completed Runs. Restarting the server does not restore old `runId` values for `pi_status`, even if their transcript bundles remain on disk.

Each captured Run has a bundle under `~/.pi-subagent/runs/<runId>/`, including `manifest.json` and `transcript.jsonl`. Records carry sequence numbers, timestamps and byte-preserving payloads; the terminal record includes a SHA-256 digest. Transcripts retain full captured content, including prompts and tool output, rather than redacted progress summaries.

Retention cleans inactive terminal bundles after 7 days, then removes the oldest eligible bundles to target a 2 GiB quota. Cleanup runs on startup, every 15 minutes, and after finalization. Active captures are protected. A trash grace period means the quota is not an immediate hard disk limit.

## Windows Run Windows

When enabled on Windows, each delegation opens `viewer/run-window.ps1` in PowerShell STA mode. It replays the transcript and follows new events: prompts, assistant/thinking text, tool calls and results, diagnostics, usage and terminal state.

- Streaming fragments are reconciled with complete events; unknown or malformed content remains visible through fallbacks.
- Hash mismatches, sequence gaps, partial records and capture errors produce `INCOMPLETE` instead of claiming a clean capture.
- Clean success displays `SUCCEEDED`; other outcomes or integrity failures display `INCOMPLETE`. Completion sound attempts are recorded per Run so reopening does not replay them.
- Closing the read-only window does not cancel the Run or stop capture. `pi_status` can reopen it while the Run remains available.
- Completed windows release bundle files after replay, allowing retention to clean the source while keeping displayed content in memory.

The viewer requires Windows, PowerShell and the shipped script. Capture and status collection do not require a GUI. Unsupported platforms, disabled viewers and viewer launch failures do not stop delegation. Viewer processes are tied to the MCP server's lifetime.

## Environment variables

| Variable | Purpose / default |
| --- | --- |
| `PI_SUBAGENT_REGISTRY` | Session registry; `~/.pi-subagent/registry.json`. |
| `PI_SUBAGENT_TRANSCRIPTS` | Transcript root; `~/.pi-subagent/runs`. |
| `PI_SUBAGENT_VIEWER` | Set to `off` to disable Run Windows. |
| `PI_SUBAGENT_POWERSHELL` | Viewer PowerShell executable; `powershell.exe`. |
| `PI_SUBAGENT_VIEWER_SCRIPT` | Override the shipped `viewer/run-window.ps1`. |
| `PI_BIN` | Override the Pi executable, for tests or custom installations. |

## Development

```sh
npm run build
npm test
npm run test:fast
```

Tests use a fake Pi process instead of paid model calls. They cover the MCP surface, sessions, execution modes, deadlines, stalls, persistence, transcripts, recovery, retention, viewer lifecycle and formatting. Bash is needed for the fake-Pi fixture; some tests assume Git for Windows at `C:/Program Files/Git`. Viewer formatting tests use real PowerShell on Windows with headless replay/self-test modes. Specialized skills are checked when discovered in the test's configured skill roots.

```text
src/server.ts              MCP stdio entry and two-tool schema
src/tools/                 Delegation, status and retained prompt helpers
src/runner/                Arguments, process launch, parsing and validation
src/registry/              Sessions, Runs and persistence
src/transcript/            Capture, integrity, recovery and retention
src/viewer/                Viewer launch, reopen and state
viewer/run-window.ps1      Windows transcript viewer
skills/pi-subagent/        Bundled delegation skill and references
test/                     Automated tests and fixtures
docs/                     Historical design and implementation documents
```

[`docs/design.md`](docs/design.md), [`docs/implementation-plan.md`](docs/implementation-plan.md) and [`REVIEW.md`](REVIEW.md) are historical context, not the current API contract.

## License and attribution

[MIT](LICENSE). Original project: [guyiicn/pi-subagent](https://github.com/guyiicn/pi-subagent). The original copyright notice is preserved in `LICENSE`.
