# Slim Pi Subagent with Observable Runs

Label: wayfinder:map

## Destination

Replace the current Pi subagent service with a verified two-tool, sync-first implementation that retains the Pi skill family, records every Run's process-boundary input/output, opens one realtime read-only formatted Run Window per delegation, and keeps a bounded async long-poll fallback.

## Notes

- This map explicitly carries implementation, verification, human UI inspection, and final service replacement through the route.
- Use the vocabulary in CONTEXT.md: Run, Host Session, Run Window, Transcript, and Monitor Wait.
- Every implementation ticket uses pi-worker; UI prototyping uses prototype-pisub; primary-source fact tickets use research-pisub; hard module-boundary decisions use codebase-design; update domain language with domain-modeling.
- Supported MCP tools: pi_delegate and pi_status. Remove pi_kill, pi_plan, pi_session_*, and pi_task_*.
- Codex normally holds a synchronous pi_delegate call until Pi returns. Async is only a compatibility or verified-timeout fallback.
- Async collection preserves occupying long-poll behavior: three sequential waits of at most one minute, then sequential waits of at most three minutes; waits never overlap.
- Every pi_delegate invocation is one Run and opens its own Run Window, including Pi Session continuations.
- A Transcript contains unredacted process-boundary input, non-secret launch metadata, all emitted stdout NDJSON, stderr, diagnostics, and terminal state. It cannot claim hidden context or unexposed reasoning.
- Run Windows show complete formatted events without summaries, silent truncation, or a Raw-events tab. Streaming fragments are withheld while healthy and reconciled into complete events; unmatched fragments and unknown/malformed events remain visible through explicit lossless fallback.
- Closing a window does not affect capture or Run execution, but it deliberately forfeits that Run's window-local completion indication and one-shot sound. Completed windows remain open until manually closed.
- Completed Transcripts are retained for seven days or until their total size reaches 2 GiB, whichever comes first; active Runs are never cleaned.
- Capture failure never stops a Run, but both status and window must mark the Transcript incomplete.
- Preserve backward reading of existing registry.json; leave any legacy tasks.json untouched and unused.
- Never auto-redispatch after a sync disconnect or timeout.
- Do not modify the currently configured, non-identical live checkout during implementation. Cut over only after verification with no active Run, preserving configuration and state rollback.
- Per AGENTS.md, pause and wait for human inspection whenever visual/UI verification is required.
- Baseline: build passes; 136 of 140 tests pass. Four existing test/stage-prompt.test.ts failures are Windows path-separator assertions and are outside this effort unless they block qualification.

## Decisions so far

- Completion transport research: a synchronous `pi_delegate` can return directly, but the current Codex per-server default imposes an observed approximately 300-second MCP call limit when `tool_timeout_sec` is unset. After a host timeout, retain the same Run and never redispatch automatically. The accepted 60-second/180-second sequential fallback remains provisional until qualification. [Evidence](research/01-completion-transport.md)
- Pi event-surface research: preserve raw process-boundary stdout NDJSON, stderr, and terminal metadata. Its provisional live-delta display policy is superseded by the accepted Transcript seam: production suppresses healthy streaming fragments until a complete event, with explicit unmatched-fragment fallback. Unknown and malformed content remains visible; do not claim hidden reasoning. [Evidence](research/02-pi-event-surface.md)
- Run Window prototype: independent read-only windows, full Run IDs, formatted-only recognized events, lossless unknown/malformed fallback, cached per-category font coverage, and background capture after window close are feasible. Its exactly-once notification experiment is superseded by a window-local status change and one sound attempt with no delivery guarantee. Batched RTF insertion avoids the original O(n^2) display path; automated qualification and human visual acceptance passed. [Evidence](issues/03-prove-per-run-windows-viewer.md)
- Transcript-to-window seam: Transcript v1 is the exact-byte durable evidence source; the coordinator owns terminal classification; one disposable Windows viewer per Run renders complete events with lossless fallbacks; notification is window-local and one-shot; inactive bundles use seven-day/2-GiB cleanup while active or ambiguously owned bundles are protected. The full design tree and validation gate are frozen for implementation. [Decision](issues/04-fix-transcript-window-seam.md)
- MCP core reduction: the existing server now exposes only `pi_delegate` and `pi_status`; registry v1 Pi Session continuity and safe Run completion/timeout behavior remain, while legacy plan/session/task/kill dispatch, exclusive persistence/scheduler modules, and obsolete tests/docs are removed. The stdio boundary and untouched legacy `tasks.json` are covered by regression tests. [Implementation](issues/05-reduce-mcp-core.md)
- Lossless Run Transcripts: Transcript v1 evidence layer implemented under `src/transcript/` — append-only Base64 byte journal with global sequence and terminal SHA-256, submitted/effective prompts captured separately, buffering with forced-durable boundary records, lossless replay with integrity marking (gaps/hash/partial), crash recovery that never adopts or kills, seven-day/2-GiB trash-based retention that protects active and ownership-ambiguous bundles, byte-level spawn capture, and storage-failure isolation from Runs; `pi_status` now carries Transcript availability/integrity. Viewer/formatter remain ticket 07. [Implementation](issues/06-build-lossless-run-transcripts.md)
- Pi skill family adapted to sync-first two-tool operation: the repository skill and both references were rewritten to `pi_delegate`/`pi_status` only — sync default with `runTimeoutMs` ≤ 240000 under the proven 300-second host cap, async as an explicit compatibility fallback, three one-minute then three-minute non-overlapping Monitor Waits, and a hard no-auto-redispatch rule that collects the same `runId`. The two installed specialized skills that still assumed the retired task surface (`pi-team`, `pi-worker`) were corrected; all five now use only the two tools, gated by `test/skill-contract.test.ts` with a regression-verified failure mode. Server code was deliberately left untouched, the 60-second/180-second waits stay provisional until host qualification, and the stale installed v2 skill copy is left to the ticket-09 cutover. [Implementation](issues/08-adapt-pi-skills.md)
- Independent Run Windows integrated: every `pi_delegate` (sync or async) now opens one independent read-only Run Window (`viewer/run-window.ps1`, launched by `src/viewer/manager.ts` in STA mode with an argument array and no shell interpolation) after the bundle's launch/starting records are durable and before Pi is spawned, with a bounded two-second ready handshake that never blocks the Run. The window replays and tails Transcript v1 with byte-group reassembly before decoding, formatted-only dedup of Pi's repeated message envelopes, lossless fallbacks for unknown/malformed/foreign/unmatched content, terminal-SHA-256 verification, `INCOMPLETE` on any integrity downgrade, window-local status plus exactly one recorded sound attempt with no OS toast, read-only interactions only, and bundle release after replay so retention is not pinned. One live instance per Run: a live (including still-starting) instance is focused, and a replacement is launched only after the prior instance is confirmed gone. `pi_status` gained `openWindow` plus timing, Pi-settlement and viewer fields; GUI failures of every kind are isolated. 154 tests pass with no baseline test relaxed, the formatter matrix runs the real PowerShell viewer, and the real launch path was exercised end to end. Pending human visual inspection of the production window, real Pi 0.85.1 qualification, and the retention-while-open race — all ticket 09. [Implementation](issues/07-integrate-independent-run-windows.md)

## Not yet specified

- Additional event adapters or display groupings that may become specifiable after observing the installed Pi version's real event stream.
- A registry migration response if compatibility tests reveal an old record shape the current evidence has not exposed.

## Out of scope

- Cross-platform GUI packaging; this effort targets the current Windows/Codex environment.
- Writable Run controls, including start, retry, cancel, edit, and continue actions.
- Capturing hidden model reasoning, unexposed context, or other data Pi does not emit at the process boundary.
- Preserving the legacy v2 task/session/plan tool protocol.
- Treating unrelated Windows path-separator test failures as part of the slimming change.
