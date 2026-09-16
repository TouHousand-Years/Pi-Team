# Fix the Transcript-to-window seam

Type: wayfinder:grilling
Status: resolved
Blocked by: 02, 03

## Question

Given the observed Pi event surface and the human-reviewed viewer prototype, what exact append-only Transcript schema, formatting adapter boundary, window launch/replay protocol, incomplete-capture signal, notification ownership, and retention cleanup seam should the production design lock before implementation?

## Accepted proposal

The user accepted the overall Ultra proposal on 2026-09-16.

## Detailed interview

### Round 1

- Transcript uses a single-writer, versioned JSONL envelope with a global sequence, UTC and monotonic time, record kind/source, and Base64 boundary bytes. Decoding and semantic formatting stay outside the evidence layer.
- Ordinary records may use bounded buffering for performance even though this is a personal, low-concurrency application. Flush at no more than 250 ms or 64 KiB; force durable writes for startup, capture errors, state transitions, and the terminal record. A crash-lost tail makes the Run incomplete.
- Terminal states are `running`, `succeeded`, `failed`, `protocol-error`, and `incomplete`, using the proposed predicates. The wrapper is authoritative; Pi settlement events are semantic cross-checks.
- Viewer launch failure, viewer crash, or manual close does not affect capture, Run completion, or notification eligibility. The viewer can be explicitly reopened for full replay.
- Capture submitted and effective prompts separately, plus any later stdin bytes. Persist allowlisted launch metadata, not the raw command line or environment.
- Display strictly follows Transcript `seq`; timestamps do not reorder records or claim stronger cross-pipe causality.

### Round 2

- The terminal record carries the proposed outcome, exit, timing, final-sequence, EOF, byte-count, Pi-settlement, capture-error, and SHA-256 evidence fields. The hash covers the exact serialized bytes before the terminal record.
- `succeeded`, `failed`, and `protocol-error` produce completion indication; `incomplete` produces a distinctly worded monitoring warning rather than a completion claim.
- Do not implement an OS toast or claim durable/exactly-once visible delivery. Indicate completion inside the per-Run window and play one reminder sound only; no continuing reminder is guaranteed.
- `pi_delegate` automatically launches the per-Run viewer. `pi_status` may take `openWindow: true` to reopen it; ordinary status reads have no UI side effect.
- Suppress streaming fragments in the formatted display and show complete information instead. The exact fallback for streams that never receive a matching completion record remains to be decided.
- The seven-day/2-GiB policy applies to all inactive terminal bundles. Running or ambiguously owned bundles are never automatically deleted, and trash counts toward the quota.

### Round 3

- Streaming fragments stay hidden during a healthy Run. If no matching completion event arrives by terminal state, accumulated fragments are shown once as explicitly unfinished output.
- `tool_execution_update` records stay hidden when the final `tool_execution_end` covers them. Any update content absent from the final result is shown afterwards as unmerged intermediate output.
- Closing a viewer forfeits active window/sound notification for that Run. The service does not reopen it or repeatedly alert; synchronous return or low-frequency `pi_status` remains the fallback.
- Each Run attempts sound at most once. Success uses a normal sound; failure, protocol error, or incomplete capture uses a warning sound. A durable `alertAttemptedAt` prevents replay on reopen but does not claim the sound was heard.
- An open completed viewer does not pin its bundle. After replay it releases the files; retention may remove the bundle while the window keeps its in-memory formatted content and marks that the source was cleaned.
- After a host crash, a nonterminal Run is never adopted. A stale child may be terminated only when PID, process creation time, and lease identity all match; otherwise ownership is marked ambiguous, the process is not killed, and the bundle is not automatically cleaned.

### Round 4

- Transcript storage has its own `PI_SUBAGENT_TRANSCRIPTS` setting, defaulting to `~/.pi-subagent/runs/`, independent of the registry file override.
- Each Run bundle contains atomic `manifest.json`, append-only `transcript.jsonl`, `lease.json`, and non-evidentiary `viewer-state.json`. Viewer/sound state is excluded from the evidence hash.
- Create the bundle and initial prompt/start records first, then launch the viewer and wait at most two seconds for its ready handshake before spawning Pi. Viewer failure never blocks the Run.
- Enforce one viewer instance per Run. A reopen request focuses the live instance or creates a replacement only after confirming the prior viewer exited.
- An unterminated trailing JSONL line waits for more bytes. Other malformed records are displayed losslessly; sequence gaps or terminal-hash mismatch permanently mark capture incomplete without suppressing later readable records.
- `pi_status` returns the stable Run identity/outcome, timing, result or error, capture integrity and reason, Pi settlement observation, viewer state, and Transcript availability. `openWindow` is optional and never redispatches work or replays sound.

### Round 5

- The formatter exposes submitted/effective prompts, launch metadata, lifecycle boundaries, complete assistant/thinking/tool events, final tool results plus uncovered intermediate output, stderr/diagnostics, terminal state, and final per-message/turn usage. It suppresses changing delta usage.
- Thinking content is shown only when Pi emitted it at the process boundary and is labeled accordingly; the UI never claims to expose hidden reasoning.
- The Transcript root must be a non-reparse user-profile location and retain inherited Windows ACLs. The security claim covers other standard users, not local administrators or SYSTEM.
- Cleanup validates terminal manifest, lease, and directory lock before atomic trash rename; any ambiguity or rename failure skips the bundle. Cleanup runs at startup, after finalization, and every 15 minutes, including recovery of trash deletion.
- Freeze Transcript schema v1 with no legacy migration requirement. Future versions receive lossless raw display but no success judgment or completion sound.
- Raw byte payloads are chunked at at most 64 KiB and carry `groupId`, `part`, and final-part metadata for complete logical reassembly before formatted display.
- The production viewer is Windows-only. Capture, Transcript, status, and cleanup remain cross-platform; other platforms return `viewer: unavailable` without installing another GUI.

### Round 6

- Window titles use `[state] Pi — <session> — <first-prompt-line summary> — <full runId>`, with the summary capped at 80 characters. A fixed header exposes the full Run identity and launch metadata.
- A read-only status bar communicates `RUNNING`, `SUCCEEDED`, `FAILED`, `PROTOCOL ERROR`, or `INCOMPLETE` using text, icon, and color. Terminal windows stay open until manually closed.
- Read-only interactions include scrolling, selection, copy, select-all, find, and line-wrap toggle. The viewer cannot send input, retry, terminate, or mutate a Run.
- Use segmented/virtualized rendering with no logical truncation. A completed open viewer retains all loaded formatted segments after the underlying bundle is cleaned; viewer memory failure does not alter Run or capture state.
- Ambiguous ownership is rechecked during each 15-minute reconciliation. Once the old process is confirmed absent, recovery writes an `incomplete` terminal record and starts ordinary retention; uncertainty never authorizes a kill.
- Productionize the PowerShell/WinForms prototype as a separately shipped viewer launched by Node in STA mode with an argument array and no shell interpolation.
- The accepted validation gate covers schema/byte fidelity, all terminal classes, capture and crash failures, formatter fallbacks, replay/tailing, Unicode and 50,000-record load, one-shot window sound, retention races, the two-tool surface, registry/tasks compatibility, real Pi 0.85.1 qualification, rollback, and required human visual inspection.

## Interview state

The design-tree frontier is empty. The user confirmed the complete shared understanding on 2026-09-16; implementation has not started.

## Answer

Lock Transcript v1 as the durable, append-only evidence boundary and make the Run coordinator the sole terminal authority. Capture submitted/effective prompts and exact stdout/stderr bytes before semantic parsing into a single-writer JSONL stream with global ordering, bounded buffering, 64-KiB payload chunks, forced durable boundary records, and a terminal hash over the preceding serialized bytes. Classify Runs as `running`, `succeeded`, `failed`, `protocol-error`, or `incomplete`; Pi settlement events cross-check semantics but do not control OS-level completion.

Store each Run under the independently configurable Transcript root as `manifest.json`, `transcript.jsonl`, `lease.json`, and non-evidentiary `viewer-state.json`. Reconcile stale leases without adopting orphaned Runs or killing an ambiguously owned process. Clean all inactive terminal bundles after seven days and then oldest-first to a 2-GiB ceiling, using atomic trash moves; active and ownership-ambiguous bundles are excluded.

Launch one independent Windows PowerShell/WinForms viewer per Run after initial evidence is durable and before Pi starts, with a two-second non-blocking ready wait. The viewer replays and tails one sequence cursor, remains read-only, never truncates logical content, and can be reopened with `pi_status(openWindow: true)`. It suppresses streaming fragments during healthy execution and renders complete semantic events; unmatched fragments and uncovered intermediate tool output appear once as explicit incomplete/unmerged fallback. Unknown, malformed, corrupt, or future-version input remains losslessly visible and can only downgrade integrity, never be silently repaired.

Completion indication is local to the live Run Window: update its persistent status display and attempt one sound per Run, tracked outside the evidentiary Transcript. There is no OS toast, persistent reminder, or exactly-once visibility claim. Closing the window forfeits active notification but never affects capture or execution. `pi_delegate` remains sync-first with async fallback elsewhere in the route, while `pi_status` exposes stable outcome, capture, viewer, and Transcript availability without redispatching work.

Implementation is gated on the accepted automated matrix, real Pi 0.85.1 qualification, registry v1 compatibility, untouched legacy `tasks.json`, the two-tool public surface, rollback readiness, and required human visual inspection before live-service replacement.
