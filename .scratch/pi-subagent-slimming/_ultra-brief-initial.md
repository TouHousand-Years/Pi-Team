# Ultra brief — pi-subagent slimming proposal gate

## Original request

The user wants to modify this project by removing unnecessary features and MCP tools, retaining and adapting only what `pi-worker` and related skills need, reducing the operational burden placed on the host agent, replacing continuous listening with low-frequency monitoring every few minutes led mainly by a human `continue` instruction after completion, and adding a read-only popup/status indicator that shows current pi-subagent work and notifies on completion.

The user explicitly selected the `wayfinder-pisub` workflow. This pass must propose the whole direction only; implementation and final Wayfinder charting happen later after user acceptance and detailed decision rounds.

## Goal and destination candidate

Produce a smaller, easier-to-operate pi-subagent whose supported core matches the installed `pi-team`/`pi-worker` family, whose asynchronous work does not require continuous agent polling, and whose current/finished work is visible to a human through a read-only Windows status window with completion notification. The eventual Wayfinder effort may carry implementation through the map if the user confirms that in Notes.

## Current state and evidence

- The repository at `C:\Users\qnhxx\Documents\AI-Projects\Code\pi-subagent` is at `174cf17`. Its server registers 12 tools in `src/server.ts`: `pi_delegate`, `pi_status`, `pi_plan`, three `pi_session_*`, `pi_kill`, and five `pi_task_*` tools.
- The installed Pi skill family is external under `~/.skills-manager/skills/`. Its shared `pi-team/SKILL.md` refers only to `pi_delegate` and `pi_status`; `pi-worker`, `pi-explorer`, `pi-translator`, and `pi-ultra-planner` delegate through that contract. No installed specialized skill directly needs task/session/plan/kill tools.
- The repository's own `skills/pi-subagent` v2 protocol is the only consumer of the other ten tools. It contains the continuous-polling language: async delegates repeatedly call `pi_status`, up to 25 seconds per call.
- `src/tools/status.ts` defaults to a 25-second long poll. Completed runs remain in `RunRegistry` for 24 hours or until the 128-completed cap. Persistent state is `~/.pi-subagent/registry.json`; optional task state is `tasks.json`. The server has no MCP push/notification implementation.
- The actual Codex MCP configuration points to a different live checkout: `C:\Users\qnhxx\Documents\Codex\tools\pi-subagent`, at `21fe334`, with uncommitted changes that already switch default dispatch from async to sync. Therefore repository target and deployment/migration must be explicit.
- Pi itself intentionally has no built-in MCP or sub-agent mechanism. Its extension UI can show status/widgets/overlay and notify, but Pi is not the MCP host here. A host-independent read-only watcher over `registry.json` is the evidence-backed UI seam; Codex-native popup support is unproven.
- Runtime dependencies are minimal: MCP SDK only. No GUI toolkit is present. A Windows-only watcher can plausibly use built-in PowerShell/.NET WinForms or a small Node child process, but this is a design choice, not yet an established fact.
- Baseline: build passes. Tests define 140 cases; 136 pass and four Windows path-separator assertions in `test/stage-prompt.test.ts` fail before this work. Those failures are pre-existing and should not mask slimming regressions.
- User-owned/untracked governance files already exist (`AGENTS.md`, `CONTEXT.md`, `docs/agents`, `docs/adr`) and must be preserved. The only new planning artifact so far is `.scratch/pi-subagent-slimming/_exploration.md`.

## Success criteria

1. Publish a deliberately small supported MCP surface whose compatibility with the installed `pi-team`/specialized Pi skills is demonstrated by tests or an explicit compatibility matrix.
2. Remove obsolete implementation, persistence, documentation, and tests coherently rather than merely hiding tool registrations.
3. Make synchronous delegation the ordinary path; retain asynchronous execution only if it is necessary for long runs and make its collection low-frequency and bounded.
4. Rewrite the repository skill contract so it never asks an agent to continuously listen or mechanically poll. It should dispatch, yield control, and ask the human to continue later; optional status checks occur only every few minutes.
5. Provide a read-only status UI that cannot start, cancel, retry, or mutate work. It shows active/recent runs, progress summary, elapsed/final state, and produces one completion notification per transition.
6. Keep the MCP server usable without the UI; UI failure must not affect worker execution.
7. Define how changes from this repository become the actual live MCP server without overwriting uncommitted work in the other checkout.
8. Pass build and targeted/broad regression checks, while recording the four pre-existing platform-sensitive failures separately unless the user explicitly folds their repair into scope.

## Constraints and standing preferences

- Plan before implementation under Wayfinder; decisions belong to the user.
- When visual/UI validation is required, pause and wait for human inspection per `AGENTS.md`.
- Preserve `pi-worker`, `pi-explorer`, `pi-translator`, and `pi-ultra-planner` compatibility through `pi-team`.
- Lower the host agent's operational load. The human is the normal wake-up mechanism after an async subagent finishes.
- The popup is read-only and completion-aware.
- Do not mutate the separate live checkout until its relationship and dirty changes are deliberately resolved.

## Candidate non-goals

- A general-purpose task orchestration platform inside this MCP server.
- A writable desktop controller for retry/cancel/start.
- A Codex-specific UI integration without authoritative evidence that Codex exposes the needed surface.
- Preserving the repository's legacy v2 `pi_task_*` orchestration solely for backward compatibility, unless the user chooses it.
- Fixing unrelated Windows path tests in the same change, unless the user opts in.

## Decision-critical unknowns

1. Whether `pi_kill` remains as a human emergency escape hatch even though installed skills do not require it.
2. Whether the minimal API is two tools (`delegate`, `status`) or three including `kill`.
3. Whether async remains an explicit advanced mode or is removed entirely. Long tasks may exceed MCP call timeouts, so removal carries compatibility risk.
4. Exact UI packaging: built-in Windows PowerShell/.NET viewer, Node-based window with a dependency, or Pi extension (which would not cover the current Codex host).
5. Desired status scope: only current process/run, or all active and recently completed runs in the shared registry.
6. Completion notification channel and deduplication semantics.
7. How to reconcile this repository with the dirty live checkout.
8. Whether old registry files must remain readable after removing task/session concepts.

## Request to Ultra Planner

Return one coherent end-to-end proposal suitable for presenting to the user for acceptance before detailed grilling. Include:

1. recommended product boundary and exact retained/removed capability groups;
2. lifecycle and human interaction model for sync, async, low-frequency monitoring, and continue;
3. read-only status popup architecture and notification behavior;
4. ordered implementation/migration stages with observable validation for each;
5. alternatives and trade-offs;
6. assumptions, risks, rollback points, and evidence gaps that would change the recommendation.

Ground every recommendation in this brief. Clearly distinguish decisions the user must confirm from defaults the implementation can safely choose later. Do not explore, use tools, or modify files.

---

# Completed-chart review supplement

## Conversation decisions after the original brief

- The user corrected the viewer from a periodic summary popup to one independent realtime Run Window per pi_delegate invocation.
- The Run Window must show all process-boundary input/output in one complete formatted stream, not a brief and not a Raw-events tab.
- The Transcript is unredacted, current-user-only, retained seven days or 2 GiB total for completed Runs.
- Closing a window does not stop capture or notification; completed windows stay open until manually closed.
- Capture failure leaves the Run running and marks the Transcript incomplete.
- Codex uses a pending synchronous pi_delegate call as the normal completion path. Pi completion returns that call and resumes the Host Session.
- Async remains only a compatibility or verified-timeout fallback. Its occupying pi_status schedule is three sequential waits of at most one minute, then sequential waits of at most three minutes, never overlapping.
- Existing registry.json Pi Sessions remain readable. Legacy tasks.json is untouched and ignored.
- The source is this original repository. After all validation and with no active Run, Codex switches to this repository's dist/server.js; the old live checkout remains untouched for rollback.
- Sync disconnects/timeouts never cause automatic redispatch.
- The user accepted WinForms as the first prototype route and requires a human visual-inspection pause.
- The user explicitly confirmed the complete shared understanding and authorized implementation through the Wayfinder map.

## Canonical map body

Destination: Replace the current Pi subagent service with a verified two-tool, sync-first implementation that retains the Pi skill family, records every Run's process-boundary input/output, opens one realtime read-only formatted Run Window per delegation, and keeps a bounded async long-poll fallback.

Notes: Implementation is carried through the map. Use CONTEXT.md terminology and the specialized skills named in map.md. Preserve the accepted tool, lifecycle, Transcript, UI, retention, compatibility, failure, validation, and cutover decisions above. Baseline is build passing and 136/140 tests passing; four existing Windows path-separator failures remain out of scope unless they block qualification.

Decisions so far: empty, because no child ticket has yet been resolved.

Not yet specified:

- Visual refinements after human reaction to the first faithful WinForms prototype.
- Additional event adapters/display groupings revealed by the installed Pi event stream.
- Registry migration response if compatibility tests expose an unknown old record shape.

Out of scope:

- Cross-platform GUI packaging.
- Writable Run controls.
- Hidden reasoning or unexposed context.
- Legacy v2 task/session/plan protocol compatibility.
- Unrelated Windows path-separator fixes.

## Created tickets and dependency graph

1. Prove Codex completion transport boundaries — wayfinder:research — blockers: none. Determine official and observed guarantees for pending synchronous pi_delegate and sequential one-minute/three-minute pi_status long-polls.
2. Inventory Pi's lossless event surface — wayfinder:research — blockers: none. Determine every emitted input/output/event shape and lossless formatting rules without duplicate assistant output.
3. Prove the per-Run Windows viewer — wayfinder:prototype — blocker: Inventory Pi's lossless event surface. Prototype independent WinForms windows, realtime replay/tail, complete formatted rendering, four-Run isolation, volume/Unicode behavior, failure isolation, one completion notification, and human visual inspection.
4. Fix the Transcript-to-window seam — wayfinder:grilling — blockers: Inventory Pi's lossless event surface; Prove the per-Run Windows viewer. Lock schema, adapter, launch/replay, incomplete signal, notification ownership, and retention seam from evidence and human reaction.
5. Reduce the MCP core to the supported surface — wayfinder:task — blockers: Prove Codex completion transport boundaries; Fix the Transcript-to-window seam. Implement only pi_delegate/pi_status while keeping internal Pi Session continuity and removing legacy tools and exclusive machinery.
6. Build lossless per-Run Transcripts — wayfinder:task — blockers: Inventory Pi's lossless event surface; Fix the Transcript-to-window seam. Implement append-only capture, ordering, failure state, retention, replay, registry compatibility, and isolation.
7. Integrate independent Run Windows — wayfinder:task — blockers: Prove the per-Run Windows viewer; Build lossless per-Run Transcripts. Productize auto-launch, complete formatted windows, closure/notification behavior, and execution isolation.
8. Adapt Pi skills to sync-first operation — wayfinder:task — blockers: Prove Codex completion transport boundaries; Reduce the MCP core to the supported surface. Rewrite skill contracts and prove specialized-skill compatibility.
9. Qualify and replace the live service — wayfinder:task — blockers: Integrate independent Run Windows; Adapt Pi skills to sync-first operation. Run all validation and human inspection, back up configuration/state, switch Codex, preserve the old service, and demonstrate rollback.

Declared dependency edges: 02→03; 02→04; 03→04; 01→05; 04→05; 02→06; 04→06; 03→07; 06→07; 01→08; 05→08; 07→09; 08→09.

Active frontier: Prove Codex completion transport boundaries; Inventory Pi's lossless event surface.

## Tracker constraints

- Local Markdown map at .scratch/pi-subagent-slimming/map.md and one child file per ticket under issues/.
- An open, unblocked, unclaimed child is frontier; lowest number wins.
- Claim before work by setting Status: claimed.
- Resolve by adding an Answer, setting Status: resolved, and appending a one-line context pointer to Decisions so far.
- Never resolve more than one ticket per session except research tickets.

## Chart-review request

Review this completed chart against the entire brief and conversation decisions. Evaluate destination fidelity, coverage, ticket sharpness, dependency correctness, scope drift, implementation authorization, and hidden assumptions. Separate BLOCKERS from SUGGESTIONS and cite the supplied map, ticket, or decision evidence for each finding. Do not edit or silently override the canonical map.
