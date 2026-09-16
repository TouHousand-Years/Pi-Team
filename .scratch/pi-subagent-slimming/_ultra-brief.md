# Ultra brief — ticket 04 Transcript-to-Run-Window seam

## Decision requested

Produce one coherent production design that locks the exact append-only Transcript schema, capture/formatting boundary, Run Window launch and replay/tail protocol, completion and incomplete-capture authority, exactly-once notification ownership, retention cleanup seam, registry compatibility, and validation/migration steps before tickets 05-07 implement them.

This is a planning-only pass. Do not explore the repository, use tools, edit files, or implement anything. Treat this brief as the complete evidence boundary.

## Goal and success criteria

The final service exposes only `pi_delegate` and `pi_status`, prefers synchronous direct return, and creates one independent read-only formatted Run Window for every delegation. Every Run has an unredacted process-boundary Transcript containing submitted input, non-secret launch metadata, all stdout NDJSON, stderr, diagnostics, and terminal state. The window replays and tails it without summaries, silent truncation, or duplicate recognized events. Unknown/malformed/partial data remains losslessly visible. Capture failure marks the Transcript incomplete without stopping the Run or notifying completion. Closing a window never affects capture, execution, or notification. Valid completion notifies exactly once. Completed Transcripts are kept seven days or until completed storage exceeds 2 GiB; active Runs are never deleted. Existing `registry.json` remains readable and legacy `tasks.json` untouched.

## Accepted decisions and constraints

- One `pi_delegate` call is one Run and one independent Run Window, including Pi Session continuations.
- The window is read-only, realtime, formatted-only; it shows all process-boundary input/output, not a summary or raw-events tab.
- Unredacted storage is accepted and restricted to the current user.
- Completed windows remain until manually closed. Closing a running window detaches display only; capture and notification continue.
- No hidden-reasoning claim. Only Pi-emitted process-boundary data is represented.
- Capture/display failures are isolated from Pi execution.
- Current live checkout is untouched until verified cutover with no active Run and rollback copy.
- Windows-only GUI is in scope; writable controls are out of scope.
- Binding vocabulary: Run, Host Session, Run Window, Transcript, Monitor Wait (`CONTEXT.md`). No ADR exists.

## Current production facts

- There is no production Transcript or GUI.
- `src/runner/spawn.ts:49-99` `collectOutput` is the only point observing every stdout line and stderr byte. It exposes `onLine`, retains stdout in RAM, and keeps only a 2 KiB stderr tail; there is no stderr callback.
- `src/tools/delegate.ts:114-205` owns Run finalization. `src/runner/parse.ts:17-84` is intentionally lossy and should remain a semantic/result layer above raw capture.
- `RunRegistry` is in-memory, caps completed Runs at 128, and has an uncalled 24-hour cleanup; it is unsuitable as Transcript storage or cleanup authority.
- `registry.json` v1 is atomic, session-oriented, redacted, and drops `runId`. Corrupt files are backed up and persisted running sessions become error after restart. `tasks.json` is separate.
- Delegate child concurrency is capped at four. Timeouts, stall/manual kills, and server-shutdown termination already exist.
- `pi_status` is a long-poll read path and must not own notification.
- Current fixtures lack streaming deltas, `agent_settled`, stderr flood, capture failure, duplicate terminal, Transcript, formatter, window, notification, and retention cases.

## Prototype and research evidence

- Human-accepted schema candidate: one UTF-8-no-BOM append-only `<runId>.journal.jsonl` with contiguous `seq` from 1 and records `{seq, ts, ch, kind?, data, ...extras}`. `ch` is `stdout|stderr|meta`; meta kinds are `launch|terminal|captureError`. Prototype hashes every record `data` joined by LF.
- Accepted formatter: pure record-to-display adapter; streaming deltas are content authority; terminal envelopes reconcile rather than duplicate; tool calls/results and usage render once; structural events remain markers; unknown/malformed/partial records use lossless fallback.
- Accepted Run Window: separate read-only WinForms viewer, full Run ID, replay then tail, completed window remains open, close-running detaches display only, display failure isolated.
- Accepted notification: one-shot per `runId`, independent of window and `pi_status`, only on valid completion. Capture failure and signaled terminal are incomplete and do not notify.
- Prototype verifies seq/order/hash, replay+tail, payload order, no duplicate recognized raw JSON, unknown fallback, exactly-once notification, capture-failure-no-notify, display isolation, Unicode, and 50,000-event streaming. Batched RTF avoids O(n²) append cost.
- Pi 0.85.1 stdout is NDJSON; stderr is diagnostics. Pi normally ends with `agent_end` then `agent_settled`. Partial/malformed/unknown records must not disappear.

## Conflicts the proposal must resolve

1. Completion authority: Pi `agent_end` + `agent_settled` versus wrapper `meta/terminal` plus contiguous seq/no capture error. Specify one authoritative predicate and cross-check.
2. Wire fidelity: decide exact bytes, exact decoded chunks/lines, or both, including partial lines and invalid UTF-8.
3. Window model: prototype is one process/many Forms; product says one independent window per Run. Choose process/ownership and failure isolation.
4. Retention: choose startup/on-complete/timer triggers, oldest-first ordering, crash safety, and 2 GiB accounting without touching active Runs.
5. Restart linkage: `registry.json` drops `runId`; define Transcript discovery and terminal/incomplete status after restart without breaking v1 reading.
6. A stale prototype comment said capture errors notify; implementation, verifier, map, and user decision bind no-notify.

## Non-goals

- No legacy v2 plan/task/session/kill tool surface.
- No writable GUI controls or GUI cancellation.
- No hidden reasoning or unexposed context.
- No cross-platform GUI.
- No live-checkout mutation during implementation.

## Evidence

- Repository evidence: `_grilling-exploration-04.md`.
- Event rules: `research/02-pi-event-surface.md`.
- Prototype: `_prototype-exploration.md` and `prototype/*`.
- User decisions: `_grilling-decisions.md`, `map.md`, resolved ticket 03.

## Required response

Return:

1. Recommended end-to-end module boundary and data flow.
2. Normative Transcript schema: fields, byte/text fidelity, sequencing, append/flush/close rules, terminal/capture-error semantics, discovery layout.
3. Formatter API and dedup/reconciliation ownership.
4. Viewer process, launch, replay/tail, restart, and failure protocol.
5. Completion/incomplete/exactly-once notification state machine with one authority.
6. Retention ownership, triggers, ordering, crash/race behavior, and v1 registry compatibility.
7. Ordered, independently checkable steps for tickets 05-07 with tests and rollback points.
8. Alternatives, assumptions, risks, and evidence gaps that would change the recommendation.

Ground every recommendation in this brief. Do not invent user intent. If insufficient, name the smallest missing evidence set.
