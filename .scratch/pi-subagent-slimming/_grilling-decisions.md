# Detailed grilling decisions

## Accepted whole direction

- The Wayfinder effort carries implementation, verification, UI inspection, and eventual service replacement.
- The supported MCP surface contains `pi_delegate` and `pi_status`; `pi_kill`, `pi_plan`, `pi_session_*`, and `pi_task_*` are removed.
- Every `pi_delegate` invocation is a Run and opens an independent Run Window, including continuations of an existing Pi session.
- “All input/output” means the complete process-boundary record: submitted/effective prompt and non-secret launch metadata plus all stdout NDJSON, stderr, diagnostics, and terminal state actually emitted by Pi. It excludes unavailable hidden context and unexposed reasoning.
- Transcripts are persisted unredacted and restricted to the current Windows user. The UI warns that content may be sensitive.
- `pi_status` retains bounded occupying long-poll semantics. For an asynchronous Run, the Host Session performs up to three consecutive one-minute Monitor Waits, then consecutive three-minute Monitor Waits, with no overlap, stopping at terminal status. This is intentionally low-frequency long-polling rather than snapshot polling.
- If the actual host cannot sustain these waits, that is a feasibility blocker rather than permission to substitute a different monitoring owner.
- The current original repository is the implementation source. After it is complete and verified, replace the currently configured non-identical service during an idle cutover; preserve rollback.
- The initial UI direction is a separate local Windows Run Window per Run. Visual validation pauses for human inspection.

## Still open after round 1

- Transcripts remain for seven days or until completed-Run transcripts total 2 GiB, whichever limit is reached first. Cleanup removes the oldest completed Runs and never an active Run.
- Closing a running Run Window closes only its display. Capture and completion notification continue independently. A completed window stays open until the user closes it.
- The Run Window shows one complete formatted event stream. It has no Raw-events tab and must not summarize, truncate, or omit unknown events.
- Capture/storage failure does not stop the Run. The Run Window and status result explicitly mark the transcript incomplete.
- Start with a PowerShell/.NET WinForms feasibility prototype; switch UI technology only if event volume, Unicode, or window isolation fails. Human visual inspection is mandatory.
- For Codex, a synchronous `pi_delegate` call can remain pending and return immediately when Pi finishes, avoiding `pi_status` polling. Async completion after the original MCP response has returned has no established Codex server-push path; it still needs host-side result submission or polling.

## Still open after round 2

- Codex always prefers synchronous `pi_delegate`; Pi completion returns the pending MCP call and resumes the Host Session. Async and the one-minute/three-minute Monitor Wait schedule remain only as a compatibility or verified-timeout fallback.
- The new service remains backward-readable for existing `registry.json` Pi Sessions. It neither migrates nor deletes the old registry. A legacy `tasks.json` is left untouched and ignored.
- Cutover occurs with no active Run: build the original repository, back up the Codex MCP configuration, and point it at this repository's `dist/server.js`. Preserve the old live checkout and state for immediate rollback.
- If a synchronous MCP call disconnects or times out, never redispatch automatically. The Run Window remains the observed state source; a new or async fallback Run requires an explicit Host Session decision after the previous Run's outcome is known.

## Design-tree status

All currently visible user decisions are resolved. Awaiting the user's explicit confirmation that the shared understanding is complete before charting the Wayfinder map.
