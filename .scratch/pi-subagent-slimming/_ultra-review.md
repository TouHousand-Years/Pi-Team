# Ultra review: Slim Pi Subagent with Observable Runs

The chart has no planning blocker and is safe to enter the research frontier. It is not yet safe to deploy or replace the live service.

## Review findings

- Treat completion-transport research as a decision gate. Verify synchronous return, no automatic redispatch after disconnect, and no overlapping fallback waits.
- Make security and retention acceptance criteria explicit: current-user-only access, seven-day or 2 GiB completed-transcript retention, continued capture after a window closes, and accounting separate from the legacy registry cap.
- Use **Fix the Transcript-to-window seam** to lock shared lifecycle and capture interfaces before the MCP-core and Transcript implementation tickets proceed in parallel.
- Require the event-surface inventory to include a coverage matrix for normal, unknown, malformed, partial, stderr, diagnostic, and capture-failure events, with duplicate-output checks.
- Keep compatibility and removal auditable: verify the two-tool surface against all four specialized Pi skills, preserve old-session readability, leave legacy tasks untouched, and preserve repository governance files.
- Make cutover qualification explicit: distinguish baseline test failures from regressions, require human visual approval, keep UI failure from terminating the server, and retain the old checkout/config/state as rollback material.

## Disposition

No map facts were changed by this review. The open frontier remains:

1. **Prove Codex completion transport boundaries**
2. **Inventory Pi's lossless event surface**

