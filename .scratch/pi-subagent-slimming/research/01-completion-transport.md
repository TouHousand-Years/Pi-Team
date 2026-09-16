# Completion transport: proven behavior and the map-contract decision

Ticket: `issues/01-prove-codex-completion-transport.md`
Status: resolved (with one required contract change and one residual host-validation gap)
Researcher: Explorer SubAgent (read-only)
Date evidence collected: 2026-09-16

## Direct decision

The accepted fallback contract is **only conditionally valid**. It must be amended as follows:

1. **The pending synchronous `pi_delegate` call is a real completion path, but it is hard-capped by the Codex host at 300 s.** The host (rmcp MCP client) aborts an outstanding `tools/call` after 300 s with the error `timed out awaiting tools/call after 300s`. Therefore the contract's "Pi completion returns the pending MCP call" guarantee holds **only for Runs that terminate in under 300 s**. The server's default sync deadline (`runTimeoutMs` = 600 000 ms) and stall deadline (`stallTimeoutMs` = 300 000 ms) are **at or above** the host cap and must not be relied on to return a sync result.
   - **Required change:** for synchronous invocations the effective server deadline must be strictly below 300 s (recommended ≤ 240 s, leaving margin), OR the Codex config must raise `tool_timeout_sec` for the `pi-subagent` server above the intended sync Run deadline. As shipped (`config.toml` has no `tool_timeout_sec` for `pi-subagent`), 300 s is the binding limit.
2. **A sync host timeout does not kill or cancel the Run server-side.** Proven: after the 300 s host timeout, the same `runId` was still reported `running` by `pi_status` and later reached a terminal state. The contract's recovery rule is therefore: on a sync host timeout, **poll the same `runId` with `pi_status`**; do not start a new Run.
3. **The sequential long-poll fallback is transport-compatible but only 25 s waits are host-proven.** 164 `pi_status` calls exist; 162 completed successfully after ~25.0 s with `waitTimeoutMs: 25000`. The contract's 60 s and 180 s waits are both below the 300 s host cap and therefore safe by inference, but no host run has exercised a wait above 25 s. If the contract needs host-proven numbers now, keep each wait ≤ 25 s; if the 1-/3-minute schedule is kept, add an explicit host-validation step (or set `tool_timeout_sec` with margin).
4. **Non-overlap is a Host-Session rule, not a transport property.** The transport does not forbid overlapping `pi_status` calls (a cross-session overlap was observed; within one Host Session none was observed). No server/transport change is required; the non-overlap rule must remain an explicit Host-Session discipline.
5. **The in-code comment `低于 host 工具调用硬超时 30s` is factually wrong.** The proven host cap is 300 s, not 30 s. This comment should be corrected or removed.

No product source, test, config, registry, or live checkout was modified. See "Reproduction status".

## Proven guarantees

### A. Server behavior (read directly from source)

| Guarantee | Evidence |
| --- | --- |
| Sync `pi_delegate` blocks the MCP request handler until the Pi child process ends (`await finalize()`), then returns a terminal status. | `src/tools/delegate.ts:319-330` (sync branch); `src/runner/spawn.ts:112-121` (run timeout kills child) |
| Sync/server Run deadline defaults to 600 000 ms; stall deadline defaults to 300 000 ms. | `src/tools/delegate.ts:86, 271` |
| On `runTimeoutMs` the child gets SIGTERM, then SIGKILL after 5 s. | `src/runner/spawn.ts:112-121` |
| `pi_status` long-poll default is 25 000 ms; `waitTimeoutMs: 0` returns immediately with `running`. | `src/tools/status.ts:38-44` |
| On long-poll timeout `waitForCompletion` resolves `undefined`, and `status()` maps that to `{status:"running"}` (not an error). | `src/registry/run.ts:95-113`; `src/tools/status.ts:44-46` |
| The CallTool handler never reads the MCP cancellation/abort signal; it always finishes the run and records the terminal state. | `src/server.ts` `CallToolRequestSchema` handler; SDK `fullExtra.signal` at `node_modules/@modelcontextprotocol/sdk/dist/esm/shared/protocol.js:319-324` |
| The process survives uncaught exceptions/unhandled rejections, keeping the stdio transport alive. | `src/server.ts` `uncaughtException` / `unhandledRejection` handlers |

### B. SDK behavior (installed MCP TypeScript SDK)

| Guarantee | Evidence |
| --- | --- |
| Outbound client `request()` has a 60 000 ms default timeout and cancels with `notifications/cancelled`. | `protocol.js:6-8` (`DEFAULT_REQUEST_TIMEOUT_MSEC = 60000`), `:712-714`, `:672-691` |
| **The server side imposes no timeout on inbound request handling.** `_setupTimeout` is only called from `request()` (outbound). `_onrequest` only registers an `AbortController` and passes its signal to the handler. | `protocol.js:284-334`; `:714`; cancel handler `:170-176`, `:315` |
| Cancellation from the peer aborts the handler signal but does **not** terminate the handler promise. | `protocol.js:319-324` (signal exposed), no race/abort wrapper around the handler promise |
| Consequence: the 60 s SDK default does **not** bound `pi_delegate`/`pi_status` handling by Codex. Codex is a Rust/rmcp client, not this TS SDK (`rmcp::service`, `codex_rmcp_client` targets in Codex logs). | `protocol.js:6-8`; Codex log targets below |

### C. Codex host behavior (bounded local evidence)

Observed in `~/.codex` thread/log SQLite databases, read-only.

| Guarantee | Evidence |
| --- | --- |
| Codex enforces a **300 s** timeout on an MCP `tools/call`. | Sync `pi_delegate` item `created_at_ms=1789461974312`: `status:"failed"`, `durationMs:300005`, `error.message = "tool call error: tool call failed for \`pi-subagent/pi_delegate\` ... timed out awaiting tools/call after 300s"` |
| Completed sync `pi_delegate` calls returned normally under 300 s: durations 53 606 / 59 852 / 76 759 / 224 543 / 314 ms (all with `mode:"sync"`). | Same thread-item query (see Evidence map commands) |
| The host timeout does **not** stop the server-side Run. The timed-out sync Run `f482475e-3cb4-4a70-b05a-eced5c3fa4d8` was still `running` on three subsequent 25 s `pi_status` polls (~321 s, ~353 s, ~386 s after the original call) and later reported `status:"error"`. | `pi_status` items at `created_at_ms` 1789462292783, 1789462325281, 1789462358109, 1789463180830 |
| The host does **not** auto-redispatch after a sync timeout: the next actions were reasoning and `pi_status` polls of the same `runId`, not a new `pi_delegate`. | Same thread, ord 150 → 153 → 166/173/180/201 |
| Sequential 25 s `pi_status` long-polls work: 162 completed calls at `durationMs ≈ 25000` with `waitTimeoutMs:25000`. | `thread_items` query over all `pi_status` calls (see commands) |
| The async path also works and its runs are recoverable: `7ae5d17d-…` was launched with `mode:"async"`, polled with 25 s `pi_status`, and finally reported `status:"timeout"` after the server's own 600 000 ms deadline. Registry records `code:"timeout"`. | thread item at `created_at_ms=1789524450770`; final `pi_status` at `1789525284257`; `~/.pi-subagent/registry.json` session `wayfinder-transport-retry-20260916.lastError` |
| The `pi-subagent` MCP server has **no** `tool_timeout_sec` configured, so the 300 s value is its effective default. Other MCP servers demonstrate the key is configurable (3600, 349200, 600). | `~/.codex/config.toml:71-78` (no timeout); `:65` (only `tool_timeout_sec = 600.0`, on the disabled `agentling` server); plugin MCP JSONs |

## Documented-but-not-host-proven facts

- **"Host tool-call hard timeout 30 s"** (`src/tools/status.ts:38`): contradicted by the 300 s host evidence. This is an incorrect assumption, not a proven fact.
- **OpenAI async tool calling is application-managed with no server push** (`_refs.md`): documented by the official guides, consistent with observation, but it does not by itself state a Codex desktop timeout. No separate host test was run for it here.
- **1-minute then 3-minute `pi_status` waits** (accepted contract, `_grilling-decisions.md`, `_ultra-brief.md`): consistent with the 300 s cap but never exercised. Only 25 s waits are host-proven.
- **`waitForCompletion` timer semantics under an exact host timeout race** (e.g. wait ≈ 300 s): not tested.
- **Whether the host emits `notifications/cancelled` on its 300 s timeout:** not directly observed. Even if emitted, the server ignores the signal, and the run-continues evidence holds regardless. Label unresolved.

## Failure boundaries

1. **Host hard boundary — 300 s per MCP `tools/call`.** Any `pi_delegate` (sync) or `pi_status` wait that would exceed 300 s is aborted by the host. For sync, the Run is not cancelled server-side; the caller just loses the synchronous return.
2. **Server boundaries.** `runTimeoutMs` default 600 s and `stallTimeoutMs` default 300 s (`delegate.ts:86,271`). Because 600 s > 300 s and 300 s = 300 s, a long sync Run's terminal status is normally never delivered inside the pending call — the host boundary fires first.
3. **Long-poll boundary.** `status.ts` maps a wait expiry to `running`, so a caller must loop. A stale/evicted `runId` returns `not_found` or `runExpired` (`status.ts:33-35`); observed example: `pi_status` `durationMs:2`, result `{"error":"not found: run 91de8453-…","code":"not_found"}`.
4. **Async server timeout.** `7ae5d17d` ended `status:"timeout"` via the server's 600 s `runTimeoutMs` (not a host abort). This is the server's own deadline, distinct from the host 300 s cap.
5. **Transport drop.** Stdio disconnect closes pending `_onclose` handlers (SDK `_onclose` clears response handlers/timeouts, `protocol.js:243-262`); the server's CallTool handler is not cancelled and keeps running. Server process-level handlers prevent a crash from taking down all tools.

## Sync disconnect/no-redispatch rule

**Confirmed and should be kept, with one clarification.**

- On a sync host timeout/disconnect the host surfaces a tool-call error to the model; it does not automatically re-issue `pi_delegate`.
- The Run continues server-side and stays observable via `pi_status` on the **same** `runId`.
- Therefore the accepted rule ("never auto-redispatch; a new/async fallback Run requires an explicit Host-Session decision after the previous outcome is known") is correct. Clarification to add: before starting any new Run, the Host Session should first `pi_status` the timed-out `runId`, because the original Run may still be alive and will otherwise be duplicated.

## Sequential non-overlapping 1-minute then 3-minute fallback

- **Transport fit:** each wait must be < 300 s. The contract's 60 s and 180 s waits fit with margin; 180 s leaves ~120 s headroom.
- **Host-proven today:** only sequential 25 s waits (162 successful, ~25.0 s each). No 60 s or 180 s `pi_status` wait has been executed.
- **Sequential:** observed schedules are ordered and non-overlapping within a single Host Session. One apparent overlap pair was across two different threads/runIds (`5d36ae83…` thread `01a080cd…` vs `005e03ac…` thread `01a080d8…`), i.e. two concurrent sessions, not one session overlapping its own fallback.
- **Non-overlap is not transport-enforced:** `codex_core::tools::parallel` exists and parallel tool calls are possible. "Never overlapping" must stay an explicit Host-Session constraint.
- **Timing:** polling is opportunistic, not a continuous monitor. In the `7ae5d17d` async case the Host Session had a ~10-minute gap between the last 25 s poll of one turn and the next turn's poll; the Run had already timed out server-side by then. The contract must not assume uninterrupted coverage.

## Evidence map

### Required inputs and source facts

- `src/tools/delegate.ts:84` — `const mode = input.mode ?? "async";` (AI-Projects HEAD `174cf17`). **Live deployed variant differs:** `C:\Users\qnhxx\Documents\Codex\tools\pi-subagent\src\tools\delegate.ts:84` is `?? "sync"`.
- `src/tools/delegate.ts:86` — `runTimeoutMs ?? 600000`.
- `src/tools/delegate.ts:271` — `stallTimeoutMs ?? 300000`; `:319` `// sync 模式：阻塞到 finalize`.
- `src/runner/spawn.ts:112-121` — `runTimeoutMs` → `SIGTERM`, then `SIGKILL` after 5 s.
- `src/tools/status.ts:38` (comment claiming 30 s host cap), `:40` (`waitTimeoutMs ?? 25000`), `:41-43` (`waitMs===0` → running), `:44-46` (undefined → running).
- `src/registry/run.ts:95-113` — `waitForCompletion` resolves on complete or timer.
- `src/server.ts` — `CallToolRequestSchema` handler; never consumes `extra.signal`; process-level `uncaughtException`/`unhandledRejection` guards.
- `node_modules/@modelcontextprotocol/sdk/dist/esm/shared/protocol.js:6-8` — `DEFAULT_REQUEST_TIMEOUT_MSEC = 60000`.
- `protocol.js:284-334` — `_onrequest` registers `AbortController`, passes `signal`, no inbound timeout.
- `protocol.js:712-714` — timeout set only on outbound `request()`; `protocol.js:170-176` — cancellation aborts registered controller.

### Codex host configuration

- `~/.codex/config.toml:71-78` — `[mcp_servers.pi-subagent]` with command/args/env only, **no `tool_timeout_sec`**.
- `~/.codex/config.toml:65` — `tool_timeout_sec = 600.0` belongs to `[mcp_servers.agentling_paper_translator]` (`enabled = false`).
- Bounded grep shows other MCP configs set `tool_timeout_sec` (`codex-app-tools` 3600, `codex-security` 349200), proving configurability.

### Codex host run evidence (read-only commands)

```bash
# 300 s host timeout on a sync pi_delegate
cd ~/.codex && python -c "
import sqlite3,json
con=sqlite3.connect('file:thread_history_1.sqlite?mode=ro',uri=True)
r=con.execute('select item_json from thread_items where created_at_ms=1789461974312 and item_json like \"%pi_delegate%\"').fetchone()
j=json.loads(r[0]); print(j['status'], j['durationMs'], j['error']['message'])"
# => failed 300005 tool call error: tool call failed for `pi-subagent/pi_delegate`
#    Caused by: timed out awaiting tools/call after 300s

# completed sync calls stay under 300 s: 53606, 59852, 76759, 224543, 314 ms
# run survives the host timeout: same runId still "running" via pi_status at
#   created_at_ms 1789462292783 / 1789462325281 / 1789462358109, then "error" at 1789463180830

# all pi_status calls: 164 total; 162 completed at durationMs ~25000 with waitTimeoutMs 25000
```

- Registry: `~/.pi-subagent/registry.json`, session `wayfinder-transport-retry-20260916` → `status:"error"`, `lastError {code:"timeout", runId:"7ae5d17d-ec27-4713-8fc6-8447311cc45f", ts:1789525055788}`. Runs are not persisted in `registry.json` (top-level keys are `version`, `sessions`).
- Live-vs-source caveat: the configured service is `C:\Users\qnhxx\Documents\Codex\tools\pi-subagent\dist\server.js` (git HEAD `21fe334` with modified `src/*`), not the AI-Projects checkout (HEAD `174cf17`). `src/tools/status.ts` is identical between the two; `server.ts`/`delegate.ts` differ only in the default mode (`sync` live vs `async` in the checkout source). The host evidence above is independent of that difference because the failing call passed `mode:"sync"` explicitly.

## Reproduction status

- Performed: read-only file reads; `git status` / `git rev-parse`; `diff` of the two checkouts; read-only SQLite queries (`mode=ro`) against `~/.codex/thread_history_1.sqlite` and `~/.codex/logs_2.sqlite`; `grep` over `~/.codex` config/plugin JSON.
- Not performed: **no live host experiment was run.** Producing a fresh 300 s timeout or a 60 s / 180 s `pi_status` wait would require a deliberate long-running Run and a live Codex session; this investigator is read-only and did not start or mutate any Run, config, registry, or service.
- Product state: unchanged. AI-Projects checkout `git status --porcelain` shows only pre-existing untracked entries (`.scratch/`, `AGENTS.md`, `CONTEXT.md`, `docs/adr/`, `docs/agents/`); no tracked file modified by this investigation. Deployed checkout was inspected read-only.

## Remaining gaps

1. **No host experiment for >25 s `pi_status` waits.** The 60 s / 180 s fallback waits are inferred-safe (both < 300 s) but unverified on this host. Exact evidence gap: no `pi_status` `tools/call` in the thread history with `waitTimeoutMs` > 25000 or `durationMs` > ~25 000 except the one 300 005 ms host timeout on `pi_delegate`.
2. **Whether the host sends `notifications/cancelled` on its 300 s timeout** is unknown; observationally the server ignores it either way, and the Run continues.
3. **The 300 s value's exact origin** (rmcp hard default vs an unexposed Codex default) is not read from a Codex config schema/doc; it is the effective value for `pi-subagent` with no `tool_timeout_sec`, corroborated by other servers overriding it.
4. **Behavior when the server's own `runTimeoutMs`/`stallTimeoutMs` is deliberately set near 300 s** (the race boundary) is untested.
5. **The accepted 1-/3-minute schedule's non-overlap** under an autonomous multi-tool host turn is a policy guarantee; the transport permits overlap (parallel tool calls). Validation depends on Host-Session behavior, not this server.
