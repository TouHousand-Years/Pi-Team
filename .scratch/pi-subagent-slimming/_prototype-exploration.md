# Prototype exploration — per-Run Windows viewer (ticket 03)

- Role: Explorer SubAgent (read-only; no product files changed)
- Repo root: `C:\Users\qnhxx\Documents\AI-Projects\Code\pi-subagent`
- Baseline commit: `174cf17` (`main`)
- Ticket: `.scratch/pi-subagent-slimming/issues/03-prove-per-run-windows-viewer.md` (`Status: claimed`, blocked-by `02`, now resolved)
- Evidence inputs: `map.md`, `research/02-pi-event-surface.md`, `research/01-completion-transport.md`,
  `CONTEXT.md`, `_grilling-decisions.md`, `_proposal-delta-01.md`, `_ultra-brief.md`, and the current
  `src/` tree.
- This file is the only write from this investigation.

---

## 0. Answer first (what the smallest prototype is)

A **single throwaway PowerShell 5.1 / .NET Framework WinForms script** that runs a message loop over
**one independent `System.Windows.Forms.Form` per Run**, where each Form tails **its own append-only
NDJSON journal file** written by a **separate synthetic generator process**, and where each Form
renders a **deterministic pass-through formatter** (1 raw record → ≥1 display lines, payload always
verbatim, no truncation, no summaries, no secondary "raw" tab). Replay is just "read the journal from
byte 0 on first tick"; tail is "continue reading appended complete lines each timer tick". A shared
`System.Windows.Forms.Timer` (UI thread, bounded batch) drives all Forms. A per-Run state record keyed
by `runId` — not by Form — owns tailing, completion detection, and a one-shot `notified` flag, so
closing a window detaches only the display. Everything runs from one command.

This is the smallest construction that can directly exercise all eight required properties without
touching the MCP server, `src/`, `package.json`, or the build. The eight properties map to concrete
signals in §8.

The **production seam** this prototype stands in for is the raw process-boundary fan-out at
`src/runner/spawn.ts:51-99` (`collectOutput`) plus a per-Run append-only journal, placed **before**
the lossy `src/runner/parse.ts:17-36` classification. The prototype replaces the Pi subprocess with a
fixture generator that writes the same bytes Pi would, so the display/lifecycle mechanics can be
proven without a live model, network, or MCP host.

---

## 1. Requirement traceability

### 1.1 User-required behavior (binding; from map / grilling / ticket 03)

| # | Requirement | Source |
| --- | --- | --- |
| U1 | Exactly one independent read-only Run Window per Run, including Pi Session continuations | `map.md` Notes; `_grilling-decisions.md:10`; ticket 03 |
| U2 | Replay the whole Transcript, then tail live | ticket 03; `_proposal-delta-01.md` revised req. |
| U3 | One complete formatted event stream; no summaries, no silent truncation, no Raw-events tab; unknown events visible in a lossless representation | `map.md` Notes; `_grilling-decisions.md:16`; ticket 03 |
| U4 | Four concurrent Runs isolated | ticket 03; `map.md` Decision "Pi event-surface" |
| U5 | Responsive under high event volume and Unicode | ticket 03 |
| U6 | Closing a window affects only the display; capture, Run execution, and completion notification continue; completed windows stay open until manually closed | `map.md` Notes; `_grilling-decisions.md:15` |
| U7 | Capture failure never stops a Run; window and status mark the Transcript incomplete | `map.md` Notes; `_grilling-decisions.md:18` |
| U8 | Exactly-once completion notification | ticket 03; `_proposal-delta-01.md` req. 2/5 |
| U9 | Windows-only; PowerShell/.NET WinForms is the first prototype route; switch technology only if volume/Unicode/isolation fails | `_grilling-decisions.md:19` |
| U10 | Pause for human visual inspection | `AGENTS.md`; `map.md` Notes; `_grilling-decisions.md:11` |

### 1.2 Repository facts (observed; not user choices)

| # | Fact | Evidence |
| --- | --- | --- |
| F1 | Pi is invoked as `pi -p <prompt> --mode json` (+ optional flags) and emits one complete JSON object per stdout line | `src/runner/argv.ts:9-21`; `research/02 §2` |
| F2 | Live stdout is already available line-by-line, but the callback is used only for the session handshake and a 200-char tool summary | `src/runner/spawn.ts:63-72`; `src/tools/delegate.ts:207-256` |
| F3 | stderr is retained only as a 2 KB tail; there is **no** `onStderr` callback | `src/runner/spawn.ts:76-79,99` |
| F4 | `collectOutput` keeps all stdout lines in memory until process exit; nothing is journaled per Run | `src/runner/spawn.ts:54-59,71,95-98` |
| F5 | Parsing is deliberately lossy: only `session`, `tool_execution_end`, `agent_end` keep content; every delta/turn/message type is reduced to its `type` | `src/runner/parse.ts:17-36` |
| F6 | The displayed summary path redacts and truncates to 200 chars | `src/types.ts:15-19`; `src/registry/redact.ts:5-9` |
| F7 | Persistence stores **Sessions**, not Runs; there is no transcript file/format | `src/registry/persist.ts`; `src/types.ts:99-103` |
| F8 | The server registers 12 MCP tools and has **no** GUI/notification code | `src/server.ts:67-228`; `grep -riE "notif" src` → 0 hits |
| F9 | No GUI dependency exists in the project | `package.json` (only `@modelcontextprotocol/sdk`) |
| F10 | Windows PowerShell is 5.1.26100, .NET CLR 4.0.30319, WinForms assembly available; console apartment is already **STA** | verified by command in §11 |
| F11 | `TextBox`/`RichTextBox` programmatic `AppendText` is **not** limited by `MaxLength` (verified 100,000 chars retained even at default `MaxLength=32767`); `RichTextBox` default `MaxLength=2147483647` | verified in §11 |
| F12 | Baseline `git status --porcelain` shows only pre-existing untracked entries | `?? .scratch/`, `?? AGENTS.md`, `?? CONTEXT.md`, `?? docs/adr/`, `?? docs/agents/` |

### 1.3 Pi 0.85.1 event surface (from `research/02`, used verbatim as fixture material)

- Canonical happy-path sequence: `research/02 §4.1` (37 stdout lines, `session` → … → `agent_settled`).
- Terminal signal: last stdout event ∈ {`agent_end`, then `agent_settled`} and `signal == null`
  (`research/02 §6`).
- Duplication hazard: assistant text appears in `text_delta`, `text_end.content`,
  `message_end.message.content`, `turn_end.message.content`, `agent_end.messages[]` (`research/02 §4.1 note`).
  → The prototype must **not** implement this dedup yet (that is ticket 04 / R2–R7); it must prove
  display mechanics losslessly on a pass-through formatter and leave a named seam.
- Unknown/extra event types, malformed lines, partial trailing lines, and stderr coexist with the
  stream and must stay visible (`research/02 §5 R10/R11`, `§6`).

---

## 2. Current state and data flow (why a new seam is needed)

```
MCP host (Codex)
  └─ pi_delegate ── src/tools/delegate.ts:65 delegate()
       ├─ spawnDelegate ───────────── src/runner/argv.ts:9  buildDelegateArgs()
       ├─ collectOutput(child,{onLine}) src/runner/spawn.ts:51
       │    ├─ stdout lines ── onLine → delegate.ts:209 (handshake + 200-char summary only)
       │    ├─ stderr ──────── stderrBuf (2 KB tail)         spawn.ts:77-78
       │    └─ all lines kept in RAM until exit             spawn.ts:54-59
       └─ finalize → extractResult(lines) ─ src/runner/parse.ts:69 (lossy)
                     └─ RunRegistry.complete ─ src/registry/run.ts:60 (in-memory only)
```

Consequences established by the evidence:

1. **No real-time full-content path exists.** The one live callback is consumed by handshake/summary
   logic (`F2`); the full line array is only read after process exit (`F4`).
2. **No per-Run persistence exists.** `registry.json` holds `SessionRecord`s with redacted summaries
   and counters (`F6`, `F7`).
3. **The natural fan-out seam is `collectOutput`.** It already sees every stdout line and reads
   stderr; it lacks only an `onStderr`/record callback and a per-Run sink (`F3`, `F4`).
4. **The prototype does not need that code.** It can emit the same record stream from a fixture
   generator, which is safer, reproducible, and network-free, and keeps this ticket a pure UI
   feasibility proof. Wiring the real seam belongs to ticket 04/06.

---

## 3. Relevant modules and public interfaces

Read-only summary of every interface the production integration (tickets 04/06/07) will touch, so the
prototype's journal contract can be shaped to fit the eventual seam.

| Module | Public interface | Role for the viewer |
| --- | --- | --- |
| `src/runner/spawn.ts` | `spawnDelegate(opts)`, `collectOutput(child,{runTimeoutMs,onLine}) → CollectResult{lines,stderrTail,exitCode,signal,spawnError}` | The exact place a raw `onRecord`/`onStderr` fan-out must attach; `CollectResult` already carries terminal metadata |
| `src/runner/argv.ts` | `buildDelegateArgs(input)`, `buildForkArgs(id)` | Defines the launch metadata the Transcript must record from the parent boundary (R12) |
| `src/runner/parse.ts` | `classifyLine`, `extractResult`, `extractFinalAssistantText` | The lossy layer the journal must sit **below** |
| `src/types.ts` | `Run`, `ProgressEvent`, `Constraints`, `PI_BUILTIN_TOOLS`, `ERROR_CODES` | `Run`/`ProgressEvent` are the current summary model, not the transcript model |
| `src/registry/run.ts` | `RunRegistry.create/get/complete/appendProgress/waitForCompletion` | In-memory Run state; no bytes |
| `src/registry/persist.ts` | `loadRegistry/saveRegistry` (Session records) | Persistence shape to stay backward-compatible with |
| `src/tools/delegate.ts` | `delegate(input,deps)` | The Run lifecycle owner; hands Run identity to the window launcher in production |
| `src/server.ts` | 12 tool registrations, stdio transport | Must remain GUI-free; the viewer is a separate process |
| `src/tools/status.ts` | `status(input,runs)` long-poll 25 s | Completion notification ownership must **not** depend on this |

Prototype-facing contract that mirrors the future seam:

- **Per Run:** a stable `runId`, a launch/argv/cwd metadata record, an ordered stdout channel, an
  ordered stderr channel, and a terminal record `{status, exitCode, signal}`.
- **Monotonic ordering:** every record has a per-Run `seq` starting at 1 with no gaps.
- **Append-only, byte-preserving:** payloads are stored verbatim; the formatter never mutates the
  journal.

---

## 4. Recommended throwaway file layout and one-command launch

All files live under the already-untracked `.scratch/` tree, so **no tracked product file is
modified** and `.gitignore` needs no change.

```
.scratch/pi-subagent-slimming/prototype/
  run-prototype.ps1        # one-command orchestrator (fixture + viewer)
  fixture-generator.ps1    # writes journals + manifest.json
  per-run-window.ps1       # WinForms viewer: N Forms, replay+tail, formatter, notify
  verify-prototype.ps1     # compares viewer report.json to generator manifest.json
  _out/                    # generated: <runId>.journal.jsonl, manifest.json, report.json
```

**One-command launch (PowerShell 5.1, explicit STA):**

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
  -File ".scratch\pi-subagent-slimming\prototype\run-prototype.ps1" -Scenario all -Runs 4
```

`run-prototype.ps1` must:

1. resolve the repo root from `$PSScriptRoot\..\..\..`,
2. ensure `_out\` exists and is empty for the chosen scenario,
3. start `fixture-generator.ps1 -OutDir _out -Scenario <s> -Runs <n> -Stream` as a **separate
   process** (`Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',... -WindowStyle Hidden`),
4. wait for `manifest.json` (bounded, e.g. 10 s),
5. start `per-run-window.ps1 -FixtureDir _out -ReportPath _out\report.json`,
6. after the viewer exits, run `verify-prototype.ps1` and print the PASS/FAIL table.

Single-scenario manual launch (equivalent, two terminals):

```powershell
# terminal 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .scratch\pi-subagent-slimming\prototype\fixture-generator.ps1 -OutDir _out -Scenario volume -Runs 4 -Stream
# terminal 2
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .scratch\pi-subagent-slimming\prototype\per-run-window.ps1 -FixtureDir _out -ReportPath _out\report.json
```

`-STA` is explicit even though Windows PowerShell 5.1 already runs STA (`F10`), so the command is
robust if run from a host that is MTA.

---

## 5. Journal / fixture format (prototype contract)

One file per Run: `_out\<runId>.journal.jsonl`, UTF-8 **without BOM**, LF-terminated, append-only.
One JSON object per line:

```json
{"seq":1,"ts":1789530000000,"ch":"meta","kind":"launch","data":"pi -p \"...\" --mode json --session-id ..."}
{"seq":2,"ts":1789530000001,"ch":"stdout","data":"{\"type\":\"session\",\"version\":3,\"id\":\"...\",\"cwd\":\"...\"}"}
{"seq":3,"ts":1789530000002,"ch":"stdout","data":"{\"type\":\"agent_start\"}"}
{"seq":4,"ts":1789530000003,"ch":"stderr","data":"Could not parse message into JSON: {bad"}
{"seq":5,"ts":1789530000004,"ch":"meta","kind":"terminal","status":"completed","exitCode":0,"signal":null}
```

Rules:

- `seq`: integer, starts at 1, increments by 1, **no gaps** (gap ⇒ viewer marks the run `incomplete`).
- `ts`: generator wall-clock ms; drives latency measurement.
- `ch`: `"stdout"` | `"stderr"` | `"meta"`. Any other value is legal and rendered by the generic
  fallback (extensibility).
- `data`: verbatim string. For `stdout`, exactly one raw Pi NDJSON line (no trailing newline).
  For `stderr`, one diagnostic line/chunk. For `meta`, human-readable text or the terminal payload.
- `kind` is meaningful only for `ch:"meta"`: `"launch"` | `"terminal"` | `"captureError"`.
- A **complete** Run is: a terminal record exists with `status ∈ {completed,error,killed,timeout}`
  and `signal == null`, **and** `seq` has no gaps, **and** no `captureError` record.
- `manifest.json` (written by the generator) records per Run:
  `runId`, `journal`, `scenario`, `emittedCount`, `lastSeq`, `rawSha256` (SHA-256 over all `data`
  joined with `"\n"` in `seq` order, UTF-8), `terminal`, `uniqueSentinel`, `generatorFinishedAt`.

`rawSha256` is the **losslessness oracle**: the viewer computes the same hash over what it actually
received and the verifier requires equality.

---

## 6. Fixture / event generator specification

`fixture-generator.ps1` parameters:

| Param | Default | Meaning |
| --- | --- | --- |
| `-OutDir` | required | output directory |
| `-Scenario` | `all` | `happy` \| `volume` \| `unicode` \| `isolation` \| `closure` \| `windowfail` \| `capturefail` \| `duplicate` \| `all` |
| `-Runs` | `4` | number of journals for `isolation`/`all` |
| `-Stream` | off | pace emission (`Start-Sleep -Milliseconds 5` every record) to force visible tailing; off = as fast as possible |
| `-Rate` | `0` | records/second cap for `volume`; `0` = unbounded |
| `-VolumeEvents` | `50000` | count of synthetic delta records |
| `-Seed` | `0` | deterministic content seed |

Per-scenario content (all `stdout` payloads must be literal JSON matching `research/02 §4.1` shapes):

- **happy** — the full 37-line canonical sequence of `research/02 §4.1`, re-emitted verbatim as
  `ch:"stdout"` records; one `stderr` diagnostic inserted after `message_end` to exercise the second
  channel; a `meta` `launch` record first; a `meta` `terminal {status:"completed",exitCode:0}` last.
- **volume** — 1 Run; `session`, `agent_start`, `turn_start`, `message_start`, then
  `-VolumeEvents` `message_update`/`text_delta` records whose `delta` is ~120 deterministic ASCII
  chars, then `text_end`, `message_end`, `turn_end`, `agent_end`, `agent_settled`, terminal.
  This is the responsiveness/throughput fixture.
- **unicode** — 1 Run; the same envelope but each text payload contains a fixed torture string:
  `中文 日本語 한국어`, emoji with ZWJ and surrogate pairs `😀🎉👨‍👩‍👧‍👦`, combining marks
  `e\u0301 a\u0300`, RTL `مرحبا שלום`, astral math `𝔘𝔫𝔦𝔠𝔬𝔡𝔢`, and literal backslash/quote
  `\\ "`. Emitted enough times to exceed 40,000 chars.
- **isolation** — `-Runs` Runs; each emits a unique `RUN-SENTINEL-<n>` inside a `tool_execution_end`
  result text and otherwise distinct content; all complete.
- **closure** — like `happy` but paced (`-Stream`) so a window can be closed mid-stream; generator
  must finish and write terminal **regardless of viewer state**.
- **windowfail** — like `isolation`, plus the generator writes `_out\force-display-error.txt`
  containing one `runId`; the viewer must throw once while formatting that Run's records and recover.
- **capturefail** — 1 Run; writes 10 records, then a `meta {kind:"captureError", message:"simulated capture failure"}`
  record, then exits **without** a terminal record.
- **duplicate** — 1 Run that writes the terminal record **twice** with different `seq`.
- **all** — runs `happy`, `volume`, `unicode`, `isolation` (4 Runs), `closure`, `windowfail`,
  `capturefail`, `duplicate` in one `_out` directory (one journal per Run; the verifier selects by
  `manifest.json`).

Generator requirements: deterministic output for a given `-Seed`; flush after every line; never hold
a lock that the viewer cannot read; write `manifest.json` only after all journals are complete.

---

## 7. Viewer specification (`per-run-window.ps1`)

### 7.1 Process and threading model

- One process, one `[System.Windows.Forms.Application]::EnableVisualStyles()`, one
  `[System.Windows.Forms.Timer]` with `Interval = $TickMs` (default 50).
- All Forms and all file reads happen on the **UI/STA thread**; no cross-thread marshaling is needed.
  This is intentional: the timer tick is bounded (`-BatchLines`, default 500 records per Run per
  tick) so a large backlog is drained across ticks instead of freezing paint.
- `Application::Run()` (no main form) with a `$openForms` counter; when the last Form closes, write
  `report.json` and call `Application::Exit()`.

### 7.2 Per-Run state (keyed by `runId`, **not** by Form)

```powershell
@{ runId; journal; reader; offset; pending; seqExpected=1; rawSb; renderedCount=0;
   replayedCount=0; tailedCount=0; startedAt; lastRecordTs; maxLatencyMs; latencySamples=@();
   terminal=$false; status=$null; captureError=$false; incomplete=$false; displayError=$null;
   notified=$false; form=$null; pinnedAutoscroll=$true; receivedOrderOk=$true; rawSha256 }
```

Closing a Form sets `state.form = $null` and decrements `$openForms`; **tailing, completion
detection, and notification keep running** because they read `state`, not the Form.

### 7.3 Form construction (one per Run)

- `Form.Text = "Run <first 8 of runId> — <status>"` (status suffix updated on terminal/incomplete).
- Body: `RichTextBox` with `Dock=Fill`, `ReadOnly=$true`, `WordWrap=$false`,
  `ScrollBars=Both`, `MaxLength=0`, `DetectUrls=$false`, `Font=Consolas 9` (see §10 font caveat),
  `BackColor` and `ForeColor` fixed (dark-on-light) so Unicode is legible.
- Footer: `StatusStrip`/`Label` showing `seq <n>/<total-if-known>` `raw <bytes>` `lat <ms>`
  `last <type>` `replay <n>` `tail <n>`.
- Read-only is enforced structurally: no buttons, no editable controls, no context menu that writes.
- Completed Forms are **never auto-closed**; only the user closes them (U6).

### 7.4 Replay + tail loop (per tick, per Run)

1. If `state.reader` is null, open the journal, seek 0 → this is the **replay** phase.
2. Read available text; split on `\n`; keep the trailing fragment in `state.pending`.
3. For each complete line (bounded by `-BatchLines`): JSON-parse best-effort; call `Format-Record`;
   append the result to `state.rawSb`/display and increment `renderedCount`. While `offset` is before
   the file size recorded at viewer start, count as `replayedCount`; after, `tailedCount`.
4. On the first tick after open, also render any `state.pending` from a previous partial line **only**
   at terminal, flagged `[partial]` (R11).
5. If the file is missing or a read throws, set `state.captureError=$true`, `state.incomplete=$true`,
   keep already-rendered text, set the title suffix `[incomplete]`, and continue the other Runs.

### 7.5 `Format-Record` (pass-through formatter; lossless, formatted, no dedup)

`Format-Record($rec) → [string[]]`. Every branch prints the **verbatim** payload somewhere; this is
the ticket-03 "complete formatted stream without summaries or silent truncation" requirement.
Deduplication of assistant text (research/02 R2–R7) is explicitly **out of scope** here and is
delegated to ticket 04; the function must carry a comment naming that seam.

| `ch` / parsed `type` | Display lines (payload always verbatim) |
| --- | --- |
| `meta` `launch` | `• launch: <data>` |
| `meta` `terminal` | `• terminal status=<status> exit=<exitCode> signal=<signal>` |
| `meta` `captureError` | `!! capture error: <data>` |
| `meta` other / unknown `kind` | `• <kind>: <data>` |
| `stderr` | `! stderr: <data>` |
| `stdout` `session` | `── session id=<id> v=<version> cwd=<cwd>` |
| `stdout` `agent_start` / `agent_settled` / `turn_start` | `── <type>` |
| `stdout` `message_start` / `message_end` | `── <type> role=<role>` + every content block verbatim |
| `stdout` `message_update` | `   <assistantMessageEvent.type> <delta|content|toolCall, verbatim>` |
| `stdout` `tool_execution_start` / `_update` / `_end` | `── <type> tool=<toolName> …` + verbatim result text |
| `stdout` `turn_end` / `agent_end` | `── <type> stopReason=… usage=… messages=<n>` + verbatim content |
| `stdout` unknown `type` | `? [event <type>] <raw line>` |
| unparseable stdout line | `? [unparsed stdout] <raw line>` |
| unknown `ch` | `? [channel <ch>] <data>` |

No line is ever elided with `…`; ellipses above are documentation shorthand only. Every branch ends
with (or contains) the original `data`.

### 7.6 Completion detection and exactly-once notification

- A Run becomes **complete** on the first `meta`/`kind:"terminal"` record with `signal == null` and
  no gap and no earlier `captureError`; otherwise it becomes **incomplete**.
- On the first completion only: set `state.terminal=$true`, `state.status=<status>`; if
  `-not $state.notified`, set `$state.notified=$true`, append `runId` to `$notifications`, and raise
  **one** non-modal notification. Duplicate terminal records and replay of an already-terminal
  journal therefore produce exactly one notification per Run per viewer process (U8).
- **Incomplete runs do not emit a completion notification** (they are not completions); they get the
  title suffix `[incomplete]` and a `report.json` entry (U7).
- Notification surface (smallest dependency-free option): a borderless `TopMost` `Form` with a
  `Label` `Run <id> completed (<status>)` that auto-closes after `-NotifyMs` (default 5000) and does
  **not** block the message loop. (`NotifyIcon.ShowBalloonTip` is the documented alternative but
  needs an icon and a tray lifetime; the topmost Form is easier to verify and to script.)
- The notification is owned by the `runId` state, so closing the Run's window before completion does
  not suppress it (U6).

### 7.7 Failure isolation

- **Window/display failure:** wrap each Run's tick in `try/catch`. On throw set
  `state.displayError`, set the title suffix `[display error]`, append `?? display error: <msg>` to
  the display, and continue to the next Run. One broken Run must not stop the timer or the other
  Forms.
- **Capture failure:** on missing/unreadable journal or a `captureError` record, mark incomplete (as
  above). The viewer never writes to the generator's files and never kills the generator.
- **Generator survival:** the generator MUST complete all its writes and `manifest.json` even if the
  viewer is killed; the verifier asserts `generatorFinishedAt` and `manifest.rawSha256` for that Run
  regardless of viewer survival. This is the "capture/Run does not depend on the GUI" proof.

### 7.8 `report.json` (machine-readable output)

```json
{
  "startedAt": 0, "endedAt": 0, "tickMs": 50, "batchLines": 500,
  "notifications": ["<runId>"], "notificationCounts": {"<runId>": 1},
  "runs": [{
    "runId":"...", "scenario":"volume", "replayedCount":0, "tailedCount":0,
    "renderedCount":0, "lastSeq":0, "receivedOrderOk":true, "rawSha256":"...",
    "textLength":0, "terminal":true, "status":"completed", "incomplete":false,
    "captureError":false, "displayError":null, "notified":true,
    "maxLatencyMs":0, "p95LatencyMs":0, "maxHeartbeatGapMs":0, "formDetached":false
  }]
}
```

`maxHeartbeatGapMs` comes from a second counter in the same timer callback (or a dedicated 100 ms
timer) that records the delta between consecutive UI ticks; a blocking tick shows up as a large gap.

### 7.9 Self-test mode

`per-run-window.ps1 -SelfTest` creates a `RichTextBox`, appends a known Unicode torture string
(>40,000 chars, including the §6 unicode set), and asserts `$rtb.Text -ceq $expected` and
`$rtb.Text.Length -eq $expected.Length`; then disposes it and prints `SELFTEST PASS`/`FAIL`. This
proves control-level Unicode round-trip and no programmatic truncation without `Application.Run`
(no visible window). It is the automated complement to the font-glyph visual check.

---

## 8. Measurable signals (requirement → signal → pass criterion)

| Requirement | Signal (where) | Pass criterion |
| --- | --- | --- |
| U1 one window per Run | `report.json.runs[].runId` count and Form count | one Form per journal; each title contains its own `runId` |
| U2 replay + tail | `replayedCount`, `tailedCount` | `replayedCount > 0` and `tailedCount > 0` for paced scenarios; `replayedCount + tailedCount == emittedCount` |
| U3 lossless / complete | `rawSha256 == manifest.rawSha256`, `renderedCount == emittedCount`, `lastSeq == manifest.lastSeq`, `receivedOrderOk` | all equal/true; plus §7.9 self-test PASS; plus human check that unknown/malformed lines are visible |
| U4 four-window isolation | verifier sentinel matrix over `report.json` + per-Form `Text` scan | each `RUN-SENTINEL-<n>` appears in exactly its own Run and in no other Run |
| U5 responsiveness (volume) | `maxHeartbeatGapMs`, `maxLatencyMs`, `p95LatencyMs`, `renderedCount` | `renderedCount == 50000`; `maxHeartbeatGapMs < 500`; `p95LatencyMs < 2000`; `maxLatencyMs < 8000` (adapt only with a documented reason) |
| U5 Unicode | §7.9 self-test; `rawSha256` for the unicode Run | self-test PASS and hash equal; human confirms glyphs render (no tofu) |
| U6 display-only close | `report.json.runs[k].formDetached == true` **and** `rawSha256` complete **and** `notified == true`; other Runs unaffected | detached Run still complete/notified; `notifications` count unchanged for others |
| U7 capture failure | `capturefail` Run: `captureError == true`, `incomplete == true`, `terminal == false`, `notified == false`; generator manifest still `generatorFinishedAt` set | viewer never crashed (process exit 0), already-rendered text preserved, no completion notification |
| U8 exactly-once | `duplicate` Run: `notificationCounts[runId] == 1`; `closure` replay Run likewise | exactly one notification per Run per viewer process |
| U9 technology | environment commands in §11 | PowerShell 5.1 + WinForms load succeeds; no third-party package added |
| U10 human pause | visual inspection step in §9 | worker stops and waits for the human verdict before any production work |

Latency is `renderedAt - rec.ts` measured in the tick that renders the record. Thresholds are the
prototype's chosen proxies for the unspecified phrase "responsive under high event volume"; they are
recorded here as **decisions, not repository facts**, and may be tuned once, with the new value and
reason written into `report.json`.

---

## 9. Human visual inspection script (mandatory pause)

Run `-Scenario all -Runs 4`. The human must observe and answer:

1. Four windows open independently and can be moved/resized/minimized without affecting each other.
2. Opening a window mid-stream shows the earlier events immediately (replay), then visibly grows
   (tail).
3. Every event is visible as formatted text; an intentionally unknown event, a malformed line, and a
   stderr line are all present; nothing says "…truncated".
4. Chinese/Japanese/Korean, emoji, combining marks, and RTL text are legible (flag any tofu).
5. Closing the active window does not stop the other windows or the tail; the completion notification
   for the closed Run still appears; a completed window stays open until closed by hand.
6. The `capturefail` Run shows an explicit incomplete marker and produces no completion notification.
7. Notification banners appear once per completed Run (not repeatedly).

The worker records the verdict in the ticket and does not proceed until the human responds.

---

## 10. Ambiguities and decisions the ticket must resolve

These are genuinely unspecified; each needs an explicit answer before implementation.

1. **Formatter dedup scope.** Ticket 03 says "complete formatted event stream"; research/02 R2–R7
   require assembling assistant text from deltas to avoid 5× duplication. Does the prototype
   implement R2–R7, or is a pass-through formatter sufficient for the display-mechanics proof?
   *Recommendation (this report): pass-through for ticket 03; name the R2–R7 seam in a comment; lock
   dedup in ticket 04.* This is the single largest ambiguity.
2. **Notification channel.** Topmost auto-close Form vs. `NotifyIcon` balloon vs. taskbar flash vs.
   OS toast. User only requires exactly-once; the channel is unspecified. *Recommendation: topmost
   Form for scriptability; note the production channel is a ticket-04/07 decision.*
3. **"Exactly once" scope.** Once per Run per viewer process is the prototype's contract. Global
   (persisted across viewer restarts) is unspecified and not required.
4. **Volume/latency budgets.** "Responsive under high event volume" has no number. The §8 thresholds
   (50,000 events; <500 ms heartbeat gap; p95 <2 s) are proposed defaults.
5. **Journal schema ownership.** The §5 record shape is a prototype convention. Ticket 04 owns the
   production Transcript schema; the prototype must not be treated as locking it.
6. **Font/glyph coverage.** Consolas lacks CJK/emoji; WinForms GDI fallback may render some as boxes.
   Programmatic round-trip is proven by hash; glyph rendering is a visual check. A mixed-coverage
   font (e.g. `Microsoft YaHei UI` or `Segoe UI`) may be needed; flag to the human.
7. **Launch protocol.** The prototype runs all windows in one process. Production may launch one
   viewer process per Run or one shared host process; that is ticket 04/07 and must not be inferred
   from the prototype.
8. **Real-Pi vs synthetic fixtures.** The prototype proves display/lifecycle on synthetic journals.
   Real-Pi end-to-end validation (including the delta-only 0.85.1 wire format and the stale
   `test/fixtures/pi-output-echo.jsonl`, research/02 §7) remains ticket 04/06.
9. **TextBox vs RichTextBox.** RichTextBox is chosen for coloring/formatting freedom; if
   high-volume performance or glyph fallback proves poor, switching to a monochrome multiline
   `TextBox` is the documented fallback (both verified to retain >100k appended chars, `F11`).

---

## 11. Verification and product-state safety (this investigation)

Commands actually run (read-only unless noted):

```powershell
# environment / feasibility (no window shown: no Show(), no Application.Run)
powershell -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
# → 5.1.26100.7705
powershell -NoProfile -Command '[System.Environment]::Version.ToString(); Add-Type -AssemblyName System.Windows.Forms; "WinForms: available"'
# → 4.0.30319.42000 ; WinForms: available
powershell -NoProfile -Command '[System.Threading.Thread]::CurrentThread.GetApartmentState().ToString()'
# → STA
powershell -NoProfile -Command 'Add-Type -AssemblyName System.Windows.Forms; $tb=New-Object System.Windows.Forms.TextBox; $tb.Multiline=$true; $tb.MaxLength=0; $tb.AppendText("x"*100000); $tb.Text.Length'
# → 100000  (and RichTextBox default MaxLength → 2147483647)
```

```bash
node --version          # v24.19.0
git rev-parse HEAD      # 174cf17...
git status --porcelain
# ?? .scratch/  ?? AGENTS.md  ?? CONTEXT.md  ?? docs/adr/  ?? docs/agents/
git ls-files .scratch   # (empty) — .scratch is entirely untracked
```

Safety statement:

- No product file, test, config, registry, `dist/`, or live checkout was modified.
- The report is the only file written, at the declared path.
- The prototype's recommended location (`.scratch/pi-subagent-slimming/prototype/`) is inside the
  already-untracked `.scratch/` tree, so the "safe" expected `git status` after implementation is
  **identical to the baseline** (`?? .scratch/` plus the four pre-existing untracked paths, no ` M `
  lines and an empty `git diff --stat`).
- No GUI window was launched and no network was used. WinForms was only loaded and controls created
  in memory to read defaults; `Show()` and `Application.Run()` were never called.

Post-implementation check the worker must run:

```powershell
git -C "C:\Users\qnhxx\Documents\AI-Projects\Code\pi-subagent" status --porcelain
git -C "C:\Users\qnhxx\Documents\AI-Projects\Code\pi-subagent" diff --stat
```

Expected: the same five untracked entries and no tracked modifications.

---

## 12. Evidence map

**Prototype source of truth**
- Ticket: `.scratch/pi-subagent-slimming/issues/03-prove-per-run-windows-viewer.md` (all eight properties)
- Design decisions: `.scratch/pi-subagent-slimming/_grilling-decisions.md:10-19`
- Requirements: `.scratch/pi-subagent-slimming/_proposal-delta-01.md` (revised requirements 1–5),
  `.scratch/pi-subagent-slimming/_ultra-brief.md` (success criteria 5–7, unknowns 4–6)
- Map: `.scratch/pi-subagent-slimming/map.md` (Destination, Notes, Decisions so far, Out of scope)
- Vocabulary: `CONTEXT.md` (Run, Run Window, Transcript, Monitor Wait)
- Human pause rule: `AGENTS.md`

**Pi event surface / formatting rules**
- `research/02-pi-event-surface.md`: §3 coverage matrix, §4.1 canonical 37-line sequence, §4.2
  shared-partial hazard, §4.3–4.5 failures, §5 R0–R12 dedup/format rules, §6 completeness rule, §7
  conflicts (stale fixture; lossy parse; redaction), §8 unknowns.
- Completion/terminal semantics: `research/01-completion-transport.md` (sync 300 s host cap is
  orthogonal to the viewer but confirms notification ownership must not depend on the MCP call).

**Current implementation (read-only)**
- `src/runner/spawn.ts:40-99` — `CollectResult`, `collectOutput`, `onLine`, stderr 2 KB tail, no
  `onStderr`, in-memory lines.
- `src/runner/argv.ts:9-26` — `buildDelegateArgs` / `buildForkArgs` (launch metadata).
- `src/runner/parse.ts:17-36,69-88` — lossy `classifyLine` / `extractResult`.
- `src/tools/delegate.ts:207-256` — the only live `onLine` consumer (handshake + 200-char summary).
- `src/tools/status.ts:38-46` — long-poll default 25 s.
- `src/types.ts:12-19,99-103` — `PI_BUILTIN_TOOLS`, redacted `ProgressEvent`, Session-only persistence.
- `src/registry/persist.ts` — Session persistence; no Run transcript.
- `src/server.ts:67-228` — 12 tools; no notification; stdio transport.
- `package.json` — only `@modelcontextprotocol/sdk`; no GUI dependency.
- `test/fixtures/fake-pi.sh`, `test/helpers.ts` — existing fake-Pi NDJSON precedent (reusable shape).

**Repository facts verified by command**
- PowerShell 5.1 / .NET 4.0 / WinForms available / STA (F10).
- Programmatic `AppendText` not limited by `MaxLength`; `RichTextBox.MaxLength=2147483647` (F11).
- Baseline `git status` and empty `git ls-files .scratch` (F12).

**Not established (evidence gaps)**
- No measurement exists yet for WinForms behavior at the chosen 50,000-event target, four concurrent
  Forms, or mixed-script glyph coverage. That is exactly what this prototype is for; §8 thresholds are
  proposed, not observed.
- No production launch protocol, Transcript schema, notification channel, or dedup implementation is
  decided by this report (tickets 04/06/07).
