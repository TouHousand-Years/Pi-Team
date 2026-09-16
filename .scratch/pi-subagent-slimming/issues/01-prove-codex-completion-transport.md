# Prove Codex completion transport boundaries

Type: wayfinder:research
Status: resolved
Blocked by: none

## Question

Against official OpenAI/Codex documentation, the installed MCP SDK, and a bounded local experiment, what completion and timeout behavior can this Codex host actually guarantee for a pending synchronous pi_delegate call and for sequential one-minute/three-minute pi_status long-polls? Record the exact supported path, failure boundaries, and any change required to the accepted fallback contract.

## Answer

The current Codex host supports a pending synchronous `pi_delegate` call, but the per-server default is empirically capped at about 300 seconds when `tool_timeout_sec` is unset. A timed-out host call does not prove that the Pi Run stopped, so recovery must continue with the same `runId` and must never redispatch automatically. Sequential 25-second `pi_status` waits are directly proven; 60-second and 180-second waits are below the host cap but remain a qualification requirement. Keep waits non-overlapping as a Host Session invariant. See [the completion-transport report](../research/01-completion-transport.md).
