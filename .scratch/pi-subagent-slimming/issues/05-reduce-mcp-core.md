# Reduce the MCP core to the supported surface

Type: wayfinder:task
Status: resolved
Blocked by: 01, 04

## Question

Implement and verify the smallest coherent MCP core containing only pi_delegate and pi_status, retaining internal Pi Session continuity and safe Run lifecycle behavior while removing legacy plan/session/task/kill tools, their exclusive persistence and scheduler machinery, and obsolete documentation/tests.

## Answer

Reduced the existing server in place to the supported `pi_delegate` / `pi_status` surface. The change preserves registry v1 loading, named Pi Session continuation, synchronous and asynchronous delegation, status long-polling, and timeout finalization. Legacy tool dispatch and declarations, task persistence wiring, and the exclusive plan/session/task/kill modules were removed without restructuring the retained core; shared runner helpers, types, stage-prompt, and validation residue remain intentionally.

Added a real stdio MCP boundary test covering the exact two-tool list, rejection of every removed name, registry v1 continuity, create/continue continuity (including enforcement of `--session-id` on continuation), async status collection, timeout behavior, and an untouched/unused legacy `tasks.json`. Only obsolete protocol tests and task-only documentation were removed; tests for deliberately retained stage-prompt and validation residue remain. Mixed historical design documents carry explicit superseded banners. `npm run build` passes and the remaining full suite passes 98/98.
