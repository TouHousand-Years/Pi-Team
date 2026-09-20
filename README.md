# Pi-Team

Delegate tasks to the [Pi CLI](https://pi.dev) through MCP, with named sessions, sync/async execution and a read-only transcript window on Windows.

Based on [guyiicn/pi-subagent](https://github.com/guyiicn/pi-subagent).

If you are using Mattpocock's Skills, try [Matts-Skills-with-Pi-Team](https://github.com/TouHousand-Years/Matts-Skills-with-Pi-Team).

## Install

Requires Node.js, npm and Pi configured with access to a model provider.

```sh
npm install -g @earendil-works/pi-coding-agent
git clone https://github.com/TouHousand-Years/Pi-Team.git
cd Pi-Team
npm ci
npm run build
```

Ensure `pi` is on the MCP server's `PATH`. Run `npm run build` again after updating the checkout.

## Configure

Add this to your MCP host configuration, using the absolute path to `dist/server.js`:

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

On Windows, use a path such as `C:/Projects/Pi-Team/dist/server.js`. The MCP server keeps the name `pi-subagent` for compatibility.

## Adapted skills

This repository includes five skills under [`skills/`](skills/) that turn the two MCP tools into reusable, checkable workflows. The skills do not add new server tools: they define how the host scopes work, delegates it to Pi, verifies the result and stops safely.

| Skill | Use it for | Main boundary |
| --- | --- | --- |
| [`pi-team`](skills/pi-team/SKILL.md) | The shared delegation contract used by the other Pi skills: model selection, prompt composition, file ownership, result collection, concurrency and failure handling. | It supplies transport rules only; the active specialized skill still defines the task, outputs and acceptance criteria. |
| [`pi-explorer`](skills/pi-explorer/SKILL.md) | Evidence-backed repository investigation, including architecture, tests, recent commits, caches, frontends, concurrency, networking and reproducible failures. | It keeps product files read-only and returns conclusions with paths, line references, commands and explicit evidence gaps. |
| [`pi-worker`](skills/pi-worker/SKILL.md) | Bounded implementation or repository work with a closed baseline-execute-verify-correct loop. It fits coding, bulk edits, experiments, log analysis and tasks with observable checks. | Pi owns the declared output files; the host reviews them read-only and sends corrections back through another bounded delegation. |
| [`pi-translator`](skills/pi-translator/SKILL.md) | Long or consequential translations that require complete coverage, stable terminology and preservation of headings, tables, citations, code and formulas. | It translates from explicit source files, uses a glossary when needed and marks unresolved wording instead of silently guessing or omitting content. |
| [`pi-ultra-planner`](skills/pi-ultra-planner/SKILL.md) | High-leverage implementation plans, trade-off decisions and recovery plans after exploration or experiments have produced a compact evidence brief. | The planner receives text only: it has no tools, network access or write permission, and it never performs the implementation. |

The usual composition is `pi-explorer` for facts, `pi-ultra-planner` for a difficult decision, and `pi-worker` for execution. `pi-translator` is a separate document workflow. All four specialized skills delegate through `pi-team`, which uses only `pi_delegate` and `pi_status`.

## Delegate a task

Call `pi_delegate`:

```json
{
  "prompt": "Review the parser and write findings to review.md.",
  "session": "review-parser",
  "cwd": "C:/Projects/example",
  "goal": "Review parser correctness",
  "mode": "sync",
  "runTimeoutMs": 240000
}
```

- `prompt` and `session` are required. New sessions also require `goal` and an existing `cwd` directory.
- Reuse `session` to continue a conversation after its current Run finishes. You may omit `cwd` and `goal`; an explicit `cwd` must match the original.
- `mode: "sync"` waits for completion. `mode: "async"` (default) returns a `runId` to collect later.
- `runTimeoutMs` defaults to `600000` (10 minutes). Keep synchronous calls within your host's tool-call timeout.
- Up to four Runs can execute at once, with one per session. Runs stop after 5 minutes without recorded tool-result progress.

Optional `constraints` configure each call independently:

```json
{
  "model": "<model identifier configured in Pi>",
  "thinking": "high",
  "tools": ["read", "bash", "edit", "write"]
}
```

Place this object under `constraints` in `pi_delegate`. `excludeTools` is also supported. Thinking levels are `off`, `minimal`, `low`, `medium`, `high` and `xhigh`. For tool names beyond those shown, set `allowUnknownTools: true`. Resend constraints when continuing a session if needed.

## Collect results

Call `pi_status` with the returned `runId`:

```json
{
  "runId": "<runId>",
  "waitTimeoutMs": 25000
}
```

The call waits until completion or the wait timeout (default: 25 seconds). `waitTimeoutMs: 0` returns immediately. If `status` is still `running`, wait again using the same `runId`. Terminal states are `completed`, `error`, `killed` and `timeout`; inspect `result` or `error` as appropriate.

A host timeout does not necessarily stop the Run. If you have its `runId`, collect that Run before starting another. Old Run IDs are unavailable after a server restart, though session metadata and transcripts remain on disk.

## Windows viewer

Each Run automatically opens a read-only transcript window on Windows. Closing it does not stop the Run. To reopen it, call `pi_status` with `"openWindow": true`.

Set `PI_SUBAGENT_VIEWER=off` to disable windows. Delegation and transcript capture work without the viewer.

## Environment variables

| Variable | Purpose / default |
| --- | --- |
| `PI_BIN` | Pi executable override. |
| `PI_SUBAGENT_VIEWER` | `off` disables Run Windows. |
| `PI_SUBAGENT_POWERSHELL` | Viewer executable; `powershell.exe`. |
| `PI_SUBAGENT_VIEWER_SCRIPT` | Override `viewer/run-window.ps1`. |
| `PI_SUBAGENT_REGISTRY` | Session metadata; `~/.pi-subagent/registry.json`. |
| `PI_SUBAGENT_TRANSCRIPTS` | Full transcripts; `~/.pi-subagent/runs`. |

Transcripts include prompts and tool output. Inactive completed bundles are cleaned after 7 days, with oldest-first cleanup targeting a 2 GiB quota.
