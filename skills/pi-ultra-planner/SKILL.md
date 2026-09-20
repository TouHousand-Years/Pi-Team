---
name: pi-ultra-planner
description: Use a short-context flagship model as a read-only decision maker after Pi exploration or bounded work has produced a compact evidence brief. Use for high-leverage implementation planning, trade-off decisions, or recovery plans; it plans only and never executes, edits, or explores a repository. Cannot be used unless otherwise specified by user or other skills.
metadata:
  requires:
    mcps: ["pi-subagent"]
---

# Pi Ultra Planner

Use a configured short-context flagship model as the decision pass in a Vibe Coding-style loop: Pi collects affordable evidence, the flagship model chooses a plan, and the main session owns execution. The planner receives text only and has no tool, network, or write capability.

Before delegating, read [subagent-prompt.md](subagent-prompt.md). `pi-team` sends it verbatim together with the main session's complete current request.

## Build the decision brief

First use `pi-explorer` to resolve repository facts, unknowns, and relevant seams. Use `pi-worker` when a bounded experiment, test, reproduction, or baseline is needed. The evidence phase is complete only when those findings are synthesized into `_ultra-brief.md` and every decision-critical claim is supported or marked unknown.

Keep the brief within the planner's documented context budget. Include only information that can change the decision:

- the decision or goal, success criterion, scope, and non-goals
- established facts with file paths, line references, commit references, or observed test output
- approaches already attempted and their outcomes
- constraints: compatibility, performance, security, cost, schedule, and user decisions
- open questions, risks, and the exact choice the planner should resolve

Summarize repository trees, logs, diffs, and history into only the evidence that can change the choice. The brief is dispatchable when it fits the planner's context budget, presents the exact decision, and contains enough evidence to compare the viable options. Otherwise name the missing evidence and return to `pi-explorer` or `pi-worker` in a separate dispatch.

## Read-only planning pass

Invoke the configured ultra-planner with the brief and an explicit request for a plan only. Give it no tool access and no writable task directory. Its response must return to the main session, not an output file.

The planning request requires:

1. a recommended approach and the reasoning grounded in the brief
2. ordered, independently checkable execution steps, including expected validation for each
3. alternatives and the trade-offs that reject or favor them
4. assumptions, risks, rollback points, and evidence gaps that would change the recommendation

The planning pass is complete when it either returns all four items with each recommendation traceable to the brief, or returns `insufficient evidence` with the smallest missing evidence set and the decision each item would unlock. The planner may recommend more investigation; that investigation belongs to a later dispatch.

## Planner isolation

Invoke the planner through `pi-team`. In addition to its shared contract, pass `noContextFiles: true` and `excludeTools: ["read", "bash", "edit", "write"]`. The configured model never receives tools, network access, or write authority.

## Cost and handoff

Use one planning pass by default. Re-plan only after material new evidence changes a decision; send a delta brief rather than repeat the full context. Do not use this skill for routine implementation choices that Pi can resolve within a clear feedback loop.

The main session checks every recommendation against the brief, obtains any required user decision, and delegates execution to `pi-worker` or the appropriate workflow. Acceptance requires a bounded recommendation, independently checkable steps, explicit trade-offs, rollback points, assumptions, and evidence gaps. Execution begins only in the next, separately authorized step.
