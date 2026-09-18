# Qualify and replace the live service

Type: wayfinder:task
Status: resolved
Blocked by: 07, 08

> Machine qualification, backup, cutover and a verified rollback are complete.
> On 2026-09-18 the user confirmed that production Run Window human acceptance passed.
> The three follow-up audit defects are fixed and covered by regression tests.

## Question

With no active Run, qualify the complete change against build, targeted compatibility, full regression, concurrent windows, transcript retention/failure, sync return, async fallback, and human visual acceptance; then back up configuration/state, point Codex at this repository's verified build, preserve the old live checkout untouched, and demonstrate rollback.

## Answer

The change has passed machine qualification and user-confirmed production visual acceptance. The live service configuration points to this repository's build, with a previously demonstrated byte-exact rollback. The original qualification below was performed on 2026-09-17; the 2026-09-18 audit fixes and validation are recorded in `../audit-2026-09-18.md`. The original repeatable harness under `.scratch/pi-subagent-slimming/qualify/` drives the compiled server, real Pi 0.85.1 CLI, and real Run Window.

### Build, regression, targeted compatibility

- `npm run build` is clean and `npm test` passes **154 of 154** with zero failures. The map's baseline of "136 of 140, four Windows path-separator failures" no longer applies: those four `stage-prompt` failures are gone from the tree and nothing was relaxed to get there. Both runs are captured verbatim as `qualify/_out/npm-build.txt` and `qualify/_out/npm-test.txt`, and the 10-scenario run as `qualify/_out/full-run.txt`, so the claims are shipped evidence rather than assertions.
- `surface`: exactly `pi_delegate` and `pi_status`; all five probed retired names (`pi_kill`, `pi_plan`, `pi_session_list`, `pi_task_create`, `pi_task_status`) fail with `unknown tool`; `prompt`/`session` validation and `goal_required` hold.
- `compat`: the **real 505 KB live `registry.json`** (50 sessions, v1) loads, a real Run still completes while it is loaded, and all 50 records survive the rewrite field-for-field. Continuing a legacy session hands Pi that record's `piSessionId`, observed in the Transcript launch record — the legacy `lastActive`/`msgCount`/`lastError`/`progress` shape is fully modelled, so nothing is dropped. One cosmetic honesty note: the rewrite re-serializes each record in the loader's own field order, so a textual diff of the file flags the 5 of 50 records whose original key order differed from the loader's, even though every value is identical.

### Sync return, async fallback

- `sync`: one `mode:"sync"` call returns the terminal state inside the call, comfortably under both the 240 s skill deadline and the host's 300 s ceiling. The Transcript verifies (`integrity-ok`, outcome `succeeded`, no capture error), a Run Window opens with the full `[SUCCEEDED] Pi — session — prompt — runId` title, `pi_status {openWindow:true}` focuses that same process rather than duplicating it, and reopening does not replay the sound. The creating Run correctly hands Pi no session id; the continuation Run is handed the id the registry recorded.
- `async`: dispatch returns at once with a `runId` (under 20 s), a `waitTimeoutMs: 0` call is a true pure poll, a **60 s Monitor Wait occupies its full minute and correctly reports `running`**, and the following 180 s wait collects the terminal state. The second wait started strictly after the first returned, so the waits never overlap. This is the host-proven confirmation ticket 08 could not obtain: the 60 s/180 s schedule is no longer merely inferred-safe.

### Concurrent windows, retention, capture failure

- `concurrent`: four simultaneous Runs are accepted, each gets its own live window with its own process and its own bundle, the desktop really holds four windows at once, a fifth dispatch is refused with `resource-busy`, all four transcripts verify `SUCCEEDED`, and completed windows stay open.
- `retention`: the shipped policy is seven days / 2 GiB; expired terminal bundles are trashed, a released-lease bundle is trashed, and an **active (non-terminal) bundle and a bundle leased by a live foreign process are never cleaned** — even under a zero quota. Quota evicts oldest-first, and trash past its grace window is purged.
- `timeout`: a killed Run is reported `timeout`, its terminal is `incomplete`, the live window settles to `INCOMPLETE`/`incomplete` with exactly one recorded warning-sound attempt and stays open, and nothing is auto-redispatched. Worth stating plainly, because it corrects a loose reading of the map: a SIGTERM'd Run closes its stdout pipe cleanly, so there is **no capture error** and `sawEof` is `true` — the incompleteness is carried by the terminal outcome, which both surfaces honour.
- `capture-disabled`: with unusable evidence storage (a reparse-point root) the Run still **succeeds**, `pi_status` reports the Transcript unavailable *with a reason* and `integrity: unknown` rather than claiming anything, no window is opened on nothing, no bundle leaks into the target directory, and the Run is still recorded.
- `capture-damage`: a real window marks a byte-damaged transcript `INCOMPLETE` (`sequence-gap` + `terminal-hash-mismatch`), never repairs it, keeps the surviving content visible, and never rewrites the Run's own outcome; a capture error recorded at capture time is shown in the window verbatim, not summarised.

### Two real findings, and one honest limitation

1. **Ticket 07's "the window does not pin its bundle" is right, but the race is real and transient.** The harness first failed this check: retention's atomic rename returned `EPERM` and recorded the bundle as `skipped`. Direct probing shows no file in the bundle is held open (an exclusive `r+` open succeeds on `lease.json`, `manifest.json`, `transcript.jsonl` and `viewer-state.json`), and the rename **succeeded one second later with the window still alive** — the failure lands when the viewer's per-tick rewrite of its own `viewer-state.json` is in flight. Retention's design already tolerates this (a failed rename is recorded as `skipped` and the next pass retries, 15 minutes later), so nothing leaks and nothing is lost; the scenario now models that cadence, and asserts the rename succeeds while the window is on screen, the window survives with its content, and `pi_status` then reports the evidence unavailable while the Run's outcome stands.
2. **The window's durable "source cleaned" flag is unobservable after cleanup.** The window sets it and says so in its pane and status bar, but it writes it into `viewer-state.json` — inside the very bundle that was just cleaned — so it moves to trash with it and can never be read afterwards. `pi_status` therefore reports viewer state `none`, not `cleaned`. No user-visible behaviour is wrong (the window still shows the marking, and `transcript.available: false` is honest), but the field is effectively dead as a machine-readable seam. Recorded rather than fixed: it is a viewer/server change, and this ticket's job is qualification.
3. **`pi_status.transcript.integrity` reads the durable manifest without replaying**, so post-hoc byte damage to a transcript is reported by the replaying window, not by `pi_status` — which will still say `integrity-ok` for a tampered file. That is the documented seam from ticket 07 (bounded tail read, never a full replay) and it is correct for what it claims, but the report should not be read as a tamper check.

### Cutover

`node cutover.mjs status|backup|apply|rollback` does the replacement; it refuses to apply while any Run is active (it checks both the registry and for live `pi` child processes — it correctly refused the first time, while the visual run was still in flight).

- **Backed up** to `~/.pi-subagent/cutover-backup-2026-09-17T03-39-15-032Z/`: `config.toml`, `registry.json`, and the installed skill (3 files, hashed), with a manifest recording the build's `dist/server.js` SHA-256 and git HEAD. `tasks.json` was absent and was neither read nor written.
- **Applied**: exactly one line of `~/.codex/config.toml` — the `args` of `[mcp_servers.pi-subagent]`, from `...\Documents\Codex\tools\pi-subagent\dist\server.js` to `...\Documents\AI-Projects\Code\pi-subagent\dist\server.js`. `apply` re-reads the file and asserts a one-line diff. The deferred ticket-08 item is done too: the stale installed v2 skill at `~/.skills-manager/skills/pi-subagent/` is refreshed to this repo's v3.
- **State preserved and independently re-checked**: `node cutover.mjs verify` re-reads the configuration and re-hashes everything, and all eight checks pass — the configured entry points at this repo's build, the installed skill is the repo's v3, no staging directory was left behind, the build being run is the build recorded at backup time, the legacy `tasks.json` was neither created nor written, the previously live checkout still sits at `21fe334` with its same seven modified files, and **the live `registry.json` is byte-identical to the backup**. Result: `qualify/_out/cutover-verification.json`.
- **Rollback demonstrated, not asserted.** Rolling back restored `config.toml` byte-exactly (the SHA-256 matched the backup) and all three skill files byte-exactly, and a verification run against the *configured* service then really did come back as the old 12-tool build with no Transcript and no Run Window. The cutover was then re-applied and re-verified. `apply` also refuses to run if the config has moved since the backup, and it swaps the installed skill through a staging directory so a failure cannot leave the old copy deleted; it replaces only `args[0]` and re-reads the file to prove every trailing argument survived.
- **Verified by reading the configuration, not by assumption.** `verify-configured-service.mjs` parses `[mcp_servers.pi-subagent]` out of `~/.codex/config.toml`, launches exactly that command with exactly that env (only the state paths are redirected so the live registry and legacy `tasks.json` are never touched), and checks the two-tool surface, the host's 3660 s tool timeout against the 240 s sync deadline, a real completed Run, a verified Transcript, and an opened window. It fails on the old build and passes on this one:

| | before cutover | during rollback | after cutover |
| --- | --- | --- | --- |
| Surface | 12 tools (plan/session/task/kill present) | 12 tools | **exactly `pi_delegate` + `pi_status`** |
| Real Run | completes | completes | completes |
| Transcript | ✗ none written | ✗ none written | ✓ `succeeded`, no capture error |
| Run Window | ✗ none opened | ✗ none opened | ✓ `ready` |

Evidence: `qualify/_out/*.json` per scenario, `qualify/_out/full-run.txt`, `qualify/_out/npm-build.txt`, `qualify/_out/npm-test.txt`, `qualify/_out/cutover-verification.json`, and the three `verify-configured-service.*.json` snapshots.

### Human visual gate — passed on 2026-09-18

The user explicitly confirmed “人工核验已通过” on 2026-09-18. This closes the production visual gate. The following paragraphs preserve the original 2026-09-17 handoff; their window/process hold is historical and is not asserted to remain live.

The global Codex agent instruction requires visual verification to pause for a human (the map carries the same rule), so this gate is deliberately left to a person. Three real Run Windows were left on the desktop for that purpose (a `SUCCEEDED` one carrying a multibyte glyph line, a `RUNNING` one streaming live, and an `INCOMPLETE` one), with `qualify/_out/visual-acceptance.md` naming exactly what to look at: glyph coverage for CJK/emoji/math/box-drawing/accents, complete titles, formatted-only display with no duplicate raw JSON, mid-stream continuity, distinct terminal presentation, read-only interactions — and, closing the last ticket-07 open item, whether the completion sound is actually **audible** (`alertAttemptedAt` proves the attempt is made once, never that it is heard). The rendered text each window should be showing is dumped beside the checklist for byte-level comparison. The machine-checked half of this scenario passed: all three windows opened, matched their Run ids, and produced the expected verdicts (`SUCCEEDED` integrity-ok, `RUNNING` with the expected `no-terminal-record`, `INCOMPLETE`).

A hold is live so those windows stay on screen for the inspection: `qualify/_out/visual-hold.pid`
names its process (4-hour hold, started 2026-09-17), and the checklist names the stop command.
Closing the hold closes the windows, since they are children of the MCP server.

### Honest limits

- The cutover only takes effect on the next Codex launch; the six already-running Codex sessions still hold the old server process, which is expected and harmless.
- `PI_SUBAGENT_TASKS` is left in the config: it is dead (ticket 05 retired task persistence), and changing it was out of scope for a one-line cutover. Its removal is a follow-up.
- Nothing was added to `~/.codex/skills/`: this repo's `pi-subagent` skill is not installed for Codex, only refreshed where it already was. Whether Codex should load the sync-first skill directly is a deployment decision, not a qualification one.
- Windows remain children of the MCP server, so closing the visual hold closes them; that limitation is unchanged from ticket 07.

## Comments

- 2026-09-18: User confirmed production human acceptance. Fixed the audit's session reservation, forced-pipe EOF reporting, and running status Transcript omission; added regression coverage without changing the visual UI. Ticket resolved after automated validation.

- **The harness had four bugs of its own before it qualified anything**, each caught because the assertion failed against reality rather than passing silently: a textual registry compare reported false drift; error codes are `invalid_arg`-style snake case, not hyphens; the non-overlap check measured the wrong interval; and the config parser broke on the `[mcp_servers.pi-subagent.env]` sub-table header, which hid `PI_BIN` and made the old service look like it could not spawn Pi at all. The `verify-configured-service` scenario is the one that mattered most — it turns "we cut over" into "the file, as read, launches this build and runs a Run".
- **The `window-retention` scenario is deliberately retry-based.** A single-attempt assertion would be flaky by construction, because whether the rename lands during a viewer tick is a coin flip. Modelling retention's real cadence is both stable and more faithful than asserting one attempt.
- Two ticket-07 pending items are now closed: real Pi 0.85.1 qualification (sync, async, continuation, four concurrent Runs, timeouts and damaged evidence, all through the production path) and the retention-while-open race. The third — audibility of the sound — needs ears and is in the human checklist.
- The evidence scripts live in `.scratch/.../qualify/` alongside transcript state in `%TEMP%\pi-subagent-qualify\<stamp>\`, matching how the ticket-03 prototype kept its scripts and `_out` artifacts, so the qualification can be re-run rather than believed.
