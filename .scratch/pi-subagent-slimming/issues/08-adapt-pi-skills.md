# Adapt Pi skills to sync-first operation

Type: wayfinder:task
Status: open
Blocked by: 01, 05

## Question

Rewrite the repository Pi skill and references so Codex uses synchronous pi_delegate by default, async is an explicit compatibility fallback, fallback collection uses three one-minute then three-minute occupying Monitor Waits without overlap, disconnects never auto-redispatch, and every installed specialized Pi skill remains demonstrably compatible with the two-tool server.
