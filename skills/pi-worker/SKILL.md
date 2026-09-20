---
name: pi-worker
description: Execute a bounded coding or repository task with explicit tests and a closed feedback loop. Use for repository search tied to a deliverable, running tests, boilerplate, bulk edits, documentation lookup, log analysis, experiments, or reproduction when success can be checked; use pi-explorer for open-ended reconnaissance. Cannot be used unless otherwise specified by user or other skills.
metadata:
  requires:
    mcps: ["pi-subagent"]
---

# Pi Worker

Use the `pi-team` contract when the task has a clear boundary and observable feedback. This skill owns the work loop; `pi-team` owns delegation mechanics. The host defines and reviews the loop; Pi performs all edits to code and deliverable files.

Before delegating, read [subagent-prompt.md](subagent-prompt.md). `pi-team` sends it verbatim together with the main session's complete current request.

## Work contract

Write one bounded task request before delegation. It is ready only when Pi can identify without inference:

- the exact repository or task directory
- one requested outcome and the permitted input and output paths
- the baseline or failure to preserve or reproduce
- the validation commands, expected signals, and acceptable exceptions
- relevant constraints, non-goals, and an exhaustive completion criterion

If external documentation, packages, or API results are needed, the host obtains them and writes `_refs.md`. Pi works offline from repository files and supplied references.

## Closed loop

1. **Baseline.** Run the smallest relevant search, test, log query, or experiment. For a defect, capture a failing reproduction when practical. This step is complete when the starting state is recorded as a command plus observed signal, or the exact reason it cannot be observed.
2. **Stage.** For multi-part work, write `_plan-draft.md` with one bounded objective per stage. A stage is dispatchable when it names exact inputs, Pi-owned outputs, constraints, and executable or inspectable checks. Keep dependent stages out of the current dispatch when seeing later work would encourage premature completion.
3. **Execute.** Delegate the current bounded objective through `pi-team`. This step is complete when every declared output exists and Pi reports the commands and observations needed for host validation.
4. **Verify.** Run the stage's targeted checks, then the broader relevant regression check after the final stage. A check completes with a recorded pass signal or an explicit exception that the user has accepted.
5. **Correct.** Review outputs read-only. Return each defect to Pi with the file, location, observed failure, and expected behavior. This step is complete when the corrected output passes its failed check; the host remains read-only over Pi-owned files.
6. **Stop or continue.** Follow `pi-team` failure handling. Continue only with an in-scope corrected dispatch; when a failure cannot be resolved within scope, present the failed gate and its evidence to the user instead of retrying the same dispatch.

Use no more than four concurrent runs. Keep dependent edits sequential, and avoid parallel stages that own overlapping files.

## Acceptance

Finish only when every requested artifact exists, every requested behavior is accounted for, the declared checks pass or have an explicitly accepted exception, and the broader relevant regression check has run. Report changed files, commands and observed results, accepted exceptions, residual risks, and unverified checks. Code written without this evidence is incomplete.
