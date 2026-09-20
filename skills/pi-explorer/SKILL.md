---
name: pi-explorer
description: Explore a code repository and return evidence-backed findings without making product changes. Use to investigate caches, frontends, concurrency, networking, recent commits, tests, architecture, or a reproducible failure; use pi-worker when the requested outcome is implementation. Cannot be used unless otherwise specified by user or other skills.
metadata:
  requires:
    mcps: ["pi-subagent"]
---

# Pi Explorer

Use the `pi-team` contract for bounded, read-mostly repository reconnaissance. This skill owns the investigation scope and evidence format; `pi-team` owns delegation mechanics. The result is a navigable evidence map, not a code change.

Before delegating, read [subagent-prompt.md](subagent-prompt.md). `pi-team` sends it verbatim together with the main session's complete current request.

## Investigation contract

Write one answerable question before delegation. The investigation is dispatchable when it names the repository root, time or commit boundary, allowed commands and artifact paths, material claims that require evidence, and the condition for answering or declaring an evidence gap. Choose only the relevant tracks:

- cache: ownership, keys, lifecycle, invalidation, persistence, and tests
- frontend: entry points, state flow, rendering boundaries, assets, build, and tests
- concurrency: shared state, synchronization, cancellation, queues, and race coverage
- network: clients, protocols, retries, timeouts, authentication boundaries, and mocks
- recent commits: the requested commit range, intent, affected seams, and regression risk
- tests: test layers, fixtures, commands, coverage gaps, and relevant failures
- reproduction: prerequisites, smallest safe procedure, observed output, and repeatability

Add other tracks only when they directly serve the question.

## Workflow

1. **Bound the evidence.** Inspect locally available files and history first. When an external fact could change the answer, the host supplies it in `_refs.md`. This step is complete when every required evidence source is either locally named or recorded as a gap.
2. **Dispatch tracks.** Use one report for a narrow question. For genuinely independent tracks, write `_plan-draft.md` with one question and one completion criterion per stage, using no more than four concurrent runs. Keep a later synthesis out of track prompts when its visibility would pull investigation toward a premature conclusion.
3. **Preserve state.** Keep product code read-only. Put safe reproduction artifacts only in the declared task or temporary directory. This step is complete when repository status and artifact locations show that product state is unchanged.
4. **Prove claims.** Each report records paths and line numbers, commands and salient output, commit identifiers where relevant, facts separated from inferences, and remaining unknowns. A stage is complete only when every material claim has this evidence or is labeled as an unresolved gap.
5. **Synthesize.** When multiple reports exist, delegate a separate synthesis using only their evidence. It completes when it directly answers the original question, reconciles material conflicts, and ranks follow-up work by evidence.

## Acceptance

Finish only when the original question has a direct answer or a precisely stated evidence gap, every material claim points to repository evidence, conflicting evidence is resolved or exposed, reproduction status is `reproduced`, `not reproduced`, or `blocked` with conditions, and no product files were changed. Return the concise conclusion first, followed by facts, supported inferences, the evidence map, and gaps.
