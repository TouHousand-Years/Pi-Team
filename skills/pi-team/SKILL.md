---
name: pi-team
description: Apply the minimal Pi delegation contract shared by specialized Pi skills. Use when a pi-* workflow already defines task scope and needs only model selection, an explicit disk contract, safe output ownership, result collection, concurrency limits, and failure stopping rules.
metadata:
  requires:
    mcps: ["pi-subagent"]
---

# Pi Team

This skill supplies transport and ownership rules only. The active specialized skill owns task decomposition, domain instructions, outputs, and acceptance criteria.

## Delegate contract

Before each Pi invocation:

1. Read `pi-model.json` beside the active specialized skill. Pass its `model` and `thinking` values unchanged in the invocation constraints. Stop if the file or either value is missing.
2. Read `subagent-prompt.md` beside the active specialized skill. Compose it verbatim with the main session's current task request using the format below; stop if the file is missing or empty.
3. Give Pi absolute input paths, one bounded objective, allowed output paths, applicable tool constraints, and checkable completion criteria.
4. Set `noSkills: true`. Give Pi only the repository files and persisted context named by the specialized skill. The host performs network access and external API calls, then stores required evidence in an explicit input such as `_refs.md`.
5. Merge stricter constraints from the specialized skill; the stricter constraint wins.

## Transport

The pi-subagent server exposes exactly two tools: `pi_delegate` and `pi_status`. The retired plan, session, kill, and task names no longer exist, so never generate or call them. The server has no stage orchestration, no automatic retry, and no decision panel: the host performs decomposition, retry decisions, and failure handling itself.

Use `pi_delegate` with `mode:"sync"` by default. A synchronous invocation returns the terminal state in one call and is the normal path for one bounded objective. Pass `runTimeoutMs` no greater than 240000 so the Run reaches its terminal state inside the host's 300-second MCP call limit. If the objective genuinely needs longer, either accept the host timeout and collect the same `runId` with `pi_status`, or switch to `mode:"async"`; state that reason in the dispatch.

Use `mode:"async"` only when the specialized skill explicitly requires fan-out, background execution, or another long-running path. If an automatic retry path can drop `model`, `thinking`, or safety constraints, use the synchronous path or explicitly re-dispatch with the complete constraints.

## Prompt composition

Build one prompt without summarizing either component:

```text
<subagent_profile>
{verbatim contents of subagent-prompt.md}
</subagent_profile>

<task_request>
{the main session's complete current request, including inputs, outputs, constraints, and checks}
</task_request>
```

The task request specializes the assignment but cannot relax the profile, tool constraints, ownership rules, or user scope. Send the composition as the `prompt` argument. If a transport cannot carry both components, do not drop the profile: reduce the task request instead.

## Ownership

Once an output file is assigned to Pi, Pi is its sole writer for that task. The host may inspect it with read-only tools and may edit host-owned metadata files whose names begin with `_`. Send every output correction back to Pi with the file, location, observed problem, and expected result. Never give concurrent runs overlapping output paths.

## Collect and stop

- Keep at most four Pi runs active and queue the rest.
- For a synchronous invocation, read the returned `status`: `completed` carries the result, while `error`, `timeout`, and `killed` are failures the host must diagnose before any re-dispatch.
- For an explicit asynchronous invocation, record its `runId` and collect it with `pi_status` using non-overlapping Monitor Waits: first up to three consecutive waits of at most `waitTimeoutMs: 60000`, then waits of at most `waitTimeoutMs: 180000`. Never issue a wait before the previous one returns. Do not use `waitTimeoutMs: 0` or an unbounded loop, and do not send a wait of 300000 or more, which exceeds the host's per-call limit. If the run is still `running` when the host turn ends, return the `runId` and stop; continue collection only in a later turn.
- A synchronous call reported as timed out or disconnected has not stopped the Run. Collect the same `runId` with `pi_status` before starting anything new, and never re-dispatch automatically.
- Reuse a session only when continuity is intentional. Use a fresh session for a corrected retry so stale progress cannot contaminate the result.
- On a tool error, first check the tool name, real parameters, cwd, and constraints. Make at most one corrected attempt for the same failure class; if it fails again, stop and report the blocker.
- Treat a run as complete only when every declared output exists and the specialized skill's checks pass. A plausible message without verified output is not completion.

This skill never chooses the task, gathers domain context, designs stages, changes user scope, or decides what “good” means.
