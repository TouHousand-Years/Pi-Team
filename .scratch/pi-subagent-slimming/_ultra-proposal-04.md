# Ultra proposal summary — ticket 04

## Recommended direction

Make the process-boundary Transcript the durable evidence source, the Run coordinator the sole completion authority, and each Run Window an independent disposable reader process.

## Boundary

- Capture exact stdout/stderr byte chunks at `collectOutput`, before lossy semantic parsing. Keep `parse.ts` as the result/progress layer only.
- Store one current-user-restricted bundle per Run: append-only versioned JSONL journal, atomic discovery manifest, and execution lease. `registry.json` v1 remains unchanged; `tasks.json` remains untouched.
- Journal records have contiguous sequence numbers across channels. Launch metadata is first; a wrapper-authored terminal record is last. Stdout/stderr bytes are Base64 so invalid UTF-8 and split code points remain reversible.
- Hash the exact serialized pre-terminal journal bytes, not only decoded payload strings.
- The coordinator writes and durably validates terminal evidence after child exit, both pipe EOFs, and writer drain. Pi `agent_end`/`agent_settled` are semantic cross-checks, not OS-capture authority.
- Capture failure is irreversible incompleteness but never stops Pi. Signal, spawn failure, abandonment, missing integrity, or undrained pipes are incomplete and do not notify.
- Normal nonzero exit can be a fully captured failed completion and notify once. Exit zero without expected Pi settlement becomes a protocol-error completion rather than success.

## Formatter and viewer

- A deterministic incremental formatter sits between Transcript reader and GUI. It owns event identity, delta/envelope reconciliation, tool/usage deduplication, partial-line updates, and lossless fallback.
- Use one viewer process per Run for failure isolation. The viewer receives only protocol version, Run ID, and journal path; it replays and tails with one byte cursor, treats file notifications only as hints, and polls as fallback.
- Closing or crashing a viewer affects neither capture nor notification. Completed windows remain open. Host restart does not automatically reopen old windows; explicit reopen replays the journal.

## Notification

- `pi_status` and the window never notify. The coordinator creates a durable outbox item keyed `completion:<runId>` only after a valid durable terminal.
- Crash recovery recreates a missing outbox item from terminal evidence. Retries reuse the same identity.
- Strict exactly-once visible notification requires the destination to acknowledge and durably deduplicate that identity. Until this is proven, the implementation must not overclaim exactly-once delivery.

## Retention and compatibility

- A separate Transcript-store service reconciles and sweeps at startup, after finalization, and every 15 minutes.
- Delete inactive bundles at seven days, then oldest-first until inactive storage is at most 2 GiB. Active bundles are excluded and never deleted.
- Rename eligible bundles atomically into `trash/` before deletion; resume interrupted deletion after restart. Ambiguous ownership blocks deletion.
- Keep notification deduplication receipts outside Transcript payload retention.

## Implementation order

1. Freeze schema, completion predicate, outbox contract, and golden fixtures.
2. Implement restricted store, exact-byte capture, leases, terminal validation, and fault tests.
3. Implement pure decoder/formatter and production event fixtures.
4. Implement independent viewer launch/replay/tail and failure isolation.
5. Add restart reconciliation and retention.
6. Verify v1 registry compatibility, two-tool public surface, actual Pi 0.85.1, notification destination, and rollback before live cutover.

## Remaining evidence gates

1. Notification destination acknowledgment and durable deduplication contract.
2. Whether any post-spawn stdin or secret-bearing arguments exist.
3. Windows child ownership behavior after host crash.
4. Production event identities for precise streaming/tool reconciliation.

Full input evidence is in `_ultra-brief.md` and `_grilling-exploration-04.md`.
