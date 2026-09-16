# Inventory Pi's lossless event surface

Type: wayfinder:research
Status: resolved
Blocked by: none

## Question

Using first-party Pi documentation/source and representative local runs, which submitted inputs, stdout NDJSON events, stderr diagnostics, streaming deltas, tool calls/results, reasoning-related events, and terminal signals are actually emitted by the installed Pi version, and what deterministic formatting rules can preserve all emitted content without duplicate assistant output?

## Answer

Installed Pi 0.85.1 emits a newline-delimited stdout event stream plus stderr diagnostics and process termination data. The Transcript must preserve the original byte stream and render deltas as the live representation while treating terminal message envelopes as authoritative reconciliation, not additional display copies. Unknown, malformed, partial, startup-failure, provider-error, tool-result, and observable-thinking cases all require explicit formatting paths; hidden reasoning must not be claimed. See [the event-surface report](../research/02-pi-event-surface.md).
