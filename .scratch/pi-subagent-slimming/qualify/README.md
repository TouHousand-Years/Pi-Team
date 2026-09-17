# Ticket 09 qualification harness

Repeatable evidence for *Qualify and replace the live service*. Everything here drives
the real shipped artifacts — the compiled MCP server (`dist/server.js`) over a real stdio
client, the real Pi 0.85.1 CLI, and the real PowerShell Run Window. Nothing is mocked.

## Run it

```bash
cd .scratch/pi-subagent-slimming/qualify

# everything except the human gate (~8 minutes, 2 real Pi Run batches, real windows)
node qualify.mjs surface compat sync timeout capture-disabled capture-damage async concurrent retention window-retention

# the configured live service, read out of ~/.codex/config.toml and launched as configured
node verify-configured-service.mjs

# human visual acceptance: leaves real windows on screen and holds them open
node visual.mjs 45
```

Reports land in `_out/<scenario>.json`; `node qualify.mjs` with no arguments lists the
scenarios. Transcript state lives outside the repo under
`%TEMP%\pi-subagent-qualify\<stamp>\` and is named in each report, so a human can re-inspect
the exact bundles a verdict came from.

## What each scenario establishes

| Scenario | Establishes |
| --- | --- |
| `config-entry` | (module) the single strict reader/writer for `[mcp_servers.pi-subagent]`, shared by `cutover` and `verify-configured-service` so the two can never disagree about what the config says. |
| `surface` | Exactly `pi_delegate` + `pi_status`; every retired name (`pi_kill`, `pi_plan`, `pi_session_*`, `pi_task_*`) fails as `unknown tool`; argument validation. |
| `compat` | The real 505 KB live `registry.json` loads, a Run still works, and all 50 legacy records survive the rewrite field-for-field; continuing a legacy session hands Pi that record's `piSessionId`. |
| `sync` | One synchronous call returns the terminal state inside the call (well under the 240 s skill deadline and the 300 s host ceiling); Transcript verified, Run Window opened with a full title, reopen focuses instead of duplicating, sound not replayed; the creating Run passes no session id and a continuation gets the recorded one. |
| `timeout` | A killed Run is never claimed clean: `timeout` status, an `incomplete` terminal, an INCOMPLETE window with one warning-sound attempt, nothing auto-redispatched. |
| `capture-disabled` | With unusable transcript storage (reparse-point root) the Run still succeeds, `pi_status` reports the evidence unavailable with a reason and `integrity: unknown`, and no window is opened on nothing. |
| `capture-damage` | A real window marks a byte-damaged transcript INCOMPLETE (`sequence-gap` + `terminal-hash-mismatch`), never repairs it, keeps the surviving content visible, and never rewrites the Run's own outcome; a capture error recorded at capture time is shown verbatim. |
| `async` | Async returns at once with a `runId`; a 60 s Monitor Wait occupies its full minute and correctly reports `running`; a following 180 s wait collects the terminal state; the waits never overlap; and a second Run that outlives the 180 s tier shows that wait is genuinely occupied (≥175 s) before honestly reporting `running`. |
| `concurrent` | Four simultaneous Runs each get a distinct live window and bundle, a fifth is refused with `resource-busy`, every transcript verifies, and completed windows stay open. |
| `retention` | Seven days / 2 GiB as shipped; expired terminal bundles are trashed, active and foreign-leased bundles never are, the quota evicts oldest-first, and expired trash is purged. |
| `window-retention` | An open window does not pin its bundle: the trash rename succeeds with the window on screen, the window survives with its content, and `pi_status` then reports the evidence unavailable while the Run's outcome stands. |
| `verify-configured-service` | Whatever `~/.codex/config.toml` currently points at exposes the right surface, holds a real Run, and writes a verifiable Transcript + window. Run it before and after the cutover. |
| `visual` | The three-window artifact for human acceptance, plus the checklist in `_out/visual-acceptance.md`. |

## Cutover

```bash
node cutover.mjs status      # what is configured now vs. what this repo builds
node cutover.mjs backup      # snapshot config + state + installed skill; write the manifest
node cutover.mjs apply       # one line of config.toml + the installed skill copy
node cutover.mjs rollback    # restore both byte-exactly from the manifest
node cutover.mjs verify      # re-read every claim and write _out/cutover-verification.json
```

`apply` refuses while any Run is active (registry `running` session or a live `pi` child),
edits exactly the `args` line of `[mcp_servers.pi-subagent]`, then re-reads the file to
prove nothing else moved, and refuses if the config has moved since the backup. It replaces
only `args[0]`, so trailing argv elements survive, and it swaps the installed skill through
a staging directory so a failure cannot leave the old copy deleted. `rollback` verifies
byte-exactness of both the config and every skill file. `verify` re-reads the configured
entry and re-hashes the registry, the build, the skill and the previously live checkout.
Neither ever writes to the previously live checkout.

## Notes on the harness itself

- Scope of "real": the process-boundary scenarios (`surface`, `compat`, `sync`, `timeout`,
  `capture-disabled`, `capture-damage`, `async`, `concurrent`, `window-retention`) drive the
  real server, the real Pi CLI and the real window. `retention` is the exception — it calls
  the shipped `TranscriptStore` directly and builds its fixtures with the shipped
  `TranscriptWriter`, because the policy boundaries (eight days old, a zero quota, a lease
  held by a foreign pid) cannot be reached through the product surface in reasonable time.

- The MCP SDK's per-request timeout defaults to 60 s, so `call()` passes an explicit
  timeout — otherwise the 180 s Monitor Wait would look like a client-side abort.
- Registry equality is compared structurally (`canonical()`), because the rewrite
  re-serializes each record in the loader's own field order; a textual compare reports
  false drift.
- Retry-sensitive checks (`window-retention`) retry the way retention's next pass would,
  rather than asserting on one attempt: a rename that lands during the viewer's
  `viewer-state.json` tick fails with a transient `EPERM`, which retention records as
  `skipped` and re-attempts on its next 15-minute pass. The harness retries at one second
  so the check is not flaky; it is the same code path, not the same interval.
- A scenario that throws still writes its report (with the stack under `threw`), so a
  failure can never be invisible in `_out/`.
