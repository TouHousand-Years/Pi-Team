# 02 — Inventory of the Pi lossless event surface

Scope: what the **installed first-party Pi** actually emits across the process boundary when driven
the way `pi-subagent` drives it (`-p <prompt> --mode json`), and the deterministic rules that let a
Transcript preserve every process-boundary byte without inventing hidden reasoning or duplicating
assistant output.

- Installed Pi: **`pi --version` → `0.85.1`**
  (`C:\Users\qnhxx\AppData\Roaming\npm\node_modules\@earendil-works\pi-coding-agent`, bin → `dist/bundle/cli.js`).
- Repo checkout under study: `C:\Users\qnhxx\Documents\AI-Projects\Code\pi-subagent` @ `174cf17`.
- Method: read-only source/doc inspection of the installed package + bounded **offline** local runs
  against an in-process mock OpenAI-completions SSE server (`PI_OFFLINE=1`,
  `PI_CODING_AGENT_DIR=<OS-temp>/agent`, `--no-skills --no-context-files`). No network, no writes to
  the live `~/.pi/agent`, no product-file changes.
- Abbreviations below: `<PI>` = the installed package root.

---

## 1. Answer in one page

1. **Pi is the single, complete source of run content.** In `--mode json`, Pi takes over stdout
   (`<PI>/dist/main.js:502-506` → `takeOverStdout()`), reserves it for NDJSON, and redirects all
   incidental `process.stdout.write` to stderr (`<PI>/dist/core/output-guard.js:38-57`). So the
   Transcript can be built from **stdout NDJSON + stderr diagnostics + exit code/signal** and nothing
   is silently duplicated onto the other channel.
2. **Everything a run does is on stdout as complete JSON lines.** Every line is a whole
   `JSON.stringify(...) + "\n"` (`<PI>/dist/modes/print-mode.js:86,100`), serialized through a single
   promise chain (`<PI>/dist/core/output-guard.js:67-75`). Normal operation never emits a partial line.
3. **Content is repeated across several envelopes.** The delta stream (`message_update`), the
   authoritative `message_end`, `turn_end`, and `agent_end.messages` all carry the same text/tool
   payloads. A naive "print every field" renderer quadruple-prints assistant output. §5 gives the
   canonical dedup rules.
4. **Exit code is not a failure signal in JSON mode.** Provider/model errors are emitted as JSON
   `message_end` with `stopReason:"error"` and **exit code 0** (`http401`, `content_filter`,
   `malformed` cases). Only *pre-run startup* failures exit 1 (with empty stdout, stderr `Error: …`).
5. **Hidden reasoning is never emitted.** There is no event for the system prompt, context files,
   skills, tool schemas, or the model's private chain-of-thought. `thinking_*` only appears when the
   provider streams it (or a `redacted` block), and it is *observable* reasoning, not hidden. A
   Transcript must therefore record argv/cwd/env itself and must not claim to show hidden internals.
6. **The repo's committed fixture is stale.** `test/fixtures/pi-output-echo.jsonl` predates the
   delta-only change (Pi **0.84.0**, `<PI>/CHANGELOG.md:300`); it contains cumulative
   `message_update.message` and `partial` fields that 0.85.1 no longer emits. See §7.

---

## 2. How the surface is produced (first-party mechanics)

| Mechanic | Location | Consequence for a lossless reader |
| --- | --- | --- |
| `--mode json` → `appMode = "json"`, non-interactive | `<PI>/dist/main.js:87-98` | `resolveAppMode` picks json when `--mode json`; else print when `-p`/non-TTY |
| `takeOverStdout()` before run | `<PI>/dist/main.js:502-506` | incidental stdout → stderr; stdout is pure NDJSON |
| `reportDiagnostics` → stderr | `<PI>/dist/main.js:68-75` | `Error: ` / `Warning: ` prefixes, `console.error` |
| Session header first, then `session.subscribe` | `<PI>/dist/modes/print-mode.js:84-100` | header is emitted **once**, before any agent event |
| Each event → `writeRawStdout(JSON.stringify(toJsonEvent(e)) + "\n")` | `<PI>/dist/modes/print-mode.js:84-92` | atomic, newline-terminated lines; backpressure awaited |
| `toJsonEvent` strips `partial`, injects `toolcall_start.id`/`toolName` | `<PI>/dist/modes/json-event.js:1-25` | wire format differs from raw event objects |
| pi-ai `start`/`done`/`error` are **not** `message_update` | `<PI>/node_modules/.../pi-agent-core/dist/agent-loop.js:199-224` | `assistantMessageEvent.type ∈ {text_*, thinking_*, toolcall_*}` only |

Full raw-event unions (installed 0.85.1):
- `AgentEvent` — `<PI>/node_modules/@earendil-works/pi-agent-core/dist/types.d.ts:~300-377`.
- `AgentSessionEvent` (superset, adds the session-level events) — `<PI>/dist/core/agent-session.d.ts:39-103`.
- `AssistantMessageEvent` — `<PI>/node_modules/@earendil-works/pi-ai/dist/types.d.ts:~410`.
- `docs/json.md` — `<PI>/docs/json.md:18-91`.

---

## 3. Event coverage matrix

Legend — **Reproduced**: confirmed by a bounded local run in this investigation.
**Source-only**: reachable in print/json mode but not triggered offline here (recorded from the
emitting source). **Not in JSON mode**: different Pi mode.

### 3.1 stdout NDJSON — session lifecycle

| Wire `type` | Key fields observed | Emitted when | Status | Evidence |
| --- | --- | --- | --- | --- |
| `session` | `version:3, id, timestamp, cwd, parentSession?` | once, first line of every print/json run | **Reproduced** | happy run L0; fork header §4.6 |
| `agent_start` | `{}` | run begins | **Reproduced** | happy run L1 |
| `agent_settled` | `{}` | after `agent_end`, session idle (extension runner then bus) | **Reproduced** (not in `docs/json.md` example) | happy run L36; `<PI>/dist/core/agent-session.js:350-351` |
| `agent_end` | `messages:[…], willRetry:false` | agent loop terminal | **Reproduced** | happy run L35 |
| `turn_start` | `{}` | each model turn | **Reproduced** | happy run L2, L27 |
| `turn_end` | `message, toolResults` | each turn closes | **Reproduced** | happy run L26, L34 |
| `queue_update` | `steering:[…], followUp:[…]` | steering/follow-up queue changes | Source-only | `<PI>/dist/core/agent-session.js:318-322`; `<PI>/docs/json.md:31` |
| `compaction_start` / `compaction_end` | `reason`(manual/threshold/overflow), `result`, `aborted`, `willRetry`, `errorMessage` | manual or threshold compaction | Source-only | `<PI>/dist/core/agent-session.js:1477,1566-1874`; `<PI>/docs/json.md:31` |
| `auto_retry_start` / `auto_retry_end` | retry metadata | transient provider auto-retry | Source-only | `<PI>/dist/core/agent-session.js:412,798,2299-2320` |
| `summarization_retry_scheduled` / `_attempt_start` / `_finished` | — | branch-summary retry | Source-only | `<PI>/dist/core/agent-session.js:2264-2278` |
| `thinking_level_changed` | `level` | **only when the level actually changes mid-session** | Source-only (tried `--thinking high`: no event) | `<PI>/dist/core/agent-session.js:1372` |
| `session_info_changed` | `name` | `setSessionName` called (e.g. extension) | Source-only | `<PI>/dist/core/agent-session.js:2453` |
| `entry_appended` | `entry` | extension `appendEntry` (custom entry) only | Source-only | `<PI>/dist/core/agent-session.js:2029-2034` |
| `bash_execution_update` | `id, delta` | user-initiated bash streaming (executeBash) | Source-only | `<PI>/dist/core/agent-session.js:2375` |
| `response` / `extension_ui_request` / `extension_error` | — | **RPC mode only** | Not in JSON mode | `<PI>/dist/modes/rpc/*` |

### 3.2 stdout NDJSON — messages & streaming deltas

| Wire `type` | Key fields observed | Status | Evidence |
| --- | --- | --- | --- |
| `message_start` (role=user) | `message{role,content:[{type:text,text}],timestamp}` | **Reproduced** | happy run L3; submitted prompt is echoed here |
| `message_start` (role=assistant) | `message{api,provider,model,usage,stopReason,content:[…]}` — **content may already contain the first delta** (shared mutable partial) | **Reproduced** | happy run L5/L6; `<PI>/node_modules/.../pi-ai/dist/types.d.ts:403` |
| `message_end` (role=assistant) | authoritative final message incl. `usage`, `stopReason`, `errorMessage`, `rawStopReason` | **Reproduced** | happy run L19; error run Lx |
| `message_start` / `message_end` (role=toolResult) | `toolCallId, toolName, content, details, isError, usage?, timestamp` | **Reproduced** | happy run L24-25 |
| `message_update` | top-level `usage` + `assistantMessageEvent` (**no** `message`, **no** `partial`) | **Reproduced** | happy run L6-18; `<PI>/docs/json.md:87-91` |
| ↳ `text_start` | `contentIndex` | **Reproduced** | L9 |
| ↳ `text_delta` | `contentIndex, delta` | **Reproduced** | L10-11 |
| ↳ `text_end` | `contentIndex, content` (full block) | **Reproduced** | L17 |
| ↳ `thinking_start` | `contentIndex` | **Reproduced** | L6 |
| ↳ `thinking_delta` | `contentIndex, delta` | **Reproduced** | L7-8 |
| ↳ `thinking_end` | `contentIndex, content` (full block) | **Reproduced** | L16 |
| ↳ `toolcall_start` | `contentIndex, id, toolName` (id/name injected by `toJsonEvent`) | **Reproduced** | L12; `<PI>/dist/modes/json-event.js:2-9` |
| ↳ `toolcall_delta` | `contentIndex, delta` (argument JSON fragments) | **Reproduced** | L13-15 |
| ↳ `toolcall_end` | `contentIndex, toolCall{id,name,arguments}` | **Reproduced** | L18 |
| ↳ `start` / `done` / `error` | never surfaced as `message_update` | n/a | `agent-loop.js:199-224` maps them to `message_start`/`message_end` |

### 3.3 stdout NDJSON — tool execution

| Wire `type` | Key fields observed | Status | Evidence |
| --- | --- | --- | --- |
| `tool_execution_start` | `toolCallId, toolName, args` | **Reproduced** | happy run L20; error run L10 |
| `tool_execution_update` | `toolCallId, toolName, args, partialResult{content,details}` | **Reproduced** (bash) | happy run L21-22 |
| `tool_execution_end` | `toolCallId, toolName, result{content:[{type:text,text}],details}, isError` | **Reproduced** both `false` and `true` | happy run L23; error run L12 (`isError:true`, text `"(no output)\n\nCommand exited with code 3"`) |

### 3.4 Reasoning-related surface

| Item | Where | Status | Evidence |
| --- | --- | --- | --- |
| `thinking_start/delta/end` | `message_update.assistantMessageEvent` | **Reproduced** | happy run L6-8, L16 |
| `ThinkingContent.thinkingSignature?`, `redacted?` | content block | Source-only (not produced by the mock) | `<PI>/node_modules/.../pi-ai/dist/types.d.ts` (`ThinkingContent`) |
| Redacted thinking may be complete at `thinking_start` and emit **no deltas** | doc comment | Source-only | `<PI>/node_modules/.../pi-ai/dist/types.d.ts:406` |
| `usage.reasoning?` token breakdown | top-level `message_update.usage`, `message_end.message.usage` | **Reproduced** field present (0 in mock) | happy run L6-18 |
| Provider reasoning extraction | first non-empty of `reasoning_content` / `reasoning` / `reasoning_text` → `thinking_*` | **Reproduced** (mock used `reasoning_content`) | `<PI>/node_modules/.../pi-ai/dist/api/openai-completions.js` |
| Hidden chain-of-thought | — | **never emitted** | no such event in any union |

### 3.5 stderr diagnostics

| Kind | Literal shape | Status | Evidence |
| --- | --- | --- | --- |
| Startup diagnostic | `Error: Model "nosuchprovider/nosuchmodel" not found. Use --list-models to see available models.` | **Reproduced** (exit 1, stdout empty) | §4.4 |
| Startup diagnostic | `Error: Session id must be non-empty, contain only alphanumeric characters, '-', '_', and '.', and start and end with an alphanumeric character` | **Reproduced** (exit 1, stdout empty) | §4.4 |
| No-models guidance | `Error: <formatNoModelsAvailableMessage()>` | Source-only | `<PI>/dist/main.js:734-737`, `<PI>/dist/core/auth-guidance.js` |
| Provider SSE JSON parse | `Could not parse message into JSON: …` + `From chunk: …` (then stream aborts) | **Reproduced** | §4.3; `<PI>/node_modules/openai/core/streaming.js:60` |
| Print-mode uncaught | `console.error(error.message)` then exit 1 | Source-only | `<PI>/dist/modes/print-mode.js:131` |
| Extension error | `Extension error (<extensionPath>): <error>` | Source-only | `<PI>/dist/modes/print-mode.js:79` |
| Text-mode provider error | printed to stderr **only in `--mode text`** | Not in JSON mode | `<PI>/dist/modes/print-mode.js:112-118` |
| Incidental stdout | redirected to stderr by `takeOverStdout` | Source-only | `<PI>/dist/core/output-guard.js:38-57` |

### 3.6 Terminal signals

| Signal | Pi behavior | Status | Evidence |
| --- | --- | --- | --- |
| Normal completion | `runPrintMode` returns 0 | **Reproduced** | all mock cases `EXIT code=0` |
| Model/provider error in JSON | JSON error events, **exit 0** | **Reproduced** | §4.3 `http401`, `content_filter`, `malformed` |
| SIGTERM | kill tracked detached children → dispose → `process.exit(143)`; **no terminal JSON** | **Reproduced** (partial stdout, `signal=SIGTERM`/`code=null` on Windows; handler would exit 143 elsewhere) | `<PI>/dist/modes/print-mode.js:31-45`; §4.3 |
| SIGHUP (non-win32) | same path, `exit(129)` | Source-only | `<PI>/dist/modes/print-mode.js:40` |
| SIGINT | no handler → Node default termination (exit ≈130) | Source-only (inference from absent handler) | `print-mode.js` registers only TERM/HUP |
| Startup failure | stderr diagnostic, exit 1, **no stdout** | **Reproduced** | §4.4 |
| stdout write failure (EPIPE/EBADF) | `writeRawStdout` tail catches → `process.exit(1)`, silent | Source-only | `<PI>/dist/core/output-guard.js:67-75` |

---

## 4. Exact representative emissions

All raw lines below are unedited captures from the bounded offline runs (mock provider
`mockprovider/mock-model`, `PI_OFFLINE=1`). Experiment dir:
`%LOCALAPPDATA%\Temp\tmp.i1ni2fXCAr` (driver `driver.mjs` / `driver2.mjs`).

### 4.1 Happy path — canonical ordered sequence (37 stdout lines, exit 0, stderr empty)

```
L0  {"type":"session","version":3,"id":"…","timestamp":"…","cwd":"…"}
L1  {"type":"agent_start"}
L2  {"type":"turn_start"}
L3  {"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"Please run the echo command."}],…}}
L4  {"type":"message_end","message":{"role":"user",…}}
L5  {"type":"message_start","message":{"role":"assistant",…}}
L6  {"type":"message_update","usage":{…},"assistantMessageEvent":{"type":"thinking_start","contentIndex":0}}         ← message_start already held the first thinking chunk
L7  {"type":"message_update",…,"assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"Let me think about this. "}}
L8  {"type":"message_update",…,"assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"I should echo."}}
L9  {"type":"message_update",…,"assistantMessageEvent":{"type":"text_start","contentIndex":1}}
L10 {"type":"message_update",…,"assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"I will run "}}
L11 {"type":"message_update",…,"assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"echo now."}}
L12 {"type":"message_update",…,"assistantMessageEvent":{"type":"toolcall_start","contentIndex":2,"id":"call_1","toolName":"bash"}}
L13 {"type":"message_update",…,"assistantMessageEvent":{"type":"toolcall_delta","contentIndex":2,"delta":""}}
L14 {"type":"message_update",…,"assistantMessageEvent":{"type":"toolcall_delta","contentIndex":2,"delta":"{\"command\":"}}
L15 {"type":"message_update",…,"assistantMessageEvent":{"type":"toolcall_delta","contentIndex":2,"delta":"\"echo HI\"}"}}
L16 {"type":"message_update",…,"assistantMessageEvent":{"type":"thinking_end","contentIndex":0,"content":"Let me think about this. I should echo."}}
L17 {"type":"message_update",…,"assistantMessageEvent":{"type":"text_end","contentIndex":1,"content":"I will run echo now."}}
L18 {"type":"message_update",…,"assistantMessageEvent":{"type":"toolcall_end","contentIndex":2,"toolCall":{"id":"call_1","name":"bash","arguments":{"command":"echo HI"}}}}
L19 {"type":"message_end","message":{"role":"assistant","content":[thinking,text,toolCall],"stopReason":"toolUse","usage":{…},…}}
L20 {"type":"tool_execution_start","toolCallId":"call_1","toolName":"bash","args":{"command":"echo HI"}}
L21 {"type":"tool_execution_update","toolCallId":"call_1","toolName":"bash","args":{…},"partialResult":{"content":[{"type":"text","text":"HI\n"}],"details":{}}}
L22 {"type":"tool_execution_update",…}
L23 {"type":"tool_execution_end","toolCallId":"call_1","toolName":"bash","result":{"content":[{"type":"text","text":"HI\n"}],"details":{}},"isError":false}
L24 {"type":"message_start","message":{"role":"toolResult","toolCallId":"call_1","toolName":"bash","content":[{"type":"text","text":"HI\n"}],"isError":false,…}}
L25 {"type":"message_end","message":{"role":"toolResult",…}}
L26 {"type":"turn_end","message":{assistant…},"toolResults":[{toolResult…}]}
L27 {"type":"turn_start"}
L28 {"type":"message_start","message":{"role":"assistant",…}}
L29 {"type":"message_update",…,"assistantMessageEvent":{"type":"text_start","contentIndex":0}}
L30 {"type":"message_update",…,"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"The command "}}
L31 {"type":"message_update",…,"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"printed HI."}}
L32 {"type":"message_update",…,"assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"The command printed HI."}}
L33 {"type":"message_end","message":{assistant…}}
L34 {"type":"turn_end","message":{assistant…},"toolResults":[]}
L35 {"type":"agent_end","messages":[user,assistant,toolResult,assistant],"willRetry":false}
L36 {"type":"agent_settled"}
```

Note the **double emission** of the answer text: `text_delta` (L30-31) → `text_end.content` (L32) →
`message_end.message` (L33) → `turn_end.message` (L34) → `agent_end.messages[3]` (L35). Same payload,
five envelopes. Tool output: `tool_execution_end` (L23) → `toolResult` `message_start`/`message_end`
(L24-25) → `turn_end.toolResults` (L26) → `agent_end.messages[2]` (L35).

### 4.2 Thinking start may already carry text

`L6` is `thinking_start` but `message_start` (L5) already contained
`"thinking":"Let me think about this. "`. This is the shared-mutable-partial hazard documented at
`<PI>/node_modules/.../pi-ai/dist/types.d.ts:403` ("`partial` is the shared live response-so-far
helper, not an event-time snapshot"). **Consequence:** `message_start` content is not a reliable
empty baseline; only `*_start` + `*_delta` + `*_end` (and the authoritative `message_end`) define
content.

### 4.3 Failure / abnormal cases (all exit 0 unless stated)

`http401` (server → HTTP 401 JSON): stdout is a full lifecycle; assistant `message_end` carries
`"stopReason":"error"`, `"errorMessage":"401: {…}"`, `"rawStopReason":…`; then `turn_end`,
`agent_end`, `agent_settled`. **stderr empty. Exit 0.**

`content_filter`: text deltas emit, then `message_end` `stopReason:"error"` + `errorMessage` +
`rawStopReason`. stderr empty. Exit 0.

`malformed` (invalid JSON inside an SSE `data:` line) — **both channels fire**:
```
stderr: Could not parse message into JSON: {bad
        From chunk: …
stdout: … message_end with stopReason:"error" …
exit 0
```
Source: `<PI>/node_modules/openai/core/streaming.js:41-60` (logs then rethrows → stream error →
Pi emits an error assistant message).

`sigterm` (stream held open, parent sends SIGTERM after 2s): stdout is **truncated mid-lifecycle**
(no `agent_end`/`agent_settled`); Windows reports `signal=SIGTERM, code=null`. On non-win32 the
handler would `process.exit(143)` (`<PI>/dist/modes/print-mode.js:31-45`).

### 4.4 Startup failures (exit 1, stdout empty)

```
$ pi -p … --mode json --model nosuchprovider/nosuchmodel   # isolated config
exit=1  stdout=(empty)
stderr: Error: Model "nosuchprovider/nosuchmodel" not found. Use --list-models to see available models.

$ pi -p … --mode json --session-id 'not a valid id'
exit=1  stdout=(empty)
stderr: Error: Session id must be non-empty, contain only alphanumeric characters, '-', '_', and '.',
        and start and end with an alphanumeric character
```
These are `reportDiagnostics` on stderr (`<PI>/dist/main.js:68-75`) plus `runtimeErrors → exit 1`
(`<PI>/dist/main.js:721-731`).

### 4.5 Tool error (`isError:true`) still exits 0

`toolerror` case (model calls `bash` with `{"command":"exit 3"}`):
```
L10 {"type":"tool_execution_start","toolName":"bash","args":{"command":"exit 3"}}
L11 {"type":"tool_execution_update",…}
L12 {"type":"tool_execution_end",…,"result":{"content":[{"type":"text","text":"(no output)\n\nCommand exited with code 3"}],"details":{}},"isError":true}
… L13 toolResult message_start/message_end … L17-21 second model turn … L23 agent_end, L24 agent_settled
exit 0, stderr empty
```
A failing tool is **not** a failing run; the model sees the error and continues.

### 4.6 Session header variants

Continuation (`--session-id <existing>`): fresh header with the **same id**, new `timestamp`, and
**no replay** of prior messages — each Run's stdout is self-contained.

Fork (`--mode json --fork <id>`, no prompt):
```
{"type":"session","version":3,"id":"<NEW id>","timestamp":"…","cwd":"…","parentSession":"…\\sessions\\…jsonl"}
```
i.e. a new id plus `parentSession`. `SessionHeader` at
`<PI>/dist/core/session-manager.d.ts:5-15`; fork path at `session-manager.js:1280-1295`.

### 4.7 Repo-side parsing tests (non-mutating) confirm capture contract

`test/spawn.test.ts`: `collectOutput` returns one entry per stdout line, keeps the stderr tail, and
survives an injected stream `'error'` (EPIPE simulation). `src/runner/spawn.ts` splits on `\n` and
flushes a trailing `pending` fragment at `done`. So a **partial trailing line is captured**, and a
whitespace-only line is dropped (`if (line.trim())`) — the only silent local omission.

---

## 5. Deterministic formatting & dedup rules

Goal: render every process-boundary byte exactly once in the Transcript window, while keeping all
raw lines available for lossless export.

**R0 — Sources.** Transcript = stdout NDJSON lines (ordered, verbatim) + stderr text (ordered) +
`exitCode`/`signal`. Never synthesize a third channel.

**R1 — Raw journal is append-only.** Store every stdout line and every stderr chunk verbatim before
any formatting. Formatting/dedup applies only to the derived display view, never to the journal.

**R2 — Single content authority per assistant message.** An assistant message's content is assembled
from `message_update` deltas inside its `message_start … message_end` span, keyed by
`(type=assistant, contentIndex, block kind)`. `text_end`/`thinking_end.content` reconcile that
buffer (replace, not append). Never render text from `message_end.message.content`,
`turn_end.message.content`, or `agent_end.messages[].content` as additional lines.

**R3 — `message_start` is a marker, not a baseline.** Its `content` may already contain a first delta
(§4.2), so do not treat it as the authoritative prefix.

**R4 — Tool results rendered from `tool_execution_end`.** Render `tool_execution_end.result`
(and `tool_execution_update.partialResult` as a live region). Suppress the later role=`toolResult`
`message_start`/`message_end`, `turn_end.toolResults`, and the `agent_end.messages` toolResult copy.

**R5 — Tool calls rendered once.** Render from `toolcall_start`/`toolcall_delta` (streaming) and/or
`toolcall_end.toolCall` (final). Do not also render `tool_execution_start.args` or the toolCall
inside `message_end`/`turn_end`/`agent_end` as separate content.

**R6 — `turn_end` and `agent_end` are structural markers.** Render only their metadata
(`stopReason`, `usage`, `willRetry`, `toolResults.length`, `messages.length`). `agent_end.messages`
is a **replay of already-rendered turns** — use it only to reconcile/repair a message whose deltas
were lost (replace-by-id), never to append.

**R7 — `usage` printed once.** `message_update.usage` is cumulative and repeated on every delta; show
only the latest. `message_end.message.usage` is the authoritative final value.

**R8 — No cross-run merging.** Each Run's stdout starts with its own `session` header and does not
replay prior turns (§4.6). A Transcript is bounded to one process invocation; continuation/fork
produce a *new* Transcript linked by `id`/`parentSession`, not appended messages.

**R9 — Final answer ≠ concatenation.** Multiple assistant messages exist per run (tool-use turns +
final). Any "result" summary must reference the **last** assistant text block; the MCP tool response
`result` must not re-print what the Transcript window already rendered (that is the current
double-surface risk: `Run.result` + `Run.progress` + events).

**R10 — Unknown/extra types are never dropped.** Render `[event <type>]` + compact JSON, keep raw
line, and mark the window as "partial support" so future Pi events degrade visibly rather than
disappear.

**R11 — Partial/last line.** A trailing fragment without `\n` is kept and flagged `partial:true`; it
may be parsed best-effort but is never authoritative and never counted as a terminal event.

**R12 — Preserve submitted inputs from the parent.** The prompt is echoed as the user
`message_start/end`, but argv (prompt text as typed, `--tools/--exclude-tools/--thinking/--model/
--no-skills/--no-context-files`), cwd, session id, and env are **not** in Pi's output. Record them
from the spawn boundary so the Transcript can state exactly what was submitted without pretending
Pi disclosed its system prompt or context files.

---

## 6. Malformed / partial / capture-failure handling

| Situation | What Pi does | Detection rule | Transcript behavior |
| --- | --- | --- | --- |
| Malformed provider SSE JSON | stderr parse warning + stream abort → assistant `message_end stopReason:"error"`; exit 0 | `stopReason==="error"` and/or stderr matched | Render the error assistant message **and** attach the stderr block; do not mark process failed on exit code alone |
| Provider HTTP error (4xx/5xx) | JSON `message_end stopReason:"error"`; exit 0 | same | Same |
| Tool error | `tool_execution_end.isError:true`; run continues | `isError===true` | Render tool error inline; run is still successful if `agent_end`/`agent_settled` present and exit 0 |
| SIGTERM / SIGHUP | no terminal JSON; dispose; exit 143/129 | stream ended with no `agent_end`/`agent_settled` | Mark Transcript `incomplete`, record `signal`, keep all received lines |
| SIGINT | Node default termination | no terminal event, signal/exit ≈130 | Same |
| Startup failure | exit 1, stdout empty, stderr `Error: …` | exit≠0 and zero stdout lines | Render stderr as the whole Transcript; no events |
| stdout write failure / broken pipe | silent `process.exit(1)` | exit 1 with truncated stream, no stderr | Mark `incomplete`, record exit code |
| Spawn error (bad `PI_BIN`) | no process stdout | child `'error'` | Record `spawnError`; never fabricate events |
| Unknown wire type | — | unrecognized `type` | R10: keep raw + placeholder |
| Blank stdout line | not emitted by Pi | — | Repo's `collectOutput` drops it; acceptable, but note it in the journal contract |
| Trailing fragment without newline | only on kill/pipe-loss | line lacks `\n` at stream end | R11: keep, flag partial, parse best-effort |

**Completeness test for a Transcript:** complete ⇔ last stdout event ∈ {`agent_end` followed by
`agent_settled`} **and** `signal == null`. Otherwise `incomplete` regardless of exit code. Exit code
is a *secondary* signal because JSON-mode provider/tool errors exit 0.

---

## 7. Conflicts with the current repo

1. **Stale fixture / wire-format skew.** `test/fixtures/pi-output-echo.jsonl` contains
   `message_update.message` and `assistantMessageEvent.partial` (cumulative snapshot). Installed
   0.85.1 strips both (`<PI>/dist/modes/json-event.js:6-15`; documented change in
   `<PI>/CHANGELOG.md:300`, Pi **0.84.0**). `docs/json.md:87-91` matches 0.85.1, not the fixture.
   A parser that relies on `partial`/`message` will silently render nothing on 0.85.1; a parser that
   relies on deltas works on both. **Use deltas + `message_end` reconciliation (R2).**
2. **Lossy parsing today.** `src/runner/parse.ts` keeps content only for `session`,
   `tool_execution_end`, and `agent_end`; every `message_update`/`message_*`/`turn_*` is reduced to
   its `type`. Reasoning, streaming text, and tool-call arguments are discarded → the current
   `progress[]` cannot be a lossless transcript.
3. **Redaction/truncation in the only content channel today.** `src/registry/redact.ts` masks
   20+-char tokens and truncates summaries to 200 chars; `ProgressEvent.summary` is
   "redaction, 200 chars" (`src/types.ts:15-19`). That is fundamentally at odds with a lossless
   Transcript; lossless raw capture must sit *below* any redacted summary view.
4. **`PI_BUILTIN_TOOLS` is incomplete.** `src/types.ts` lists only `read|bash|edit|write`, while
   0.85.1 has more built-ins — relevant if the Transcript labels tool types.
5. **Dual answer surface.** `Run.result` (last assistant text) plus the raw event stream means the
   final answer can appear twice in any UI that shows both. Governed by R9.

---

## 8. Unknowns / evidence gaps (honestly bounded)

- `queue_update`, `compaction_*`, `auto_retry_*`, `summarization_retry_*`, `thinking_level_changed`,
  `session_info_changed`, `entry_appended`, `bash_execution_update` are **source-confirmed but not
  reproduced** here (they need live servers, retries, extension calls, or compaction thresholds).
  Their *shape* is taken from the emitting source lines listed in §3.1; treat as high-confidence,
  not byte-verified.
- Redacted-thinking (`redacted:true`, zero deltas) and image content blocks were not produced by the
  offline mock. Behavior is code-documented (`types.d.ts:406`).
- SIGINT exit semantics on Windows were not exercised; the claim is inference from the absence of a
  handler.
- Anthropic/Responses/Gemini provider event mapping was not exercised; only `openai-completions`
  (`<PI>/node_modules/.../pi-ai/dist/api/openai-completions.js`) was. The provider→wire mapping for
  other APIs may differ in `usage`/`stopReason` detail but not in the Pi-level event names.

---

## 9. Reproduction status & commands

Installed: `pi --version` → `0.85.1`. Node `v24.19.0`.

Offline harness (temp only): mock OpenAI-completions SSE server; isolated config via
`PI_CODING_AGENT_DIR=<temp>/agent` with a `mockprovider/mock-model` entry and empty settings;
`PI_OFFLINE=1`. Drivers: `driver.mjs` (happy path), `driver2.mjs`
(`toolerror|thinking|continuation|http401|content_filter|malformed|sigterm`), direct CLI for
`--fork` and startup-failure cases.

| Case | Command shape | Result |
| --- | --- | --- |
| happy | `pi -p … --mode json --model mockprovider/mock-model --no-skills --no-context-files --tools bash` | exit 0, 37 stdout lines, stderr empty (4.1) |
| toolerror | same + model calls `bash 'exit 3'` | exit 0, `isError:true` (4.5) |
| thinking | same + `--thinking high` | exit 0, **no** `thinking_level_changed` |
| continuation | same + `--session-id <id>` | same id, new timestamp, no replay (4.6) |
| fork | `pi --mode json --fork <id>` | header with new id + `parentSession` (4.6) |
| http401 / content_filter | server error responses | exit 0, JSON error events, stderr empty (4.3) |
| malformed | invalid SSE JSON | stderr warning + JSON error event, exit 0 (4.3) |
| sigterm | hold stream, `SIGTERM` @2s | truncated stdout, no terminal event (4.3) |
| startup failures | bogus model / invalid `--session-id` | exit 1, empty stdout, stderr `Error:` (4.4) |

---

## 10. Product-state verification

- Live `~/.pi/agent` (`auth.json`, `models*.json`, `settings.json`, `sessions/`, `skills/`) was
  **not** touched: all experiments ran under `PI_CODING_AGENT_DIR` in OS temp; live mtimes predate
  this session.
- Repo `git status --short` shows only the pre-existing untracked `.scratch/`, `AGENTS.md`,
  `CONTEXT.md`, `docs/adr/`, `docs/agents/` — no modified tracked files. This report is the only
  file written under the repo, at the declared path.
- This investigation used only read-only package inspection, `git status/log`, existing tests, and
  bounded offline temp runs; **no network** was used.
