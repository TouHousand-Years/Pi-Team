# Proposal delta 01 — realtime per-Run windows

Status: accepted by the user on 2026-09-15.

## Accepted detailed decisions — round 1

- Wayfinder Notes will authorize carrying implementation through the map.
- The supported MCP API is exactly `pi_delegate` and `pi_status`; `pi_kill` is removed.
- Every `pi_delegate` invocation is a distinct Run with its own Run Window, including continuations of an existing Pi session.
- “All input/output” means the complete process-boundary record: the submitted prompt, non-sensitive launch arguments, every emitted stdout NDJSON event, stderr, diagnostics, and terminal outcome. It does not claim hidden context or unexposed model reasoning.
- Transcripts are persisted without content redaction and restricted to the current Windows user; the Run Window warns that sensitive content may be present.
- `pi_status` becomes an immediate snapshot call. The Host Session checks an asynchronous Run at +1, +2, and +3 minutes, then every three minutes (+6, +9, …) until it observes a terminal state.
- If the host cannot reliably schedule those checks, the requirement is blocked rather than silently replaced with viewer polling or manual continuation.
- The current repository is the source implementation. After modification and verification, it replaces the currently configured service through a deliberate cutover with rollback; the existing live checkout is not treated as identical source.

## User correction

The previous proposal incorrectly assigned low-frequency monitoring to the user window and made the human initiate every follow-up. The user clarified:

1. The **Host Session** must check each asynchronous Run once every three minutes.
2. The user-facing **Run Window** must monitor in real time.
3. The Run Window must display all input and output produced through Pi, not summaries or briefs.
4. Every Run gets its own independent Run Window.

The domain term **Run** is used for one `pi_delegate` invocation. This avoids collision with the legacy `pi_task_*` orchestration concept that is a deletion candidate.

## Newly established repository facts

- `src/runner/spawn.ts` already receives Pi stdout as a live line stream. `collectOutput` calls `onLine` for every non-empty NDJSON line and retains all lines in memory until completion.
- `src/runner/parse.ts` deliberately discards the contents of most Pi event types. It preserves tool-result text for a redacted summary and the final assistant result; other delta, turn, and message events keep only their type.
- `src/tools/delegate.ts` uses the live line callback only for session handshake and 200-character tool-result summaries. Therefore the current registry cannot power a full live transcript.
- `src/registry/persist.ts` persists Session records rather than Runs. A Session record contains only goal, status, summaries, errors, limited progress, and counters. It does not contain the submitted prompt or raw Pi NDJSON.
- A realtime full-content Run Window therefore needs a new fan-out path at the raw stdout/stderr boundary, before lossy parsing, plus a per-Run durable or streamable transcript source.
- Pi's prompt is passed to the subprocess as the `-p` argument. The exact meaning of “all input” still needs a user-visible contract: at minimum the `pi_delegate` prompt; potentially prior Pi session history, injected context, tool arguments, and model reasoning if Pi emits them.

## Revised proposal requirements

- Keep the earlier small MCP boundary recommendation unless this delta forces a change: `pi_delegate` and `pi_status`, sync-first with explicit async, legacy orchestration removed, and `pi_kill` still an explicit user decision.
- For every Run, create a separate Run Window automatically when delegation starts. It is read-only and cannot start, cancel, retry, edit, or continue work.
- The Run Window updates in real time from the actual Pi event stream and shows full content rather than registry summaries. Progress percentages must not be invented.
- Preserve event ordering and distinguish host-submitted input, Pi assistant output, tool calls, tool results, stderr/diagnostics, and terminal status when those are emitted.
- A safe architecture should not make the Pi worker depend on the GUI. If a window fails, the Run continues and the transcript remains available.
- The Host Session, not the Run Window, owns low-frequency collection. For asynchronous Runs it schedules or performs one `pi_status` check every three minutes until terminal, then reports/continues in the Host Session. This replaces continuous 25-second long polling.
- The Run Window should still deliver an immediate human completion notification based on its realtime observation. The Host Session may learn completion up to three minutes later.
- Full transcripts materially increase confidentiality and storage risk. Any filtering/redaction policy is a user decision because “all input/output” may conflict with automatic secret suppression.
- Each Run Window implies up to the current four concurrent windows and potentially many retained completed transcripts. Window closure, transcript retention, relaunch, and cleanup require explicit policies.
- UI visual verification remains a mandatory human pause.

## Requested revised whole proposal

Revise only the parts of the prior direction affected by this delta. Return one coherent end-to-end proposal covering:

1. the raw-event capture and per-Run transcript boundary;
2. the lifecycle of an independent realtime Run Window, including launch failure isolation and completion notification;
3. the Host Session's exactly three-minute monitoring behavior without a tight loop or indefinite blocking;
4. what “all input/output” can truthfully mean based on emitted Pi events, and which privacy/retention decisions must be confirmed;
5. revised implementation stages, tests, risks, and rollback points;
6. whether the two-tool API recommendation changes.

Mark user decisions separately from safe implementation defaults. Do not explore, use tools, or modify files.
