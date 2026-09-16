# Pi Subagent

Pi Subagent delegates bounded work from a host agent to Pi and exposes the delegated work to both the host and the human user.

## Language

**Run**:
One invocation of Pi created by a delegation, from its submitted input through its terminal outcome.
_Avoid_: Task, job

**Host Session**:
The main agent conversation that delegates a Run and periodically checks its state.
_Avoid_: Controller, watcher

**Run Window**:
A read-only user window dedicated to one Run and showing that Run's live transcript and state.
_Avoid_: Dashboard, summary popup

**Transcript**:
The ordered, complete input and output record exposed by Pi for one Run.
_Avoid_: Progress summary, brief

**Monitor Wait**:
A bounded Host Session long-poll for an asynchronous Run. The first three waits last at most one minute each; later waits last at most three minutes each, and waits never overlap.
_Avoid_: Tight polling, zero-time polling
