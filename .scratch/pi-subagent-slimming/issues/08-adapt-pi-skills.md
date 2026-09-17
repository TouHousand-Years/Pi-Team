# Adapt Pi skills to sync-first operation

Type: wayfinder:task
Status: resolved
Blocked by: 01, 05

## Question

Rewrite the repository Pi skill and references so Codex uses synchronous pi_delegate by default, async is an explicit compatibility fallback, fallback collection uses three one-minute then three-minute occupying Monitor Waits without overlap, disconnects never auto-redispatch, and every installed specialized Pi skill remains demonstrably compatible with the two-tool server.

## Answer

Rewrote `skills/pi-subagent/SKILL.md` and both references to a v3 two-tool protocol, fixed the two installed specialized Pi skills that still assumed the retired task surface, and added a test that gates the contract.

### The repository skill

`SKILL.md` (v3.0.0) now documents only `pi_delegate` and `pi_status`, names the exact parameter sets from `src/tools/delegate.ts` and `src/tools/status.ts`, and states each rule the ticket asked for:

- **Sync first** — `mode:"sync"` is the normal path for one bounded objective, with `runTimeoutMs` ≤ 240000. The 240 s figure is not arbitrary: ticket 01 proved the Codex host aborts an MCP `tools/call` at 300 s while the server's own default `runTimeoutMs` is 600000, so a sync Run must carry its own deadline below the host ceiling to guarantee the terminal state returns inside the pending call. The skill also states the two explicit alternatives for longer objectives (accept the host timeout and collect the same `runId`, or go async).
- **Async is the explicit fallback** — only for fan-out/background work or a verified over-cap objective, and the dispatch must state its reason.
- **Monitor Wait collection** — up to three `waitTimeoutMs: 60000` waits, then `waitTimeoutMs: 180000` waits, strictly serial and non-overlapping, stopping at terminal status; a host-turn boundary returns the `runId` and resumes in the next turn; `waitTimeoutMs: 0` and `waitTimeoutMs ≥ 300000` are called out as forbidden.
- **Never auto-redispatch** — a host-reported sync timeout or disconnect has not stopped the Run; the host collects the same `runId` first, and only re-dispatches by explicit Host-Session decision with a fresh session name.

Retired surface removed throughout: task/stage orchestration, `promptHint`/`promptHintOverride`, the manual decision panel, attempt-escalation rules, `validateRules`, multi-file `outputFile`, `pi_kill`/`pi_plan`/`pi_session_*`. The skill instead warns that those names return `unknown tool`, so a stale memory does not retry them. Retained: host owns network I/O and decomposition, `constraints.noSkills:true` is passed explicitly on every dispatch, the code-edit-authority rule (host stays read-only over Pi-owned files), the anti-mechanical-retry rules, the four-run concurrency cap, and session reuse/isolation. `references/delegation-patterns.md` was rewritten as eight worked patterns for the two tools; `references/tool-call-loop-antipattern.md` keeps the case record with its tool name corrected.

### Installed specialized Pi skills

Five are installed (`~/.zcode/skills/pi-*` → `~/.skills-manager/skills/pi-*`). Two were incompatible with the two-tool server and were fixed:

- **`pi-team`** instructed the reader to "use task or stage tools", to carry the profile in a stage's `promptHint`/`promptHintOverride`, and to collect async Runs with `waitTimeoutMs` ≤ 25000 in at most three calls per turn. Replaced with the two-tool transport rule, the ≤240000 sync deadline, the `prompt`-only composition rule, the 60000/180000 Monitor Wait schedule, and the no-auto-redispatch rule.
- **`pi-worker`** ended its loop by "when the protocol reaches `manual`, present the decision panel" — the retired stage protocol. Rewritten to present the failed gate and its evidence to the user.

`pi-explorer`, `pi-ultra-planner`, and `pi-translator` were already compliant and are unchanged.

### Demonstrated compatibility

`test/skill-contract.test.ts` (4 tests) enforces the contract, with the tool vocabulary shared with the ticket-05 stdio boundary test through `test/skill-surface.ts`:

- the repository skill documents both live tools, never asks the reader to call a retired one, and warns that retired names fail;
- the always-loaded `SKILL.md` itself carries the sync deadline, the 60000-before-180000 schedule, the three-wait cap, non-overlap, the zero-poll ban, and the no-auto-redispatch rule, and no documented wait reaches the 180000 ceiling;
- every installed `pi-*` skill declares the `pi-subagent` MCP requirement, references no retired tool, names no `pi_*` token outside the two live tools, and uses no retired orchestration vocabulary;
- every installed skill that describes async collection states the 60000/180000 schedule, never overlaps, and never re-dispatches a disconnected sync call.

The gate was verified to be real, not vacuous, by injecting regressions and confirming failures: restoring `pi-team`'s task-stage/25000 wording, adding a `pi_task_create(...)` call to a repository reference, and deleting the Monitor Wait schedule from `SKILL.md` each failed the expected assertion. Numeric assertions use a digit-boundary regex so `60000` cannot match inside `600000`.

### Scope boundaries and residual risk

- **Server code is untouched.** The tool-level `mode` default remains `async`; the skill makes the host pass `mode:"sync"` explicitly. Flipping the code default was rejected deliberately: with `runTimeoutMs` still defaulting to 600000, a sync-by-default call would run past the host's 300 s cap and lose its synchronous return, so the two changes would have to land together and would belong to a code ticket, not this one.
- **The 60 s / 180 s waits remain inferred-safe, not host-proven.** Only ~25 s waits have been exercised on this host. The skill states this explicitly and names the response (fall back to 25000 and record the observation), which is the host-validation step ticket 01 asked for; final confirmation belongs to qualification.
- **A stale installed copy of the v2 skill remains** at `~/.skills-manager/skills/pi-subagent/SKILL.md` — byte-identical to this repository's previous version and still full of `pi_task_*`. It is not linked into `~/.zcode/skills`, so no host loads it, and it was left untouched as deployment rather than implementation; refreshing it belongs to the idle cutover in ticket 09.
- **The installed-skill tests skip** on a machine without those skill roots (they report why). Set `PI_SKILL_ROOTS` to pin the roots where they should be enforced.

`npm run build` passes and this change's tests pass. The full suite reports 126/130 only because another process is concurrently implementing ticket 07 in this same checkout (untracked `viewer/` and `test/viewer-format.test.ts`, 4 `viewer formatter` failures); those tests are unrelated to this ticket and were not modified.
