# TDD exploration 05 — Reduce the MCP core to the supported surface

Read-only Explorer report for ticket `.scratch/pi-subagent-slimming/issues/05-reduce-mcp-core.md`
(Status: open, Blocked by 01, 04 — both tickets are now `resolved`; the block graph
`.scratch/pi-subagent-slimming/blocking-graph.md` still lists 04 as open, see §8).
Evidence boundary: working tree HEAD `a777332e07d9302a6dd7a9dc7ec6e2e33562d67d`
("更改计划"), `CONTEXT.md`, `docs/agents/*`, `docs/adr/`, ticket 04 + accepted proposal,
`map.md`, `_grilling-decisions.md`, `_grilling-exploration-04.md`, `_ultra-proposal-04.md`,
all of `src/`, all of `test/`, `package.json`, `tsconfig.json`, live `~/.pi-subagent/`.
No product, test, ticket, map, or config file was modified. The only write is this file.

---

## 1. Direct answer

The smallest coherent 05 implementation is a **pure deletion + server wiring edit**, not a
rewrite. Two behavior tests are genuinely red today (MCP tool surface, removed-tool rejection);
everything else that must survive is already green and needs only characterization tests to
pin it before deletion. The true public seam for the surface is **the stdio MCP server itself**
(`src/server.ts`), which today has **zero tests** — the whole suite imports tool functions
directly. This is the one new test harness 05 must add.

Suggested seam set for user confirmation (details in §5):

| # | Seam (public interface) | Candidate test file | Red/Green today |
|---|---|---|---|
| S1 | MCP `ListTools` returns exactly `pi_delegate`, `pi_status` | `test/mcp-surface.test.ts` (new) | RED (12 tools) |
| S2 | MCP `CallTool` rejects removed names with `{"error":"unknown tool"}` | same file | RED for legacy names |
| S3 | MCP `pi_delegate(sync)` create → continue same `session` | same file | GREEN (guard) |
| S4 | MCP `pi_delegate(async)` → `pi_status` long-poll → terminal | same file | GREEN (guard) |
| S5 | MCP timeout lifecycle (`hang` + small `runTimeoutMs`) → `pi_status` `timeout`, no `pi_kill` | same file | GREEN (guard) |
| S6 | `registry.json` v1 backward-read: pre-written session continued across server start | same file | GREEN (guard) |
| S7 | `tasks.json` untouched/unused after a delegate run | same file | GREEN (guard) |

---

## 2. Current MCP public surface and the two kept tools

### 2.1 Registration entry point and all public tools

Single registration site: `src/server.ts`.

- `ListToolsRequestSchema` handler returns the array literal spanning
  `src/server.ts:65-242`. Exact names and declaration lines:
  - `pi_delegate` `:67`
  - `pi_status` `:85`
  - `pi_plan` `:94`
  - `pi_session_list` `:109`, `pi_session_snapshot` `:114`, `pi_session_fork` `:123`
  - `pi_kill` `:132`
  - `pi_task_create` `:141`, `pi_task_plan` `:183`, `pi_task_stage_run` `:197`,
    `pi_task_stage_collect` `:215`, `pi_task_list` `:228`
- `CallToolRequestSchema` dispatch `switch` spans `src/server.ts:244-303`; cases at
  `:246` (delegate), `:249` (status), `:266` (plan), `:269-277` (session), `:278` (kill),
  `:281-298` (task). Default unknown branch `:299-303` returns
  `{ error: "unknown tool" }` with `isError: true`.
- Imports to remove with the legacy tools: `src/server.ts:9-16`
  (`task-persist`, `TaskRegistry`, `planTool`, `session*`, `kill`, `task*`).
- Task persistence wiring: `TASKS_PATH` `:22-23`, `const tasks = new TaskRegistry()` `:28`,
  `loadTasks` `:33`, `persistTasks()` hook `:48-57`.
- `pi_status` is coupled to tasks today: `src/server.ts:249-265` loops
  `tasks.list()` and calls `applyReviewResult` after a terminal run. This must be removed or
  `src/server.ts` will not compile once `src/tools/task.ts` is deleted.

Reproduced (see §9): a spawned server answers `ListTools` with **12 tools**:
`pi_delegate,pi_kill,pi_plan,pi_session_fork,pi_session_list,pi_session_snapshot,pi_status,pi_task_create,pi_task_list,pi_task_plan,pi_task_stage_collect,pi_task_stage_run`.

### 2.2 `pi_delegate` current behavior and types

Declaration/implementation: `src/tools/delegate.ts`.

- Input type `DelegateInput` `:29-39`: `prompt`, `session`, `cwd?`, `goal?`, `constraints?`,
  `mode?: "sync"|"async"`, `runTimeoutMs?`, `stallTimeoutMs?`, `allowUnknownTools?`.
- Output type `DelegateOutput` `:47-56`: `runId`, `session?` (`Snapshot`, i.e. `SessionRecord`
  without `piSessionId`), `status`, `result?`, `progress?`, `progressTruncated?`, `usage?`,
  `error?`.
- Create-vs-continue decision `:65-79`: no record ⇒ `isCreate`, requires `goal` +
  existing-directory `cwd` (`goal_required` / `cwd_invalid`), else reuse `existing.piSessionId`;
  a `cwd` mismatch ⇒ `cwd_mismatch`; a running session ⇒ `session_busy` `:77`.
- Concurrency cap `MAX_CONCURRENCY = 4` `:10`, enforced at `:82` ⇒ `resource_busy`
  (`src/errors.ts:25`).
- Default mode is **`async`** `:84` (`const mode = input.mode ?? "async"`). Default
  `runTimeoutMs = 600000` `:86`.
- Run created in `RunRegistry` `:91`; spawn `:92-97`; session handshake on the `session`
  NDJSON event `:209-225`; progress on `tool_execution_end` `:241-256`; stall watchdog
  default `300000` `:271-281`.
- Terminal classification in `finalize` `:114-205`: spawn error ⇒ `session_create_failed`
  `:125-133`; no session event on create ⇒ `session_create_failed`/`session_start_timeout`
  `:134-146`; SIGTERM/SIGKILL ⇒ `manualKills` ? `killed` : `stalledKills` ? `stalled` :
  `timeout` `:147-158`; non-zero exit ⇒ `nonzero_exit` `:169-171`; no `agent_end` ⇒
  `no_agent_end` `:172-174`; success otherwise. `runs.complete` `:177-184`; session
  updates `:187-198`; persist hook `:201`.
- Async returns after handshake and finalizes in background `:310-317`; sync awaits
  `finalize` `:319-330`.
- `manualKills`/`markManualKill` `:15-16` exist **only** for `src/tools/kill.ts`
  (`src/tools/kill.ts:6,17`). After `pi_kill` is removed, `markManualKill` has no caller;
  the `killed` branches `:147-150,164-168` become unreachable but harmless. Keep them
  (do not refactor `delegate.ts`).

`Snapshot`/`Run`/persisted types live in `src/types.ts`:
`Run.status` union `"running"|"completed"|"error"|"killed"|"timeout"` `:58`;
`SessionRecord` `:38-52`; `Snapshot` `:71`; `RegistryFile {version:1,sessions}` `:101-104`;
`ERROR_CODES` `:107-136`.

### 2.3 `pi_status` current behavior and types

Implementation: `src/tools/status.ts`.

- Input `StatusInput` `:5-8`: `runId`, `waitTimeoutMs?`.
- Output `StatusOutput` `:10-18`: `runId`, `session?`, `status`, `result?`, `progress?`,
  `progressTruncated?`, `usage?`, `error?`.
- Terminal/absent short-circuit `:22-30`; unknown ⇒ `run_expired` if evicted (`:35`,
  `RunRegistry.isExpired` `src/registry/run.ts:48-50`) else `not_found` `:36`.
- Long-poll default 25000 ms `:38-40`; `waitTimeoutMs: 0` ⇒ immediate `running` `:41-43`;
  `runs.waitForCompletion` `:44` (`src/registry/run.ts:96-110`).

`RunRegistry` (`src/registry/run.ts`): `create` `:32-43`, `complete` `:60-77`,
`appendProgress` (200 cap + `progressTruncated`) `:79-93`, `waitForCompletion` `:96-110`,
`cleanupExpired` TTL `:113-124` (no production caller), 128-completed FIFO eviction
`:30,126-133`.

---

## 3. Legacy tools and their exclusive machinery — file/reference graph and safe delete set

### 3.1 Tools and exclusive code (verified import graph)

| Legacy surface | Tool file(s) | Exclusive machinery | Only importers (src) | Only importers (test) |
|---|---|---|---|---|
| `pi_plan` | `src/tools/plan-tool.ts` (9 lines) | `src/scheduler/plan.ts`, `src/scheduler/keywords.ts` | `src/server.ts:13` | `test/scheduler.test.ts:3` |
| `pi_session_*` | `src/tools/session.ts` (52 lines) | `spawnFork`/`buildForkArgs` inside shared `src/runner/spawn.ts:34-38`, `src/runner/argv.ts:24-26` | `src/server.ts:14` | `test/fork.test.ts:5` |
| `pi_kill` | `src/tools/kill.ts` (28 lines) | `markManualKill`/`manualKills` in `src/tools/delegate.ts:15-16` | `src/server.ts:15` | `test/kill.test.ts:6`, `test/integration.test.ts:8` |
| `pi_task_*` | `src/tools/task.ts` (432 lines) | `src/registry/task.ts` (165), `src/registry/task-persist.ts` (108), `src/tools/stage-prompt.ts` (126), `src/runner/validate.ts` (117) | `src/server.ts:9,10,16` | `test/task-tools.test.ts`, `test/task-integration.test.ts`, `test/task-persist.test.ts`, `test/stage-prompt.test.ts`, `test/validate.test.ts`, `test/validate-multifile.test.ts` |

`src/tools/task.ts` imports `delegate`, `status`, `validate`, `stage-prompt`, `TaskRegistry`
(`src/tools/task.ts:3-11`); `pi_status`'s server handler imports `applyReviewResult`
(`src/server.ts:16,256`).

### 3.2 Safe to delete (whole-file exclusive; nothing kept imports them)

- `src/tools/plan-tool.ts`, `src/scheduler/plan.ts`, `src/scheduler/keywords.ts`
- `src/tools/session.ts`
- `src/tools/kill.ts`
- `src/tools/task.ts`, `src/registry/task.ts`, `src/registry/task-persist.ts`
- Tests (forced, because they `import` the files above):
  `test/scheduler.test.ts` (18), `test/fork.test.ts` (2), `test/kill.test.ts` (2),
  `test/task-tools.test.ts` (15), `test/task-integration.test.ts` (3),
  `test/task-persist.test.ts` (10), `test/stage-prompt.test.ts` (10),
  `test/validate.test.ts` (12), `test/validate-multifile.test.ts` (6).

### 3.3 Shared structures that must stay (do not refactor)

- `src/registry/session.ts` (`SessionRegistry`) — Pi Session continuity, used by
  `delegate.ts` and `server.ts`; persisted by `src/registry/persist.ts`. The name
  "session" here is the **retained** Pi Session, unrelated to the removed
  `pi_session_*` tools.
- `src/registry/run.ts`, `src/registry/persist.ts`, `src/registry/redact.ts`
- `src/runner/spawn.ts`, `parse.ts`, `process-table.ts`, `argv.ts`
  (`buildForkArgs`/`spawnFork` become unused but live in shared files — leave them).
- `src/tools/delegate.ts`, `src/tools/status.ts`
- `src/errors.ts`, `src/types.ts`

### 3.4 Residual-only candidates (ticket says remove "obsolete"; user says prefer residue)

Conservative recommendation (lowest risk, matches "宁可残留"):
keep `src/tools/stage-prompt.ts`, `src/runner/validate.ts`, the task-only types/error
codes in `src/types.ts:107-231` and `src/errors.ts:29-33`, and `buildForkArgs`/`spawnFork`.
They become unreferenced dead code but compile cleanly (`noUnusedLocals` is not enabled in
`tsconfig.json`). Aggressive option: delete `stage-prompt.ts`, `validate.ts`, their tests,
and prune `PlanInput/PlanOutput/SessionSpec/Task/Stage/StageAttempt/StageCreateInput/
StageRunInput/ManualPanel/ValidateRule` plus `TASK_*`/`DEPENDENCY_UNMET`/`PLAN_DRAFT_MISSING`/
`FORK_TIMEOUT` codes. `test/types.test.ts:6-14` only asserts a required subset, so pruning
does not break it. Recommend deciding this with the user (§8, Q3).

### 3.5 Required edits (not deletions)

- `src/server.ts`: drop imports `:9-16`; drop `TASKS_PATH`/tasks registry/`persistTasks`
  `:22-23,28,33,48-57`; keep tool entries only for `:67-91`; keep dispatch only `:246-265`
  but remove the `applyReviewResult` block `:250-262`.
- `test/integration.test.ts:8,49-61`: remove the `kill` import and the "kill 跨调用" test
  (the other 5 tests stay).
- `test/argv.test.ts:3,36-38`: optionally drop the `buildForkArgs` import and fork test if
  fork machinery is pruned; keep otherwise.
- `README.md` and `docs/*` (see §8).

---

## 4. `registry.json` backward-read and legacy `tasks.json` untouched/unused — current state and risk

### 4.1 Observed current state

- Live user state (read-only probe of `C:/Users/qnhxx/.pi-subagent/`):
  `registry.json` exists, 440002 bytes, `version:1`, **45 sessions**; `tasks.json` **absent**.
  (Matches `_exploration.md:118` which recorded 266595 B; the file has grown since.)
- `loadRegistry` (`src/registry/persist.ts:34-63`) is defensive and version-tolerant: missing
  file ⇒ `[]` `:35`; unreadable ⇒ `[]` `:41`; invalid JSON ⇒ copy to
  `registry.json.corrupt-<ts>` + `[]` `:47-51`; non-array `sessions` ⇒ `[]` `:53-55`;
  per-record `fixRecord` `:66-93` drops records missing `name/piSessionId/cwd/goal` or with
  an invalid status, backfills `progress/lastActive/msgCount`, and rewrites
  `running → error` with `interrupted_by_restart` `:93-96`. It never writes on load.
- `saveRegistry` (`src/registry/persist.ts:9-27`) writes `{version:1,sessions}` atomically
  (tmp+rename) through a serialized `writeChain`, dropping `runId`.
- `tasks.json` is a parallel path (`src/registry/task-persist.ts`) loaded at
  `src/server.ts:33`. It is read at startup and written only via `persistTasks`
  (`src/server.ts:48-57`); probe shows it does not exist, so the live service has never
  created one.
- Ticket 04's accepted answer and `map.md:23` require: registry v1 stays readable; legacy
  `tasks.json` is left untouched and unused (`_grilling-decisions.md:27`,
  `_grilling-exploration-04.md:93`).

### 4.2 Risks

1. **Registry compatibility risk is low** for reads (loader is tolerant), but there is **no
   test that drives a pre-existing registry through the *server*** — only
   `test/persist.test.ts` unit tests `loadRegistry`. A regression in server startup wiring
   (e.g. deleting the `sessions.loadAll(loaded.sessions)` call at `src/server.ts:31`) would
   silently drop all continuity. S6 closes this.
2. **Partial deletion risk**: deleting only `src/tools/task.ts` but leaving
   `src/server.ts:9-10,22-23,28,33,48-57` would fail to compile; deleting the task tools but
   leaving the `loadTasks` call would still *read* `tasks.json` (not "unused"). S7 pins the
   final byte-level untouched property.
3. **Version field is ignored** by `loadRegistry`; a future `version:2` file would be parsed
   under v1 assumptions. Out of scope for 05, but a known unknown.
4. `RunRegistry.cleanupExpired` (24 h TTL) has no production caller (`grep` shows only the
   definition and `test/run-registry.test.ts:53`). Not 05's concern; note for 06/09.

---

## 5. Candidate public test seams

The project convention (`test/*.test.ts`) is **direct function import + fake-pi subprocess**
(`test/helpers.ts:8-36`, `test/fixtures/fake-pi.sh`). That convention cannot express
"tool X is gone" because a deleted module is a compile-time, not runtime, assertion. So 05
needs one new black-box harness over the real MCP server.

### Seam A — spawned stdio MCP server (primary, all of S1–S7)

- Public interface: launch `src/server.ts` as a child, speak JSON-RPC with
  `Client` + `StdioClientTransport` from the already-installed SDK (1.29.0,
  `@modelcontextprotocol/sdk/client/index.js`, `.../client/stdio.js`; exports confirmed in
  `node_modules/@modelcontextprotocol/sdk/package.json:24-33`).
- Spawn args: `process.execPath` + `["--import","tsx","src/server.ts"]` (same loader the
  `package.json` test script uses `:11-12`).
- Env: spread `process.env`, override `PI_SUBAGENT_REGISTRY` and `PI_SUBAGENT_TASKS` to
  temp paths so the live 45-session registry is never touched, and set `PI_BIN` to
  `bash <repo>/test/fixtures/fake-pi.sh` with `FAKE_PI_MODE`.
- No product refactor required. Verified working in read-only probes (§9).
- Caveat: `src/server.ts` has top-level `await server.connect(transport)` `:337-338` and
  installs process handlers `:305-333`; it therefore cannot be imported in-process. Spawning
  is required unless a future ticket extracts a `createServer()` factory (that extraction is
  a refactor and is not recommended here).

### Seam B — direct tool-function seam (existing convention, retained for guards)

`delegate()` / `status()` are already exercised directly with `SessionRegistry`,
`RunRegistry`, `ProcessTable` and fake-pi (`test/delegate.test.ts:8-11,16-22`,
`test/integration.test.ts:11-21`). Use this only for fine-grained regression tests if the
spawned-server harness proves flaky/slow; it does not cover the MCP surface.

### Seam C — filesystem seam (for S6/S7)

`PI_SUBAGENT_REGISTRY` / `PI_SUBAGENT_TASKS` env + temp dir (`test/persist.test.ts:17`
pattern). S6 pre-writes a v1 registry and asserts continuity through the server; S7 writes a
sentinel `tasks.json` and asserts byte-equality + no `tasks.json.tmp` after a run.

### Per-seam assertion sketches (no internal access)

- S1: `(await client.listTools()).tools.map(t=>t.name).sort()` deep-equals
  `["pi_delegate","pi_status"]`.
- S2: `await client.callTool({name:"pi_kill",arguments:{runId:"x"}})` (and one
  `pi_task_list`, `pi_plan`, `pi_session_list`) has `isError===true` and the text payload
  parses to `{error:"unknown tool"}`. (Reproduced text shape today for a bogus name: §9.)
- S3: `pi_delegate({prompt,session:"s1",cwd:tmp,goal:"g",mode:"sync"})` then
  `pi_delegate({prompt,session:"s1",mode:"sync"})`; both terminal-complete, and the second
  returned `session.msgCount >= 1`. If continuity were lost, the second call would fail with
  `goal_required` (create path). Uses `fakePiEnv("success")`.
- S4: async delegate then `pi_status({runId, waitTimeoutMs: 5000})` ⇒ `status:"completed"`,
  non-empty `result`.
- S5: `fakePiEnv("hang")`, delegate async with `runTimeoutMs:500`, then
  `pi_status({runId, waitTimeoutMs:3000})` ⇒ `status:"timeout"` and `error.code==="timeout"`.
- S6: write v1 registry with one idle session bound to the temp cwd; start server; call
  `pi_delegate({prompt,session:"<name>",mode:"sync"})` with no `goal`/`cwd`; expect
  `status:"completed"` (proves the server loaded v1 and reused `piSessionId`).
- S7: write sentinel `tasks.json`; run one delegate; assert file bytes unchanged and
  `readdirSync(dir)` contains no `tasks.json.tmp`.

---

## 6. Existing test patterns, fixtures, and exact commands per seam

### 6.1 Patterns / fixtures to reuse

- `test/helpers.ts:8-17` `fakePiEnv(mode)` sets `PI_BIN=bash <abs fake-pi.sh>` and
  `FAKE_PI_MODE`; `:19-22` `tmpCwd()`; `:24-36` `withEnv()` restores env.
- `test/fixtures/fake-pi.sh` modes: `success` (default), `no_session`, `hang`, `error_exit`,
  `stall`, `stage_success`, `stage_success_secondtry` (`test/fixtures/fake-pi.sh:1-56`).
  For MCP work only `success`/`hang`/`no_session` are needed.
- `deps()` factory + `drain()` running-count loop pattern: `test/delegate.test.ts:8-24`,
  `test/integration.test.ts:11-27`. Spawned-server tests instead close the MCP client and
  wait for child exit.
- Registry temp-file pattern: `test/persist.test.ts:8,17`.

### 6.2 Commands (verified)

- Typecheck (src only; `tsconfig.json` `include: ["src/**/*"]`, `exclude` includes `test`):
  `npx tsc --noEmit` → exit 0 today.
- Build (emits the real MCP entry `dist/server.js`, gitignored): `npm run build`.
- Full suite: `npm test` (glob `test/*.test.ts`, `package.json:11`) → baseline **140 tests,
  136 pass, 4 fail** (§8).
- Fast reporter: `npm run test:fast` (`package.json:12`).
- Single file: `node --import tsx --test test/mcp-surface.test.ts`.
- The same single-file command is how each slice should be run red/green before the full
  suite.

### 6.3 Seam → command map

| Seam | Test file | Narrow command |
|---|---|---|
| S1/S2 | `test/mcp-surface.test.ts` | `node --import tsx --test test/mcp-surface.test.ts` |
| S3–S7 | `test/mcp-surface.test.ts` | same (one file, one server harness, sequential subtests) |
| regression guards (kept) | existing files | `npm test` |
| type integrity | — | `npx tsc --noEmit` |

Keep all S1–S7 in one file so the expensive server-spawn happens once per test (or use
`before`/`after`); node:test runs top-level tests concurrently by default only across files,
within a file they still execute serially unless `concurrency` is set, so ordering is safe.

---

## 7. Recommended ordered minimal vertical slices

For a deletion task the correct TDD order is: **pin surviving behavior with green
characterization tests first, then make the surface test go red→green by deleting**. Every
slice is one public-interface behavior test; none asserts internals.

- **Slice 0 (harness).** Add `test/mcp-surface.test.ts` with the stdio client/server
  bootstrap and a `close()` that terminates the child; assert only that the server starts and
  answers `listTools` (count > 0). This validates the seam itself.
- **Slice 1 (S6, green guard first).** Registry v1 backward-read continuity through the
  server (pre-written registry + continue without `goal`/`cwd`). Protects the one data asset
  (live 45 sessions) before any deletion.
- **Slice 2 (S3, green guard).** Sync create→continue continuity in one server session.
- **Slice 3 (S4, green guard).** Async delegate → long-poll terminal `completed`.
- **Slice 4 (S5, green guard).** Hang → `timeout` lifecycle with no kill tool.
- **Slice 5 (S7, green guard).** Sentinel `tasks.json` untouched/unused after a run.
- **Slice 6 (S1, RED now).** `listTools` is exactly `[pi_delegate, pi_status]`.
- **Slice 7 (S2, RED now for legacy names).** Removed names (`pi_plan`, `pi_kill`,
  `pi_session_list`, `pi_task_list`, …) return `isError` + `{"error":"unknown tool"}`.
- **Slice 8 (deletion).** Delete the files in §3.2, edit `src/server.ts` (§3.5), delete the
  forced tests, edit `test/integration.test.ts`. Re-run Slices 1–7 (all green) and
  `npx tsc --noEmit`.
- **Slice 9 (docs).** Update/prune `README.md` tool docs and decide on `docs/*` (§8).
- **Slice 10 (full gate).** `npm run build` + `npm test`; expect the 4 `stage-prompt`
  failures to disappear with `test/stage-prompt.test.ts`, leaving 0 failures.

Why this order: Slices 1–5 are the "safe Run lifecycle + Session continuity" contract the
ticket explicitly says to retain; making them green-first means any accidental deletion that
breaks them is caught immediately. Slices 6–7 are the actual acceptance criteria for
"only two tools". No slice tests `manualKills`, `RunRegistry`, or any private function.

---

## 8. ADR / project-spec conflicts, open questions, baseline failures

### ADR / normative context

- `docs/adr/` contains only `.gitkeep` — **no ADRs exist** (`git ls-files docs/adr` →
  `docs/adr/.gitkeep`). So there is no ADR to honor or conflict with; creating a Transcript/MCP
  ADR is a new decision, not a lookup. (`docs/agents/domain.md` still requires flagging
  conflicts, hence this explicit statement.)
- `CONTEXT.md` binding glossary: **Run**, **Host Session**, **Run Window**, **Transcript**,
  **Monitor Wait**. The code's `RunRegistry`/`Run` matches "Run". The removed tools used the
  forbidden word "Task"; removal aligns the surface with `CONTEXT.md`. `SessionRegistry`
  denotes a Pi Session, not the glossary's Host Session; keep the name to avoid a refactor.
- `map.md:20` and ticket 04's answer require the two-tool surface, registry v1 readability,
  untouched `tasks.json`, and "never auto-redispatch after a sync disconnect/timeout".
  05 must not add redispatch.
- `docs/agents/issue-tracker.md`: tickets live under `.scratch/<feature>/issues/NN-*.md`.
  Ticket 05 is `Status: open`; 01 and 04 are `resolved`, so 05 is unblocked. The rendered
  `blocking-graph.md` still marks 04 `open` — stale derived artifact, not a real blocker.

### Conflicts / open questions for the main session

1. **Default mode (`sync` vs `async`).** `map.md` destination says "sync-first"; ticket 04's
   answer says "`pi_delegate` remains sync-first"; but `delegate.ts:84` defaults to `async`,
   and ticket 08 is "Adapt Pi skills to sync-first operation" (blocked by 05). **Question:**
   is changing the default in scope for 05? Recommendation: **no** — 05 is a removal ticket,
   leave `:84` unchanged and let 08 own it. Flag this explicitly to the user.
2. **Documentation scope.** Obsolete-by-tooling docs (verified to reference removed tools):
   `README.md` (`:4` "7 tools", `:14` scheduler bullet, tool table `:47-62`,
   review/async/restart notes `:64-68`, task persistence `:76`, layout `:145-147`,
   Test/Status sections), `docs/design-batch1.md` (whole file), `docs/batch1-test-handoff.md`
   (whole file), `docs/implementation-plan.md` (whole file; `pi_plan`/session/kill/task
   plan), and the legacy tool sections of `docs/design.md` (`:334-441,547-574,780-782`).
   `docs/design.md` and `docs/implementation-plan.md` also document the retained
   delegate/status core, so deleting them wholesale loses still-valid spec. **Question:** delete,
   mark superseded, or leave as history? (`skills/pi-subagent/*` also references removed tools
   but is explicitly ticket 08's scope — do not touch in 05.)
3. **Residual dead code vs aggressive prune** (§3.4). User instruction favors residue; ticket
   05 says remove "exclusive machinery". **Question:** confirm keeping `stage-prompt.ts`,
   `validate.ts`, task types, `buildForkArgs`/`spawnFork`.
4. **`pi_status` response shape.** Ticket 04's answer lists a richer status result (outcome,
   capture integrity, viewer state, Transcript availability). That is ticket 06/07 work;
   **05 must preserve today's shape** (`status.ts:10-18`) and only drop the task verdict loop.
5. **Server-surface test lifetime.** Spawning `tsx src/server.ts` per test is ~0.2-1 s; confirm
   the suite's time budget is acceptable, or extract `createServer()` (a refactor) — recommend
   spawn.

### Baseline failures (pre-existing, unrelated to 05)

- `npm test`: **140 tests, 136 pass, 4 fail**, all four in `test/stage-prompt.test.ts`
  (`buildStagePrompt 输入文件用绝对路径`, `buildStagePrompt 输出文件绝对路径 + 只写它`,
  `buildStagePrompt 自动注入 dependsOn…`, `buildReviewPrompt 含审阅指令 + verdict 要求`).
  Cause: hardcoded POSIX `/proj/...` expectations (`test/stage-prompt.test.ts:9,45,51,70,108`)
  versus Windows path separators. Baseline independently confirmed by `map.md` Notes
  ("Four existing test/stage-prompt.test.ts failures are Windows path-separator assertions").
  Since `test/stage-prompt.test.ts` is exclusive to `pi_task_*` and is deleted by 05, these 4
  failures disappear as a side effect — 05's full-suite gate should be **0 failures**.
- `npx tsc --noEmit` → exit 0.

---

## 9. Reproduction status (read-only)

All probes ran from the repo root; `git status --porcelain` was empty before and after; no
product/test/config file changed. No temp artifact was written inside the repo except this
report.

1. Surface probe (spawned `node --import tsx src/server.ts`, SDK stdio client, `listTools`):
   output `TOOL_COUNT 12`,
   `TOOL_NAMES pi_delegate,pi_kill,pi_plan,pi_session_fork,pi_session_list,pi_session_snapshot,pi_status,pi_task_create,pi_task_list,pi_task_plan,pi_task_stage_collect,pi_task_stage_run`.
2. Unknown-tool probe: `callTool({name:"pi_not_a_tool"})` → `IS_ERROR true`,
   `CONTENT [{"type":"text","text":"{\"error\":\"unknown tool\"}"}]`. This confirms the S2
   assertion shape and that the default branch does not persist/write.
3. Live state probe: `~/.pi-subagent/registry.json` exists (440002 B, `version:1`, 45
   sessions); `tasks.json` absent.
4. `npx tsc --noEmit` → exit 0. `npm test` → 140/136/4 as above.
5. Import-graph greps (`grep -rn` over `src`+`test`) for `scheduler/`, `plan-tool`,
   `tools/session`, `tools/task`, `registry/task`, `task-persist`, `runner/validate`,
   `stage-prompt`, `tools/kill`, `spawnFork|buildForkArgs` — results are the tables in §3.
6. `git rev-parse HEAD` → `a777332e07d9302a6dd7a9dc7ec6e2e33562d67d`; `git ls-files`
   enumerations for src/test/docs.

## 10. Evidence index (paths with the decisive lines)

- Surface: `src/server.ts:9-16,22-23,28,33,48-57,65-242,244-303` (esp. `:67,85,94,109-132,141-238,246-299`).
- Kept tools: `src/tools/delegate.ts:29-56,65-97,114-205,271-281,310-330`; `src/tools/status.ts:5-46`.
- Types: `src/types.ts:38-71,101-136`; errors: `src/errors.ts:5-33`.
- Registries: `src/registry/session.ts:118-121`; `src/registry/run.ts:32-133`;
  `src/registry/persist.ts:9-27,34-63,66-96`.
- Legacy graph: `src/tools/plan-tool.ts:1`; `src/scheduler/plan.ts:1`; `src/tools/session.ts:1-52`;
  `src/tools/kill.ts:1-28`; `src/tools/task.ts:1-432`; `src/registry/task.ts:1-165`;
  `src/registry/task-persist.ts:1-108`; `src/tools/stage-prompt.ts:1-126`;
  `src/runner/validate.ts:1-117`;
  `src/runner/spawn.ts:34-38`; `src/runner/argv.ts:24-26`.
- Tests/fixtures: `test/helpers.ts:8-36`; `test/fixtures/fake-pi.sh:1-56`;
  `test/delegate.test.ts:8-24`; `test/integration.test.ts:8,49-61`;
  `test/persist.test.ts:8,17`; `test/stage-prompt.test.ts:9,45,51,70,108`; `test/argv.test.ts:36-38`.
- Specs: `CONTEXT.md`; `map.md:20-23`; `issues/04-fix-transcript-window-seam.md` (Answer);
  `_grilling-decisions.md:14-31`; `_grilling-exploration-04.md:91-93,97,150`;
  `_ultra-proposal-04.md`; `docs/adr/` (empty); `docs/agents/*`.
