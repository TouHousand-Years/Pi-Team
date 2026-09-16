# Exploration 04 — Transcript-to-Run-Window seam

Read-only Explorer report for ticket `04-fix-transcript-window-seam`.
Evidence boundary: working tree + HEAD `174cf17087b3f349cce7fe11928a1dccfd7b5886` ("fix: MCP 启动路径改用编译产物，修正安装文档 (#2)"); `CONTEXT.md`; `docs/adr/`; `docs/agents/`; `.scratch/pi-subagent-slimming/{map.md,_grilling-decisions.md,research/01,research/02,_prototype-exploration.md,issues/01-07,prototype/*,_out/*}`. No product file, ticket, map, prototype script, or config was modified; this file is the only write.

---

## Direct answer

There is **no production Transcript today**. The two halves of the seam both exist but are unwired and lossy:

1. **Capture half** — `collectOutput` (`src/runner/spawn.ts:49-99`) is the only code that sees every stdout line and stderr byte. It exposes only `onLine`, keeps all lines in RAM, keeps only a 2 KB stderr tail, and has no `onStderr`. This is the exact fan-out point the prototype's append-only journal stands in for (`_prototype-exploration.md:30-32,106`).
2. **Lifecycle half** — `delegate()`'s `finalize` (`src/tools/delegate.ts:114-205`) is the only Run-lifecycle owner; it consumes `res.lines` after process exit via the lossy `extractResult` (`src/runner/parse.ts:69-84`) and calls `runs.complete`. `RunRegistry` is in-memory with a 128-completed cap and an **uncalled** 24 h TTL (`src/registry/run.ts:30-31,113,126`).

To lock the seam before implementation, ticket 04 must freeze six contracts. Everything below is organized by the ticket's six required tracks.

---

## Track A — Module / data ownership

**Facts**

- Raw process boundary: `collectOutput(child, {runTimeoutMs, onLine}) → {lines, stderrTail, exitCode, signal, spawnError}` (`src/runner/spawn.ts:49-99`). stdout is split on `\n` and each complete line fires `onLine` (`:64-74`); at exit a trailing fragment is flushed (`:95-98`). stderr is buffered only as a 2 KB tail, no callback (`:76-79,99`). All stdout lines stay in the returned `lines` array in memory until exit.
- The single current consumer of `onLine` is `delegate` (`src/tools/delegate.ts:207-256`). It uses the callback for exactly two things: the `session` handshake (`:209-225`) and a 200-char redacted progress summary (`:248`, via `parse.ts:78`).
- Lossy semantic layer: `classifyLine` keeps content only for `session`, `tool_execution_end`, `agent_end`; all other event types collapse to `{type}` (`src/runner/parse.ts:17-36`). `extractResult` returns `{result, progress, usage}` and caps progress at 200 (`parse.ts:69-84`; `src/registry/run.ts:89`).
- Run identity/lifecycle owner: `src/tools/delegate.ts`; in-memory state: `RunRegistry` (`src/registry/run.ts`), `SessionRegistry` (`src/registry/session.ts`). Session persistence: `src/registry/persist.ts`. Task persistence: `src/registry/task-persist.ts`. Server wiring: `src/server.ts` (`REGISTRY_PATH`/`TASKS_PATH` at `:20-33`, 12 tools at `:246-296`).
- The prototype's journal is the candidate production schema (`_prototype-exploration.md:188-211`; `prototype/fixture-generator.ps1:143-226`): one append-only `<runId>.journal.jsonl` per Run, UTF-8 no BOM, records `{seq, ts, ch, kind?, data, ...extras}` where `ch ∈ {stdout,stderr,meta}` and `kind ∈ {launch,terminal,captureError}` (only when `ch="meta"`). `seq` starts at 1 and is contiguous; `rawSha256` is over every record's `data` joined with LF (`fixture-generator.ps1:217-225`).
- Required-but-absent parent-boundary metadata: the submitted prompt/argv is only reconstructible from `buildDelegateArgs` (`src/runner/argv.ts`); the prototype records it as the `meta`/`launch` record (`fixture-generator.ps1:178-185`). R12 requires the Transcript to preserve submitted input (`research/02:343`).

**Supported inference** — Ownership must be a new `Transcript` writer owned by the capture seam (attached at `spawn.ts:51-99`), not a field on `Run`/`SessionRecord`, because `RunRegistry` is bounded and volatile and `persist.ts` persists only redacted Session summaries. `Run` keeps the *pointer/status*; the Transcript file is the content authority.

**Unknown** — Whether production keeps the prototype's `meta` wrapper envelope (seq/ts/ch/kind/data) as the frozen on-disk schema, or separates "raw wire bytes" from "display records". The prototype is explicitly a convention, not a locked schema (`_prototype-exploration.md:279,316`; ticket 04 question names "exact append-only Transcript schema" as the first thing to lock).

---

## Track B — Process / capture lifecycle and concurrency

**Facts**

- One delegate call spawns one Pi child via `spawnDelegate` and wraps it in `collectOutput` (`src/tools/delegate.ts:207`). Concurrency is capped at 4 (`MAX_CONCURRENCY=4`, `:10,82`), throwing `resource_busy`.
- Timeouts/kills: `runTimeoutMs` default 600 000 ms → SIGTERM then SIGKILL after 5 s (`delegate.ts:86`; `spawn.ts:112-119`). Stall watchdog default 300 000 ms → `markStalledKill` (`delegate.ts:271-280`). Manual kill tracked via `markManualKill`/`manualKills` (`delegate.ts:16,258`). `ProcessTable` SIGTERMs children on server exit (`src/runner/process-table.ts`; `server.ts:324-335`).
- Two run modes: `async` (default at HEAD, `delegate.ts:84`) returns after handshake and finalizes in the background (`:310-311`); `sync` blocks on `finalize` (`:319-320`). The live checkout at `C:\Users\qnhxx\Documents\Codex\tools\pi-subagent` differs from the repo (research/01 finding; `_exploration.md`).
- Completion semantics in production are *content-based*: complete ⇔ last stdout event is `agent_end` followed by `agent_settled` and `signal == null` (`research/02:367`).
- Prototype completion semantics are *envelope-based*: complete ⇔ a `meta`/`terminal` record with `signal == null` arrived, every `seq` 1..N was seen in order, and no `captureError` preceded it (`_prototype-exploration.md:338-345`; `per-run-window.ps1:1188-1218`; verifier `verify-prototype.ps1:521-522`).
- Prototype concurrency model: one viewer process, one `System.Windows.Forms.Timer` tick (`per-run-window.ps1:1610-1625`), one `Form` + state per Run discovered by scanning the fixture dir (`Invoke-Tick` / `Discover-Runs`); a shared per-tick wall-clock budget with rotation so one large journal cannot starve others (`per-run-window.ps1:1385-1400`). Latency/heartbeat are measured against a 50 ms tick (`report.json` `tickMs`).

**Supported inference** — Ticket 04 must define whether Pi's own `agent_end`/`agent_settled` is the completeness authority or whether the wrapper's `terminal` record is. The prototype's `terminal` record is written by the *generator/wrapper*, not by Pi (`fixture-generator.ps1:194-201`), so the two authorities coincide only if production synthesizes the terminal record itself and treats the Pi stdout tail as the cross-check.

**Conflict** — `research/02:367` says completeness is a Pi stdout event; `_prototype-exploration.md:338-345` says it is the wrapper `terminal` meta record. These are two different oracles and both are cited as accepted.

---

## Track C — Formatting / window launch boundary

**Facts**

- Prototype formatting is a **pass-through, lossless display adapter** applied per raw record before the window: `Format-Record` (`per-run-window.ps1:1044-1164`) renders `meta`/`launch`, `meta`/`terminal`, `meta`/`captureError`, and stdout/stderr; unknown/malformed records fall back to raw + `[partial unparsed tail]` rather than dropping (`:1344-1352`).
- Dedup/assembly rules R2–R7 are the hard part of the formatter: single content authority per assistant message, `message_start` is a marker, tool results from `tool_execution_end`, tool calls rendered once, `turn_end`/`agent_end` are structural markers, `usage` printed once (`research/02:302-327`). Unknown types never dropped (R10, `:336`).
- Launch boundary is a **separate process**, not a thread: `run-prototype.ps1` starts a hidden generator, waits for `gate.ready`, launches `per-run-window.ps1` while journals are still appending; the viewer opens every journal and writes `gate.go` (`run-prototype.ps1:1-16,183-241`). This is the "replay then tail" protocol the window must implement.
- The viewer opens a window **before** the generator finishes; verifier requires `replayedCount > 0` and `tailedCount > 0` (`verify-prototype.ps1:13,362-376`).
- Window title must start with `Run <full-runId> - ` (`verify-prototype.ps1:515-518`). Completed windows stay open until manually closed; `formDetached` records whether the user closed a window while the Run continued (`per-run-window.ps1:1440`; U6 at `_prototype-exploration.md:49`).
- No GUI/notification code exists in production: `grep -riE "notif" src` → 0 hits; 12 MCP tools registered (`server.ts:246-296`). GUI failure isolation is prototyped but not implemented (`_prototype-exploration.md:51,286`; `report.json` `displayError` on `windowfail-0001`).

**Supported inference** — The formatter is a production adapter boundary that must live *above* the Transcript and *below* the window. It must be a pure function from raw record → display lines so the window can be headless-tested. The prototype names this seam explicitly (`_prototype-exploration.md:80,316`).

**Unknown** — Whether production launches one viewer process per Run or one shared host process that owns many windows. The prototype tests one process with many forms (`per-run-window.ps1:1385-1400`) but ticket 07's wording says "one independent read-only formatted window for every Run". This is a top prototype ambiguity (`_prototype-exploration.md:10`).

---

## Track D — Incomplete capture and notification ownership

**Facts**

- Prototype: `captureError` is a `meta` record (`fixture-generator.ps1:203-207`). On seeing it the viewer sets `state.captureError = true` and never sets `terminal` (`per-run-window.ps1:1205-1208`). A terminal record with `signal != null` also means incomplete. Incomplete ⇒ **no notification** (`per-run-window.ps1:1209-1218`; verifier `:521-522`).
- The retained artifact confirms this: `capturefail-0001` has `terminal:false, captureError:true, incomplete:true, notified:false`; `dupnotify` fires exactly once (`notificationCounts` all `1`); `windowfail-0001` has `displayError` set yet `terminal:true, notified:true` (`.scratch/.../prototype/_out/report.json`).
- `Notify-Completion` is one-shot per Run keyed on `state.notified`, and notification is a separate WinForms toast, not the window (`per-run-window.ps1:1267-1311`).
- Production has **no notification path at all**. `pi_status` long-polls at 25 000 ms (`src/tools/status.ts:38-45`) and must not own notification (`_prototype-exploration.md:129`).
- The prototype header comment says a `captureError` triggers the completion notification, but the code does the opposite (`per-run-window.ps1:45-49` vs `:1205-1218`). The ticket/map decision is "capture failure is incomplete, without notification."

**Supported inference** — Notification must be owned by per-Run state created at launch (before any window), keyed by `runId`, firing once on the *valid* completion predicate, and independent of both the window lifetime and `pi_status`. The prototype's `notified` flag is the working reference.

**Conflict** — Header comment vs code in `per-run-window.ps1` (notify-on-capture-error). Code + verifier + retained report all say no-notify; treat the comment as stale.

---

## Track E — Retention / registry compatibility

**Facts**

- Production in-memory retention: `RunRegistry` caps completed Runs at 128 with FIFO eviction on complete (`src/registry/run.ts:30,75-76,126-133`) and defines `cleanupExpired()` with a 24 h TTL (`:31,113-124`) that has **no production caller** — only `test/run-registry.test.ts:53` calls it. So TTL cleanup is effectively dead code today.
- Session persistence: `registry.json` is `{version:1, sessions:[...]}` written atomically via temp+rename with a serialized write chain (`src/registry/persist.ts:6,9-27`); on load it backs up corrupt files (`:49`), revalidates each record (`:66-92`), and rewrites `running → error` because the process is gone (`:92-93`). `runId` is deliberately dropped on disk (`:9`). `SessionRegistry.snapshot` omits `piSessionId` (`src/registry/session.ts`).
- Redaction is in the only content channel today: `redact()` masks token-like secrets and truncates to 200 chars (`src/registry/redact.ts:5`), applied only in `parse.ts:78`. Progress caps: 200 in `Run`, 50 in `SessionRecord` (`run.ts:89`; `session.ts:4,71`).
- Task persistence `tasks.json` is a separate atomic path (`task-persist.ts`); the map's decision is to leave existing `tasks.json` untouched/unused after the core is reduced (ticket 05 removes task machinery).
- Ticket 06 requires "seven-day/2-GiB cleanup" of completed transcripts and "backward-compatible registry reading"; ticket 04 must lock where that cleanup attaches and how it coexists with `RunRegistry` eviction.
- Migration cutover constraint: the live installed checkout differs from the repo and defaults to `sync`; the accepted path is replacing `dist/server.js` (research/01; `_exploration.md`).

**Supported inference** — Transcript retention (7 d / 2 GiB, completed-only, oldest-first, never touch active Runs) is a new sweep that must not reuse `RunRegistry.cleanupExpired` (wrong key, wrong units, uncalled). `registry.json` must remain readable at `version:1` unchanged; the `Run`↔Transcript link should be by `runId` (a field already dropped on disk, so the link must be derivable, not persisted in `registry.json`).

**Evidence gap** — No production design exists for who runs the retention sweep, on what trigger (startup / on-complete / timer), or how the 2 GiB budget is measured across many journals. Not decided in map/tickets.

---

## Track F — Tests and migration seams

**Facts**

- Existing tests: `test/spawn.test.ts` (`collectOutput` line/stderr/kill), `parse.test.ts`, `run-registry.test.ts`, `persist.test.ts`, `status.test.ts`, `delegate.test.ts` (async/sync, handshake, `resource_busy`, `goal_required`, `cwd_invalid`, `session_create_failed`, `onSessionChange` hook), `integration.test.ts`.
- Fixture harness: `test/helpers.ts` (`fakePiEnv`, `tmpCwd`, `withEnv`) drives `test/fixtures/fake-pi.sh`, whose modes only emit `session`, `turn_start`, `tool_execution_end`, `agent_end` (`fake-pi.sh:7-56`). **No streaming deltas, no `agent_settled`, no stderr-heavy, no capture-failure mode.**
- `test/fixtures/pi-output-echo.jsonl` is stale: it contains `partial`/`message` fields Pi 0.85.1 no longer emits (`research/02:40-42,381`); `parse.test.ts` still consumes it.
- There are **zero** tests for: transcript journaling, seq-gap detection, partial-line handling, formatter assembly (R2–R7), window launch/replay, notification exactly-once, GUI-failure isolation, or retention.
- Prototype verification is a full oracle: `verify-prototype.ps1` recomputes `rawSha256`, checks `seq` contiguity, replay/tail counts, rendered payload order, notification exactly-once, capture-failure-no-notify, duplicate-terminal-no-double-notify, no-BOM encodings, and self-tests on corrupted fixtures (`verify-prototype.ps1:8-37,521-536`). This is the reference acceptance surface ticket 06/07 must port to Node tests.
- Pre-existing unrelated failures: `test/stage-prompt.test.ts` and Windows path-separator assertions (noted in exploration history).

**Supported inference** — Ticket 04 should treat `verify-prototype.ps1`'s checks as the test contract to port, and must add new `fake-pi.sh` modes (streaming deltas, stderr flood, mid-stream capture loss, duplicate terminal) because the current fixture cannot exercise the seam.

---

## Track G — Domain vocabulary and ADR constraints

**Facts**

- `CONTEXT.md` defines the binding glossary: **Run**, **Host Session**, **Run Window**, **Transcript**, **Monitor Wait**. `Transcript` = the ordered, complete input/output record exposed by Pi; `Run Window` = the per-Run viewer (see the ticket 04 question and map Notes).
- `docs/agents/domain.md` instructs: read `CONTEXT.md` + relevant ADRs, use glossary vocabulary, and **explicitly flag conflicts with existing ADRs**.
- `docs/adr/` contains only `.gitkeep` — **there are no ADRs**, so there are no ADR constraints to honor or conflict with. `git status` shows `docs/adr/` untracked; HEAD `174cf17` predates it.

**Supported inference** — The binding constraints for this seam are therefore the map Notes, `_grilling-decisions.md`, `CONTEXT.md`, and research 01/02 — not ADRs. The "ADR constraints" track resolves to: *none exist*; creating one for the Transcript schema would be a new decision, not a lookup.

---

## Conflicts (must be resolved before or during 04)

1. **Completeness oracle** — Pi stdout `agent_end`+`agent_settled` (`research/02:367`) vs wrapper `meta`/`terminal` record (`_prototype-exploration.md:338-345`).
2. **Notification-on-capture-error** — prototype header comment says notify (`per-run-window.ps1:45-49`); code, verifier, and retained report say do not.
3. **Default mode / live binary** — repo HEAD defaults `async` (`delegate.ts:84`); live installed checkout defaults `sync` and differs (research/01; `_exploration.md`).
4. **`pi_status` timeout comment** — `status.ts:38` claims a 30 s host hard timeout; research/01 proves 300 s (`status.ts` comment is wrong).
5. **Retained latency artifact vs ticket claim** — `_out/report.json` (the retained artifact, `headless:false`) shows `maxHeartbeatGapMs:2267` and `volume` `p95LatencyMs:54957`, which fail the prototype's own U5 thresholds; ticket 03 comments cite a separate *paced* run that passed (268 ms / 94 ms). The passing run is not present as an artifact.
6. **Window process model** — one process/many forms (prototype) vs "one independent window for every Run" (ticket 07 wording); called out as a prototype ambiguity (`_prototype-exploration.md:10`).
7. **Stale committed fixture** — `pi-output-echo.jsonl` predates 0.85.1 but is still used by `parse.test.ts` (`research/02:40-42`).

---

## Unknowns / evidence gaps

- Frozen production Transcript schema (raw byte stream vs prototype meta envelope vs both); no file on disk is designated normative.
- Whether the Journal bytes represent the *wire* bytes or a lossy re-encode; the prototype writes `data` as a JSON string, so byte-for-byte fidelity to Pi stdout is not yet proven for arbitrary content (R11 partial-line/encoding edge cases).
- No production notification transport chosen (WinForms toast vs Windows toast vs other); no owner module.
- No retention sweep trigger/budget accounting design (Track E gap).
- No `onStderr`-style fan-out exists; only the 2 KB tail — a real design addition.
- No production GUI-failure isolation design; prototyped only.
- No decision on how `Run`/`registry.json` (which drops `runId`) links to a persisted Transcript after a server restart.
- No ADR records any of the above.

---

## Reproduction / verification commands used

```
git rev-parse HEAD                                   # 174cf17087b3f349cce7fe11928a1dccfd7b5886
git status --porcelain                               # .scratch/, AGENTS.md, CONTEXT.md, docs/adr/, docs/agents/ untracked
ls docs/adr                                          # .gitkeep only
grep -rn "cleanupExpired" src test                   # only run.ts def + test caller
grep -riE "notif" src                                # 0 hits
grep -n "R[0-9]" .scratch/.../research/02-pi-event-surface.md
grep -n "seam|collectOutput|journal" .scratch/.../_prototype-exploration.md
```

## Bottom line for ticket 04

Lock, in this order: (1) the append-only Transcript envelope + `rawSha256`/seq rules, written at the `spawn.ts:49-99` fan-out; (2) the pure formatter adapter (R2–R7 + unknown/partial fallbacks); (3) the replay-then-tail window launch protocol and process model; (4) the incomplete-capture predicate and its status vocabulary, deciding Pi-vs-wrapper authority; (5) notification ownership as one-shot per-`runId` state independent of window and `pi_status`; (6) the 7 d / 2 GiB completed-only retention sweep kept separate from `RunRegistry`'s 128-cap/24 h TTL and from `registry.json` `version:1` backward compatibility. Port `verify-prototype.ps1`'s checks into Node tests and extend `fake-pi.sh`; note that `docs/adr/` is empty, so no ADR constraint blocks or guides this.
