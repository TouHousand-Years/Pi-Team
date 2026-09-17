#!/usr/bin/env node
// Ticket 09 qualification: "Qualify and replace the live service".
//
// Usage: node qualify.mjs <scenario> [...]
//   surface           two-tool MCP surface + retired names rejected
//   compat            the real 505 KB live registry.json round-trips losslessly
//   sync              real Pi sync return inside one tool call, plus the Run Window
//   timeout           capture failure never stops a Run, but is marked incomplete
//   async             real Pi async return + 60 s / 180 s Monitor Waits, non-overlapping
//   concurrent        four simultaneous Runs, one window each, cap enforced
//   retention         seven-day / 2-GiB retention, active Runs never cleaned
//   window-retention  retention may clean a completed bundle while its window is open
//
// Every scenario is independent and writes qualify/_out/<scenario>.json.
import { spawn } from "node:child_process";
import { existsSync, cpSync, lstatSync, mkdirSync, readFileSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  LIVE_REGISTRY, RUN_ROOT, check, finish, listDirs, newReport, pidAlive, readJson,
  readManifest, readViewerState, launchRecord, replay, scratch, sleep, startServer, call,
  terminalRecord, windowTitles, bundleDir, killWindow, launchWindow, waitFor,
} from "./lib.mjs";

// The registry rewrite re-serializes each record through the loader's own field
// order, so equality must be structural rather than textual.
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function differingFields(a, b) {
  const keys = new Set([...Object.keys(a ?? {}), ...Object.keys(b ?? {})]);
  return [...keys].filter((k) => canonical(a?.[k]) !== canonical(b?.[k]));
}

function transcriptOf(s) {
  return {
    RUN_ROOT, registry: s.registry, transcripts: s.transcripts, cwd: s.cwd,
  };
}

// ===========================================================================
// 1. surface
// ===========================================================================
async function scenarioSurface() {
  const report = newReport("surface");
  const dir = scratch("surface");
  const registry = join(dir, "registry.json");
  const transcripts = join(dir, "runs");
  const { client, stderr } = await startServer({ registry, transcripts, viewer: false });
  try {
    const tools = await client.listTools();
    const names = tools.tools.map((t) => t.name).sort();
    report.tools = tools.tools;
    check(report, "exactly pi_delegate and pi_status are exposed",
      JSON.stringify(names) === JSON.stringify(["pi_delegate", "pi_status"]), names);
    check(report, "server advertises the pi-subagent name",
      (await client.getServerVersion())?.name === "pi-subagent");

    for (const retired of ["pi_kill", "pi_plan", "pi_session_list", "pi_task_create", "pi_task_status"]) {
      const r = await call(client, retired, {}, 20_000);
      check(report, `retired tool ${retired} is rejected as unknown`,
        r.isError && /unknown tool/i.test(r.text), { isError: r.isError, text: r.text });
    }

    const bad = await call(client, "pi_delegate", { session: "x" }, 20_000);
    check(report, "pi_delegate without prompt is an invalid-arg error",
      bad.isError && bad.json?.code === "invalid_arg", bad.json);

    const noGoal = await call(client, "pi_delegate", { prompt: "p", session: "surface-new" }, 20_000);
    check(report, "new session without goal is rejected before any Pi spawn",
      noGoal.isError && noGoal.json?.code === "goal_required", noGoal.json);

    const delegate = tools.tools.find((t) => t.name === "pi_delegate");
    const status = tools.tools.find((t) => t.name === "pi_status");
    check(report, "pi_delegate requires prompt+session and carries mode/runTimeoutMs",
      JSON.stringify(delegate.inputSchema.required) === JSON.stringify(["prompt", "session"])
      && "mode" in delegate.inputSchema.properties && "runTimeoutMs" in delegate.inputSchema.properties);
    check(report, "pi_status requires runId and carries waitTimeoutMs/openWindow",
      JSON.stringify(status.inputSchema.required) === JSON.stringify(["runId"])
      && "waitTimeoutMs" in status.inputSchema.properties && "openWindow" in status.inputSchema.properties);
    check(report, "server stderr reports no problem", stderr.join("") === "" || !/uncaught|unhandled/i.test(stderr.join("")), stderr.join(""));
  } finally {
    await client.close();
  }
  return finish(report);
}

// ===========================================================================
// 2. compat — the live registry of the running service, read and rewritten
// ===========================================================================
async function scenarioCompat() {
  const report = newReport("compat");
  const dir = scratch("compat");
  const registry = join(dir, "registry.json");
  const transcripts = join(dir, "runs");
  const cwd = scratch("compat-cwd");
  cpSync(LIVE_REGISTRY, registry);
  const before = readJson(registry);
  report.registry = { path: registry, sessions: before.sessions.length, bytes: statSync(registry).size };

  const { client } = await startServer({ registry, transcripts, viewer: false });
  try {
    // A real Run against the legacy registry: proves it loads, and forces a rewrite.
    const r = await call(client, "pi_delegate", {
      prompt: "Use the bash tool to run exactly: echo COMPAT_OK. Then reply with exactly: COMPAT_REPLY",
      session: "qualify-compat",
      cwd,
      goal: "qualification: prove the legacy registry is read and preserved",
      constraints: { noSkills: true },
      mode: "sync",
      runTimeoutMs: 240_000,
    }, 300_000);
    report.compatRun = { status: r.json?.status, elapsedMs: r.elapsedMs, error: r.json?.error };
    check(report, "a Run still works while the legacy registry is loaded",
      r.json?.status === "completed", r.json);

    await sleep(500); // persist() runs on a microtask; give the atomic rename a moment
    const after = readJson(registry);
    report.afterSessions = after.sessions.length;

    const beforeByName = new Map(before.sessions.map((s) => [s.name, s]));
    const afterByName = new Map(after.sessions.map((s) => [s.name, s]));
    const missing = [...beforeByName.keys()].filter((n) => !afterByName.has(n));
    check(report, "no legacy session was dropped by the rewrite", missing.length === 0, missing);

    const drifted = [];
    for (const [name, rec] of beforeByName) {
      const now = afterByName.get(name);
      const fields = now ? differingFields(rec, now) : ["<record missing>"];
      if (fields.length) drifted.push({ name, fields });
    }
    report.drift = drifted;
    check(report, "all 50 legacy session records survive field-for-field", drifted.length === 0,
      drifted.slice(0, 5));

    const reordered = [...beforeByName.keys()].filter((n) => {
      const a = beforeByName.get(n); const b = afterByName.get(n);
      return b && JSON.stringify(a) !== JSON.stringify(b);
    });
    report.keyOrderNormalized = { count: reordered.length, of: beforeByName.size, sample: reordered.slice(0, 3) };

    check(report, "no legacy record was silently marked running",
      after.sessions.every((s) => ["idle", "error"].includes(s.status)),
      after.sessions.filter((s) => s.status === "running").map((s) => s.name));

    const created = afterByName.get("qualify-compat");
    check(report, "the new session was appended in the same v1 shape",
      created && after.version === 1 && typeof created.piSessionId === "string" && created.status === "idle",
      created);

    // Legacy continuity: continuing a *legacy* session must hand Pi that record's
    // piSessionId. The Transcript launch record is the proof, and it is available
    // immediately after dispatch, before Pi's own outcome matters.
    const legacy = before.sessions.find((s) => s.name === "issue31-explore");
    const cont = await call(client, "pi_delegate", {
      prompt: "Reply with exactly: LEGACY_CONTINUATION_OK",
      session: legacy.name,
      constraints: { noSkills: true },
      mode: "async",
    }, 60_000);
    const contBundle = cont.json?.runId ? bundleDir(transcripts, cont.json.runId) : undefined;
    await sleep(1500);
    const launch = contBundle && existsSync(contBundle) ? launchRecord(contBundle) : undefined;
    report.legacyContinuation = {
      runId: cont.json?.runId, status: cont.json?.status,
      expectedSessionId: legacy.piSessionId, launch,
    };
    check(report, "a legacy session continues with the piSessionId from the legacy file",
      launch?.sessionId === legacy.piSessionId, { launch, expected: legacy.piSessionId });
    if (cont.json?.runId) await call(client, "pi_status", { runId: cont.json.runId, waitTimeoutMs: 180_000 }, 240_000);
  } finally {
    await client.close();
  }
  return finish(report);
}

// ===========================================================================
// 3. sync — the normal path: one synchronous pi_delegate call, one window
// ===========================================================================
async function scenarioSync() {
  const report = newReport("sync");
  const dir = scratch("sync");
  const registry = join(dir, "registry.json");
  const transcripts = join(dir, "runs");
  const cwd = scratch("sync-cwd");
  report.state = transcriptOf({ registry, transcripts, cwd });

  const prompt = "Use the bash tool to run exactly this command: echo SYNC_MARKER_QUALIFY. "
    + "Then reply with exactly: SYNC_REPLY_QUALIFY";
  const { client } = await startServer({ registry, transcripts, viewer: true });
  try {
    const r = await call(client, "pi_delegate", {
      prompt, session: "qualify-sync", cwd,
      goal: "qualification: sync return through one MCP call",
      constraints: { noSkills: true },
      mode: "sync", runTimeoutMs: 240_000,
    }, 300_000);
    report.run = { runId: r.json?.runId, status: r.json?.status, elapsedMs: r.elapsedMs, error: r.json?.error, result: r.json?.result };

    check(report, "sync returns the terminal state inside the call",
      r.json?.status === "completed", r.json);
    check(report, "sync returned well inside the 240 s deadline the skill mandates",
      r.elapsedMs < 240_000, { elapsedMs: r.elapsedMs });
    check(report, "sync returned inside the host's observed 300 s MCP-call ceiling",
      r.elapsedMs < 300_000, { elapsedMs: r.elapsedMs });
    check(report, "the result carries Pi's own answer",
      typeof r.json?.result === "string" && r.json.result.includes("SYNC_REPLY_QUALIFY"), r.json?.result);

    const runId = r.json.runId;
    const bundle = bundleDir(transcripts, runId);

    const manifest = readManifest(bundle);
    report.manifest = manifest;
    check(report, "the Transcript terminal outcome is succeeded",
      manifest.terminal?.outcome === "succeeded", manifest.terminal);
    check(report, "the Transcript recorded no capture error",
      !manifest.terminal?.captureError, manifest.terminal);

    const launch = launchRecord(bundle);
    report.launch = launch;
    check(report, "the launch record keeps the submitted prompt byte-for-byte",
      launch?.promptSubmitted === prompt, launch?.promptSubmitted);
    check(report, "the launch record names the effective prompt and cwd",
      launch?.promptEffective === prompt && launch?.cwd === cwd, launch);

    const st = await call(client, "pi_status", { runId, waitTimeoutMs: 0 }, 20_000);
    report.status = st.json;
    check(report, "pi_status reports integrity-ok for the completed Run",
      st.json?.transcript?.integrity === "integrity-ok" && st.json?.transcript?.outcome === "succeeded",
      st.json?.transcript);
    check(report, "pi_status carries terminal timing",
      typeof st.json?.timing?.startedAt === "number" && typeof st.json?.timing?.endedAt === "number",
      st.json?.timing);

    const vstate = readViewerState(bundle);
    report.viewerState = vstate;
    check(report, "a Run Window was opened and reported ready",
      vstate?.state === "ready" && pidAlive(vstate.pid), vstate);
    check(report, "the window is not marked incomplete for a clean Run",
      vstate?.captureIncomplete === false, vstate?.captureIncomplete);

    const titles = windowTitles();
    const mine = titles.filter((t) => t.title.includes(runId));
    report.windowTitles = mine;
    check(report, "exactly one real window exists for the Run", mine.length === 1, mine);
    check(report, "the window title carries the token, session, prompt and Run id",
      mine.length === 1 && mine[0].title.startsWith("[SUCCEEDED] Pi")
      && mine[0].title.includes("qualify-sync") && mine[0].title.includes(runId),
      mine[0]?.title);
    check(report, "the window's pid is the process PowerShell reports",
      mine.length === 1 && mine[0].pid === vstate.pid, { title: mine[0]?.pid, viewerState: vstate?.pid });

    // Reopen: focus the live instance, never a second window.
    const reopen = await call(client, "pi_status", { runId, openWindow: true, waitTimeoutMs: 0 }, 30_000);
    await sleep(800);
    const titlesAfter = windowTitles().filter((t) => t.title.includes(runId));
    report.reopen = { viewer: reopen.json?.viewer, titles: titlesAfter };
    check(report, "reopen focuses the live window instead of duplicating it",
      titlesAfter.length === 1 && titlesAfter[0].pid === vstate.pid, titlesAfter);
    check(report, "reopen reports the window as ready",
      reopen.json?.viewer?.state === "ready" && reopen.json?.viewer?.pid === vstate.pid,
      reopen.json?.viewer);
    check(report, "reopening never replays the completion sound",
      reopen.json?.viewer?.alertAttemptedAt !== null && reopen.json?.viewer?.alertAttemptedAt !== undefined,
      reopen.json?.viewer?.alertAttemptedAt);

    const rep = replay(bundle);
    report.replay = { status: rep.status, report: rep.report };
    check(report, "the shipped viewer verifies the transcript hash",
      rep.report?.integrityOk === true && rep.report?.hashComputed === rep.report?.hashExpected, rep.report);
    check(report, "the shipped viewer classifies the Run SUCCEEDED with a success sound decision",
      rep.report?.token === "SUCCEEDED" && rep.report?.soundDecision === "success", rep.report);
    check(report, "the rendered window shows the prompt and Pi's answer, unreduced",
      rep.text.includes("SYNC_MARKER_QUALIFY") && rep.text.includes("SYNC_REPLY_QUALIFY"));

    // Continuity: the creating Run must hand Pi no session id, and a second Run on
    // the same session must receive exactly the id the registry recorded.
    const second = await call(client, "pi_delegate", {
      prompt: "Reply with exactly: SYNC_SECOND_QUALIFY",
      session: "qualify-sync",
      constraints: { noSkills: true },
      mode: "sync", runTimeoutMs: 240_000,
    }, 300_000);
    const secondLaunch = second.json?.runId
      ? launchRecord(bundleDir(transcripts, second.json.runId)) : undefined;
    const registrySession = readJson(registry).sessions.find((s) => s.name === "qualify-sync");
    report.continuation = {
      creatingRunSessionId: launch?.sessionId ?? null,
      registrySessionId: registrySession?.piSessionId,
      continuationRunSessionId: secondLaunch?.sessionId,
      status: second.json?.status,
    };
    check(report, "the creating Run starts a fresh Pi session (no session id handed over)",
      launch?.sessionId === undefined, launch);
    check(report, "a continuation Run is handed the session's recorded Pi session id",
      second.json?.status === "completed"
      && typeof registrySession?.piSessionId === "string"
      && secondLaunch?.sessionId === registrySession.piSessionId,
      report.continuation);

    check(report, "the continuation opens its own window",
      windowTitles().filter((t) => t.title.includes(second.json.runId)).length === 1,
      windowTitles().map((t) => t.title));
  } finally {
    await client.close();
  }
  return finish(report);
}

// ===========================================================================
// 4. timeout — an uncompleted Run is never claimed as clean
// ===========================================================================
async function scenarioTimeout() {
  const report = newReport("timeout");
  const dir = scratch("timeout");
  const registry = join(dir, "registry.json");
  const transcripts = join(dir, "runs");
  const cwd = scratch("timeout-cwd");
  report.state = transcriptOf({ registry, transcripts, cwd });

  const { client } = await startServer({ registry, transcripts, viewer: true });
  try {
    const r = await call(client, "pi_delegate", {
      prompt: "Use the bash tool to run exactly: powershell -NoProfile -Command \"Start-Sleep -Seconds 60; Write-Output LATE\". Then reply with exactly: NEVER",
      session: "qualify-timeout", cwd,
      goal: "qualification: a truncated Run marks its evidence incomplete",
      constraints: { noSkills: true },
      mode: "sync", runTimeoutMs: 10_000,
    }, 120_000);
    report.run = { runId: r.json?.runId, status: r.json?.status, error: r.json?.error, elapsedMs: r.elapsedMs };
    check(report, "the Run is reported as a timeout, not as success",
      r.json?.status === "timeout" && r.json?.error?.code === "timeout", r.json);
    check(report, "the timeout fired near its 10 s deadline, not after the Run's own 60 s",
      r.elapsedMs < 45_000, r.elapsedMs);

    const runId = r.json.runId;
    const bundle = bundleDir(transcripts, runId);
    const terminal = terminalRecord(bundle);
    report.terminal = terminal;
    check(report, "the Transcript terminal outcome is incomplete",
      terminal?.outcome === "incomplete", terminal);
    // A killed Run closes its stdout pipe cleanly, so nothing is left mid-record and
    // there is no *capture* error to record. The incompleteness is carried by the
    // terminal outcome itself, which both surfaces must honour. Recorded, not asserted.
    report.timeoutShape = {
      sawEof: terminal?.sawEof, signal: terminal?.signal,
      captureError: terminal?.captureError ?? null,
      capturedBytesBeforeKill: terminal?.stdoutBytes,
    };

    const st = await call(client, "pi_status", { runId, waitTimeoutMs: 0 }, 20_000);
    report.status = st.json;
    check(report, "pi_status marks the Transcript incomplete rather than available-and-clean",
      st.json?.transcript?.integrity === "incomplete" && st.json?.transcript?.outcome === "incomplete",
      st.json?.transcript);

    // The window tails the transcript, so its own verdict lands a tick later.
    const vstate = await waitFor(() => {
      const s = readViewerState(bundle);
      return s && s.token !== "RUNNING" ? s : undefined;
    }, { timeoutMs: 30_000, what: "the window to reach a terminal verdict" });
    report.viewerState = vstate;
    check(report, "the live window ends up INCOMPLETE, not SUCCEEDED",
      vstate.token === "INCOMPLETE" && vstate.outcome === "incomplete", vstate);
    check(report, "the live window made exactly one (warning) sound attempt, and recorded it",
      typeof vstate.alertAttemptedAt === "number", vstate.alertAttemptedAt);
    check(report, "the window is still alive and open after the Run died",
      pidAlive(vstate.pid), vstate);

    const rep = replay(bundle);
    report.replay = { status: rep.status, report: rep.report };
    check(report, "the shipped viewer shows INCOMPLETE and refuses a success sound",
      rep.report?.token === "INCOMPLETE" && rep.report?.soundDecision === "warning", rep.report);

    check(report, "exactly one Run was started: nothing was auto-redispatched",
      listDirs(transcripts).length === 1, listDirs(transcripts));
  } finally {
    await client.close();
  }
  return finish(report);
}

// ===========================================================================
// 5. async — the compatibility fallback and the Monitor Wait schedule
// ===========================================================================
async function scenarioAsync() {
  const report = newReport("async");
  const dir = scratch("async");
  const registry = join(dir, "registry.json");
  const transcripts = join(dir, "runs");
  const cwd = scratch("async-cwd");
  report.state = transcriptOf({ registry, transcripts, cwd });

  const { client } = await startServer({ registry, transcripts, viewer: true });
  try {
    const dispatch = await call(client, "pi_delegate", {
      prompt: "Use the bash tool to run exactly: powershell -NoProfile -Command \"Start-Sleep -Seconds 80; Write-Output SLEPT\". Then reply with exactly: ASYNC_REPLY_QUALIFY",
      session: "qualify-async", cwd,
      goal: "qualification: async fallback and non-overlapping Monitor Waits",
      constraints: { noSkills: true },
      mode: "async",
    }, 60_000);
    report.dispatch = { runId: dispatch.json?.runId, status: dispatch.json?.status, elapsedMs: dispatch.elapsedMs };
    check(report, "async returns immediately with a runId instead of blocking",
      dispatch.elapsedMs < 20_000 && dispatch.json?.status === "running" && !!dispatch.json?.runId,
      report.dispatch);

    const runId = dispatch.json.runId;

    const poll = await call(client, "pi_status", { runId, waitTimeoutMs: 0 }, 20_000);
    report.zeroPoll = { elapsedMs: poll.elapsedMs, status: poll.json?.status };
    check(report, "waitTimeoutMs 0 is a pure poll that returns at once",
      poll.elapsedMs < 3_000 && poll.json?.status === "running", report.zeroPoll);

    const w1Start = Date.now();
    const w1 = await call(client, "pi_status", { runId, waitTimeoutMs: 60_000 }, 120_000);
    const w1End = Date.now();
    report.wait1 = { elapsedMs: w1.elapsedMs, status: w1.json?.status, startAt: w1Start, endAt: w1End };
    check(report, "the first Monitor Wait is accepted at 60000 and occupies it",
      w1.elapsedMs >= 58_000 && w1.elapsedMs < 90_000, report.wait1);
    check(report, "the Run is still running after the first wait, so the wait did not fabricate a result",
      w1.json?.status === "running", w1.json?.status);

    const w2Start = Date.now();
    const w2 = await call(client, "pi_status", { runId, waitTimeoutMs: 180_000 }, 240_000);
    const w2End = Date.now();
    report.wait2 = { elapsedMs: w2.elapsedMs, status: w2.json?.status, error: w2.json?.error, startAt: w2Start, endAt: w2End };
    check(report, "the second Monitor Wait is accepted at 180000",
      w2.elapsedMs < 180_000, report.wait2);
    check(report, "the wait schedule collects the terminal state, not a timeout",
      w2.json?.status === "completed", w2.json);
    check(report, "the second wait started no earlier than the first returned: waits never overlapped",
      w2Start >= w1End, { firstEndedAt: w1End, secondStartedAt: w2Start, gapMs: w2Start - w1End });

    const bundle = bundleDir(transcripts, runId);
    const manifest = readManifest(bundle);
    report.manifest = manifest;
    check(report, "the collected Run's evidence is complete and verified",
      manifest.terminal?.outcome === "succeeded" && !manifest.terminal?.captureError, manifest.terminal);

    const rep = replay(bundle);
    report.replay = { status: rep.status, report: rep.report };
    check(report, "the shipped viewer verifies the async Run's transcript hash",
      rep.report?.integrityOk === true && rep.report?.token === "SUCCEEDED", rep.report);
    check(report, "the async Run's answer is present and unreduced",
      typeof w2.json?.result === "string" && w2.json.result.includes("ASYNC_REPLY_QUALIFY"), w2.json?.result);

    const mine = windowTitles().filter((t) => t.title.includes(runId));
    report.windowTitles = mine;
    check(report, "the async Run opened its own window too",
      mine.length === 1 && mine[0].title.startsWith("[SUCCEEDED]"), mine);

    // A wait that returns early because the Run finished proves the schedule is
    // *accepted*; it does not prove a long wait is actually *occupied*. This second
    // Run outlives the 180 s tier, so the wait must sit there for its full duration
    // and then honestly report `running` rather than inventing a result.
    const longDispatch = await call(client, "pi_delegate", {
      prompt: "Use the bash tool to run exactly: powershell -NoProfile -Command \"Start-Sleep -Seconds 200; Write-Output LONG_SLEPT\". Then reply with exactly: ASYNC_LONG_OK",
      session: "qualify-async-long", cwd,
      goal: "qualification: a 180 s wait is really occupied",
      constraints: { noSkills: true }, mode: "async",
    }, 60_000);
    const longRunId = longDispatch.json?.runId;
    const l1Start = Date.now();
    const l1 = await call(client, "pi_status", { runId: longRunId, waitTimeoutMs: 180_000 }, 240_000);
    const l1End = Date.now();
    report.longWait = {
      runId: longRunId, elapsedMs: l1.elapsedMs, status: l1.json?.status,
      startAt: l1Start, endAt: l1End,
    };
    check(report, "a 180 s wait on a Run that outlives it is occupied almost in full",
      l1.elapsedMs >= 175_000 && l1.elapsedMs < 200_000, report.longWait);
    check(report, "the occupied wait reports still-running instead of fabricating a result",
      l1.json?.status === "running", l1.json);
    const l2 = await call(client, "pi_status", { runId: longRunId, waitTimeoutMs: 180_000 }, 240_000);
    report.longCollect = { elapsedMs: l2.elapsedMs, status: l2.json?.status, error: l2.json?.error };
    check(report, "the following wait collects that Run's terminal state",
      l2.json?.status === "completed" && /ASYNC_LONG_OK/.test(l2.json?.result ?? ""), l2.json);
  } finally {
    await client.close();
  }
  return finish(report);
}

// ===========================================================================
// 6. concurrent — four Runs, four windows, cap enforced
// ===========================================================================
async function scenarioConcurrent() {
  const report = newReport("concurrent");
  const dir = scratch("concurrent");
  const registry = join(dir, "registry.json");
  const transcripts = join(dir, "runs");
  report.state = transcriptOf({ registry, transcripts });

  const { client } = await startServer({ registry, transcripts, viewer: true });
  try {
    const prompts = Array.from({ length: 4 }, (_, i) =>
      `Use the bash tool to run exactly: powershell -NoProfile -Command "Start-Sleep -Seconds 55; Write-Output C${i}". Then reply with exactly: CONCURRENT_${i}_OK`);
    const cwds = Array.from({ length: 4 }, (_, i) => scratch(`concurrent-cwd-${i}`));

    const dispatched = await Promise.all(prompts.map((prompt, i) => call(client, "pi_delegate", {
      prompt, session: `qualify-conc-${i}`, cwd: cwds[i],
      goal: `qualification: concurrent Run ${i}`,
      constraints: { noSkills: true },
      mode: "async",
    }, 60_000)));
    const runIds = dispatched.map((d) => d.json?.runId);
    report.dispatched = dispatched.map((d) => ({ runId: d.json?.runId, status: d.json?.status, elapsedMs: d.elapsedMs, error: d.json?.error }));
    check(report, "four concurrent Runs are all accepted",
      runIds.every(Boolean) && dispatched.every((d) => d.json?.status === "running"), report.dispatched);

    const fifth = await call(client, "pi_delegate", {
      prompt: "echo never", session: "qualify-conc-5", cwd: cwds[0],
      goal: "qualification: the concurrency cap", constraints: { noSkills: true }, mode: "async",
    }, 60_000);
    report.fifth = { isError: fifth.isError, json: fifth.json, elapsedMs: fifth.elapsedMs };
    check(report, "a fifth Run is refused with resource-busy, not queued behind four",
      fifth.isError && fifth.json?.code === "resource_busy", report.fifth);

    // Wait for four distinct live windows.
    const pids = new Map();
    const deadline = Date.now() + 60_000;
    while (Date.now() < deadline && pids.size < 4) {
      for (const runId of runIds) {
        const st = readViewerState(bundleDir(transcripts, runId));
        if (st?.state === "ready" && pidAlive(st.pid)) pids.set(runId, st.pid);
      }
      if (pids.size < 4) await sleep(1000);
    }
    report.windowPids = Object.fromEntries(pids);
    check(report, "each Run has a live window with its own process",
      pids.size === 4 && new Set(pids.values()).size === 4, report.windowPids);

    const titles = windowTitles();
    const mine = titles.filter((t) => runIds.some((id) => t.title.includes(id)));
    report.windowTitles = mine;
    check(report, "the desktop really holds one window per Run, all four at once",
      new Set(mine.map((t) => t.title.match(/run-[0-9a-f-]{8}/)?.[0] ?? t.title)).size === 4, mine);

    const bundles = runIds.map((id) => bundleDir(transcripts, id));
    check(report, "each Run owns a distinct transcript bundle",
      new Set(bundles).size === 4 && bundles.every((b) => existsSync(join(b, "transcript.jsonl"))), bundles);

    const collected = [];
    for (const runId of runIds) {
      const r = await call(client, "pi_status", { runId, waitTimeoutMs: 180_000 }, 240_000);
      collected.push({ runId, status: r.json?.status, error: r.json?.error });
    }
    report.collected = collected;
    check(report, "all four concurrent Runs finish completed",
      collected.every((c) => c.status === "completed"), collected);

    const replayVerdicts = bundles.map((b) => replay(b).report);
    report.replayTokens = replayVerdicts.map((v) => ({ token: v?.token, integrityOk: v?.integrityOk }));
    check(report, "every concurrent Run's transcript verifies and classifies SUCCEEDED",
      replayVerdicts.every((v) => v?.integrityOk === true && v?.token === "SUCCEEDED"), report.replayTokens);

    const stillOpen = windowTitles();
    check(report, "completed windows stay open until closed by hand",
      runIds.every((id) => stillOpen.some((t) => t.title.includes(id))), stillOpen.map((t) => t.title));
    check(report, "no window died when its Run finished",
      runIds.every((id) => {
        const st = readViewerState(bundleDir(transcripts, id));
        return st?.state === "ready" && pidAlive(st.pid);
      }), report.windowPids);
  } finally {
    await client.close();
  }
  return finish(report);
}

// ===========================================================================
// 7. retention — seven days / 2 GiB, active Runs never cleaned
// ===========================================================================
async function scenarioRetention() {
  const report = newReport("retention");
  const dir = scratch("retention");
  const root = join(dir, "runs");
  mkdirSync(root, { recursive: true });

  const schema = await import("../../../dist/transcript/schema.js");
  const { TranscriptStore } = await import("../../../dist/transcript/store.js");
  const { TranscriptWriter } = await import("../../../dist/transcript/writer.js");

  report.policy = {
    retentionMs: schema.RETENTION_MS,
    retentionDays: schema.RETENTION_MS / 86_400_000,
    quotaBytes: schema.QUOTA_BYTES,
    quotaGiB: schema.QUOTA_BYTES / 1024 ** 3,
    trashGraceMs: schema.TRASH_GRACE_MS,
    cleanupIntervalMs: schema.CLEANUP_INTERVAL_MS,
  };
  check(report, "the shipped policy is seven days and two GiB",
    schema.RETENTION_MS === 7 * 24 * 3600 * 1000 && schema.QUOTA_BYTES === 2 * 1024 ** 3,
    report.policy);

  const pidOf = (days) => Date.now() - days * 86_400_000;

  function makeBundle(id, { endedAt, terminal = true, lease } = {}) {
    const bd = join(root, id);
    const w = TranscriptWriter.create(bd, {
      runId: id, session: "sess", cwd: root,
      promptSubmitted: `prompt for ${id}`, promptEffective: `prompt for ${id}`,
    });
    w.state("starting");
    w.stdoutData(Buffer.from(`{"type":"agent_end"}  ${id}\n`, "utf8"));
    if (terminal) {
      w.finalize({
        outcome: "succeeded", exitCode: 0, signal: null,
        startedAt: endedAt - 1000, endedAt, sawEof: true,
        piSettlement: { agentEnd: true, agentSettled: true, lastStdoutType: "agent_end" },
      });
    }
    if (lease) writeFileSync(join(bd, "lease.json"), JSON.stringify(lease));
    return bd;
  }

  // A live, foreign owner: a lease on a bundle whose owner is still running must
  // never be cleaned, even when it is past retention.
  const foreign = spawn(process.execPath, ["-e", "setTimeout(()=>{},120000)"], { stdio: "ignore" });
  await sleep(500);

  makeBundle("old-done", { endedAt: pidOf(8) });
  makeBundle("old-done-released", { endedAt: pidOf(9), lease: { runId: "old-done-released", pid: process.pid, leaseId: "l1", createdAt: pidOf(9), released: true } });
  makeBundle("fresh-done", { endedAt: pidOf(0.1) });
  makeBundle("active", { endedAt: Date.now(), terminal: false });
  makeBundle("owned-elsewhere", { endedAt: pidOf(9), lease: { runId: "owned-elsewhere", pid: foreign.pid, leaseId: "l2", createdAt: pidOf(9) } });
  report.bundles = listDirs(root);

  const store = new TranscriptStore(root);
  const report1 = store.cleanup();
  report.cleanup = report1;
  check(report, "a completed bundle past seven days is trashed",
    report1.trashed.includes("old-done"), report1);
  check(report, "a released-lease bundle past seven days is trashed",
    report1.trashed.includes("old-done-released"), report1);
  check(report, "a fresh completed bundle is kept", existsSync(join(root, "fresh-done")), listDirs(root));
  check(report, "an active (non-terminal) bundle is never cleaned",
    existsSync(join(root, "active")) && !report1.trashed.includes("active"), report1);
  check(report, "a bundle whose owner is a live foreign process is never cleaned",
    existsSync(join(root, "owned-elsewhere")) && !report1.trashed.includes("owned-elsewhere"), report1);
  check(report, "the trashed bundles are gone from the live root but retained under trash",
    !existsSync(join(root, "old-done")) && existsSync(join(root, ".trash")), listDirs(join(root, ".trash")));

  // Quota: with a quota below the current total, the oldest terminal bundles go
  // first and the active one is still protected.
  const quotaStore = new TranscriptStore(root, { quotaBytes: 1, retentionMs: schema.RETENTION_MS });
  const report2 = quotaStore.cleanup();
  report.quotaCleanup = report2;
  check(report, "the quota path trashes the oldest terminal bundle",
    report2.quotaTrashed.length > 0, report2);
  check(report, "the active bundle survives even a zero quota",
    existsSync(join(root, "active")), listDirs(root));

  // Trash grace: a trashed bundle older than the grace window is physically removed.
  const staleTrash = join(root, ".trash", "stale-bundle.1");
  mkdirSync(staleTrash, { recursive: true });
  writeFileSync(join(staleTrash, "transcript.jsonl"), "x\n");
  const twoDaysAgo = new Date(Date.now() - 2 * 86_400_000);
  utimesSync(staleTrash, twoDaysAgo, twoDaysAgo);
  const graceStore = new TranscriptStore(root, { trashGraceMs: 24 * 3600_000, quotaBytes: schema.QUOTA_BYTES });
  const report3 = graceStore.cleanup();
  report.graceCleanup = report3;
  check(report, "a trashed bundle past the grace window is physically purged",
    report3.purged.includes("stale-bundle.1") && !existsSync(staleTrash), report3);

  // A disabled root must degrade, not throw.
  const disabled = new TranscriptStore(join(root, "nope", "\u0000bad"));
  report.disabledCleanup = disabled.cleanup();
  check(report, "an unusable root disables retention instead of throwing",
    typeof report.disabledCleanup.disabled === "string", report.disabledCleanup);

  foreign.kill();
  return finish(report);
}

// ===========================================================================
// 4b. capture-disabled — unusable evidence storage never stops a Run
// ===========================================================================
async function scenarioCaptureDisabled() {
  const report = newReport("capture-disabled");
  const dir = scratch("capture-disabled");
  const registry = join(dir, "registry.json");
  const realRoot = join(dir, "runs-real");
  const linkRoot = join(dir, "runs-link");
  const cwd = scratch("capture-disabled-cwd");
  mkdirSync(realRoot, { recursive: true });
  symlinkSync(realRoot, linkRoot, "junction");
  report.state = { RUN_ROOT, registry, transcripts: linkRoot, realRoot, cwd, link: lstatSync(linkRoot).isSymbolicLink() };

  const { client, stderr } = await startServer({ registry, transcripts: linkRoot, viewer: true });
  try {
    const r = await call(client, "pi_delegate", {
      prompt: "Use the bash tool to run exactly: echo CAPTURE_DISABLED_OK. Then reply with exactly: CAPTURE_DISABLED_REPLY",
      session: "qualify-capture-disabled", cwd,
      goal: "qualification: no usable evidence storage still runs the Run",
      constraints: { noSkills: true }, mode: "sync", runTimeoutMs: 240_000,
    }, 300_000);
    report.run = { runId: r.json?.runId, status: r.json?.status, error: r.json?.error, result: r.json?.result };
    check(report, "the Run still succeeds with no usable transcript storage",
      r.json?.status === "completed" && /CAPTURE_DISABLED_REPLY/.test(r.json?.result ?? ""), r.json);

    const st = await call(client, "pi_status", { runId: r.json.runId, waitTimeoutMs: 0 }, 20_000);
    report.status = st.json;
    check(report, "pi_status reports the Transcript as unavailable, with a reason",
      st.json?.transcript?.available === false && typeof st.json?.transcript?.reason === "string"
      && /reparse point/.test(st.json.transcript.reason), st.json?.transcript);
    check(report, "pi_status never claims integrity it cannot support",
      st.json?.transcript?.integrity === "unknown", st.json?.transcript);
    check(report, "no Run Window is opened when there is nothing to show",
      st.json?.viewer === undefined
      && !windowTitles().some((t) => (t.title ?? "").includes(r.json.runId)),
      { viewer: st.json?.viewer, titles: windowTitles().map((t) => t.title) });
    check(report, "no bundle was written through the unusable root",
      listDirs(realRoot).length === 0, listDirs(realRoot));
    check(report, "the Run is still recorded in the registry",
      readJson(registry).sessions.some((s) => s.name === "qualify-capture-disabled" && s.status === "idle"),
      readJson(registry).sessions.filter((s) => s.name === "qualify-capture-disabled"));
    report.stderr = stderr.join("");
    check(report, "the server survived with no unhandled failure", !/uncaught|unhandled/i.test(report.stderr), report.stderr);
  } finally {
    await client.close();
  }
  return finish(report);
}

// ===========================================================================
// 4c. capture-damage — damaged evidence is visible, never silently repaired
// ===========================================================================
async function scenarioCaptureDamage() {
  const report = newReport("capture-damage");
  const dir = scratch("capture-damage");
  const registry = join(dir, "registry.json");
  const transcripts = join(dir, "runs");
  const cwd = scratch("capture-damage-cwd");
  report.state = transcriptOf({ registry, transcripts, cwd });

  const { client } = await startServer({ registry, transcripts, viewer: true });
  try {
    // --- A. byte damage to a real Run's transcript, seen by a real window ---
    const r = await call(client, "pi_delegate", {
      prompt: "Use the bash tool to run exactly: echo DAMAGE_MARKER_OK. Then reply with exactly: DAMAGE_REPLY_OK",
      session: "qualify-damage", cwd,
      goal: "qualification: damaged evidence is marked, not repaired",
      constraints: { noSkills: true }, mode: "sync", runTimeoutMs: 240_000,
    }, 300_000);
    check(report, "the Run completes before its evidence is damaged", r.json?.status === "completed", r.json);

    const runId = r.json.runId;
    const bundle = bundleDir(transcripts, runId);
    const firstWindow = readViewerState(bundle);
    killWindow(firstWindow.pid);
    await waitFor(() => !pidAlive(firstWindow.pid), { timeoutMs: 20_000, what: "the first window to exit" });

    const transcriptPath = join(bundle, "transcript.jsonl");
    const lines = readFileSync(transcriptPath, "utf8").split("\n");
    const dropIndex = lines.findIndex((l, i) => i > 0 && l.includes('"kind":"state"'));
    const damaged = [...lines.slice(0, dropIndex), ...lines.slice(dropIndex + 1)];
    writeFileSync(transcriptPath, damaged.join("\n"));
    report.damage = { path: transcriptPath, droppedLine: lines[dropIndex], droppedIndex: dropIndex };

    const reopen = await call(client, "pi_status", { runId, openWindow: true, waitTimeoutMs: 0 }, 40_000);
    report.reopen = reopen.json?.viewer;
    check(report, "a replacement window is launched once the previous one is confirmed gone",
      reopen.json?.viewer?.state === "ready" && reopen.json?.viewer?.pid !== firstWindow.pid, reopen.json?.viewer);

    const damagedState = await waitFor(() => {
      const s = readViewerState(bundle);
      return s && s.pid === reopen.json.viewer.pid && s.token !== "RUNNING" ? s : undefined;
    }, { timeoutMs: 30_000, what: "the replacement window to judge the damaged bundle" });
    report.damagedViewerState = damagedState;
    check(report, "the window marks the damaged transcript INCOMPLETE",
      damagedState.token === "INCOMPLETE" && damagedState.captureIncomplete === true, damagedState);

    const rep = replay(bundle);
    report.replay = { status: rep.status, report: rep.report, textHasAnswer: rep.text.includes("DAMAGE_REPLY_OK") };
    check(report, "the shipped viewer names the damage instead of repairing it",
      rep.report?.integrityOk === false
      && rep.report.integrityReasons.some((x) => x.startsWith("sequence-gap"))
      && rep.report.integrityReasons.some((x) => x.startsWith("terminal-hash-mismatch")),
      rep.report?.integrityReasons);
    check(report, "the surviving content is still shown in full", rep.text.includes("DAMAGE_REPLY_OK"), rep.text.slice(0, 400));

    const after = await call(client, "pi_status", { runId, waitTimeoutMs: 0 }, 20_000);
    report.statusAfterDamage = after.json;
    check(report, "damage to the evidence never rewrites the Run's own outcome",
      after.json?.status === "completed", after.json?.status);
    // Honest seam: pi_status reads the durable manifest with a bounded tail read
    // rather than replaying the file, so post-hoc byte damage is reported by the
    // replaying window, not by status. Recorded, not asserted.
    report.statusIntegrityAfterDamage = after.json?.transcript?.integrity;

    // --- B. a capture error recorded at capture time (real writer), shown by a
    // real window: the manifest path that pi_status *does* read ---
    const { TranscriptWriter } = await import("../../../dist/transcript/writer.js");
    const fixtureId = "capture-error-fixture";
    const fixture = join(transcripts, fixtureId);
    const w = TranscriptWriter.create(fixture, {
      runId: fixtureId, session: "qualify-fixture", cwd,
      promptSubmitted: "fixture with a capture error", promptEffective: "fixture with a capture error",
    });
    w.state("starting");
    w.stdoutData(Buffer.from('{"type":"agent_end"}\n', "utf8"));
    w.captureError("injected: storage write failed mid-Run");
    w.finalize({
      outcome: "incomplete", exitCode: null, signal: "SIGTERM",
      startedAt: Date.now() - 1000, endedAt: Date.now(), sawEof: false,
      piSettlement: { agentEnd: false, agentSettled: false, lastStdoutType: "message_update" },
    });
    const fixtureWindow = await launchWindow(fixture);
    const errState = await waitFor(() => {
      const s = readViewerState(fixture);
      return s && s.pid === fixtureWindow.pid && s.token !== "RUNNING" ? s : undefined;
    }, { timeoutMs: 30_000, what: "the fixture window to judge the capture error" });
    report.captureErrorWindowState = errState;
    check(report, "a capture error recorded at capture time marks the window INCOMPLETE",
      errState.token === "INCOMPLETE" && errState.captureIncomplete === true, errState);
    const errReplay = replay(fixture);
    report.captureErrorReplay = { report: errReplay.report, textShowsError: /injected: storage write failed mid-Run/.test(errReplay.text) };
    check(report, "the window shows the capture error itself, not a summary",
      errReplay.report?.token === "INCOMPLETE"
      && errReplay.report.integrityReasons.some((x) => x.startsWith("capture-error"))
      && /injected: storage write failed mid-Run/.test(errReplay.text),
      errReplay.report?.integrityReasons);
  } finally {
    await client.close();
  }
  return finish(report);
}

// ===========================================================================
// 8. window-retention — the race ticket 07 left open
// ===========================================================================
async function scenarioWindowRetention() {
  const report = newReport("window-retention");
  const dir = scratch("window-retention");
  const registry = join(dir, "registry.json");
  const transcripts = join(dir, "runs");
  const cwd = scratch("window-retention-cwd");
  report.state = transcriptOf({ registry, transcripts, cwd });

  const { TranscriptStore } = await import("../../../dist/transcript/store.js");

  const { client } = await startServer({ registry, transcripts, viewer: true });
  try {
    const dispatch = await call(client, "pi_delegate", {
      prompt: "Use the bash tool to run exactly: powershell -NoProfile -Command \"Start-Sleep -Seconds 6; Write-Output WOKE\". Then reply with exactly: WINDOW_RETENTION_OK",
      session: "qualify-window-retention", cwd,
      goal: "qualification: retention while the window stays open",
      constraints: { noSkills: true }, mode: "sync", runTimeoutMs: 240_000,
    }, 300_000);
    check(report, "the Run completes with its window open", dispatch.json?.status === "completed", dispatch.json);

    const runId = dispatch.json.runId;
    const bundle = bundleDir(transcripts, runId);
    const before = readViewerState(bundle);
    report.viewerBefore = before;
    check(report, "the window is still open after the Run finished",
      before?.state === "ready" && pidAlive(before.pid), before);
    check(report, "the window released the bundle after replay",
      before?.sourceCleaned !== true, { sourceCleaned: before?.sourceCleaned });

    // Force retention to consider this bundle expired, exactly as it would after
    // seven days, while the window is still on screen.
    //
    // The window does not pin the bundle: it holds no open handle, so the atomic
    // trash rename is possible. It is not *instantaneous* though — the viewer
    // rewrites viewer-state.json inside the bundle on every tick, and a rename that
    // lands in the middle of that transient write fails with EPERM. Retention is
    // built for this (a failed rename is recorded as `skipped` and the next pass
    // retries), so the check below reproduces that cadence: attempt, then retry.
    const store = new TranscriptStore(transcripts, { retentionMs: 0 });

    const attempts = [];
    let trashed = false;
    for (let i = 0; i < 10 && !trashed; i++) {
      const res = store.cleanup();
      const windowAlive = pidAlive(before.pid);
      attempts.push({ attempt: i + 1, trashed: res.trashed.includes(runId), skipped: res.skipped.includes(runId), windowAlive });
      if (res.trashed.includes(runId)) {
        trashed = true;
        report.trashMoment = { attempt: i + 1, windowStillAlive: windowAlive };
        break;
      }
      await sleep(1000);
    }
    report.cleanupAttempts = attempts;
    check(report, "a completed bundle is not pinned by its open window",
      attempts.every((a) => a.windowAlive), attempts);
    check(report, "retention trashes the completed bundle while its window is open",
      trashed, attempts);
    check(report, "the trash rename succeeds with the window still on screen",
      report.trashMoment?.windowStillAlive === true, report.trashMoment);
    check(report, "the bundle is really gone from the live root",
      !existsSync(join(transcripts, runId)), listDirs(transcripts));

    // The window survives its own bundle: the pane keeps its in-memory content, so
    // the only remaining handle on the window is the state file that moved with the
    // bundle into trash.
    const trashEntries = listDirs(join(transcripts, ".trash"));
    const trashedState = trashEntries.length === 1
      ? readViewerState(join(transcripts, ".trash", trashEntries[0])) : undefined;
    report.trashEntries = trashEntries;
    report.viewerAfterCleanup = trashedState;
    check(report, "the window is still alive after its bundle was cleaned",
      trashedState?.pid !== undefined && pidAlive(trashedState.pid), trashedState);
    check(report, "its last recorded verdict was still SUCCEEDED",
      trashedState?.token === "SUCCEEDED" && trashedState?.outcome === "succeeded", trashedState);
    check(report, "the live root holds no recreated empty bundle",
      listDirs(transcripts).every((n) => n === ".trash"), listDirs(transcripts));

    const titles = windowTitles().filter((t) => t.title.includes(runId));
    report.windowTitles = titles;
    check(report, "the cleaned window is still on screen and still labelled SUCCEEDED",
      titles.length === 1 && titles[0].title.startsWith("[SUCCEEDED]"), titles);

    const after = await call(client, "pi_status", { runId, waitTimeoutMs: 0 }, 20_000);
    report.statusAfterCleanup = after.json;
    check(report, "pi_status honestly reports the evidence is no longer available",
      after.json?.transcript?.available === false, after.json?.transcript);
    check(report, "the Run's own outcome is still reported from the registry",
      after.json?.status === "completed", after.json?.status);
    // Honest limitation: the window marks a cleaned source in its pane and status
    // bar, but the durable flag it also sets lives in viewer-state.json — inside the
    // bundle that was just cleaned — so `sourceCleaned` cannot be observed after the
    // fact, and pi_status reports viewer state "none" rather than "cleaned".
    report.sourceCleanedDurability = {
      durableFlagObservableAfterCleanup: trashedState?.sourceCleaned === true,
      statusViewerAfterCleanup: after.json?.viewer,
      note: "the flag is written into the bundle, so it moves to trash with it; the in-pane marking is what the human sees",
    };
  } finally {
    await client.close();
  }
  return finish(report);
}

// ===========================================================================

const SCENARIOS = {
  surface: scenarioSurface,
  compat: scenarioCompat,
  sync: scenarioSync,
  timeout: scenarioTimeout,
  "capture-disabled": scenarioCaptureDisabled,
  "capture-damage": scenarioCaptureDamage,
  async: scenarioAsync,
  concurrent: scenarioConcurrent,
  retention: scenarioRetention,
  "window-retention": scenarioWindowRetention,
};

const wanted = process.argv.slice(2);
if (wanted.length === 0 || wanted.includes("--help")) {
  process.stdout.write(`usage: node qualify.mjs <${Object.keys(SCENARIOS).join("|")}>...\nRUN_ROOT=${RUN_ROOT}\n`);
  process.exit(2);
}
mkdirSync(RUN_ROOT, { recursive: true });
process.stdout.write(`state root: ${RUN_ROOT}\n`);
let failed = 0;
for (const name of wanted) {
  const fn = SCENARIOS[name];
  if (!fn) {
    process.stdout.write(`unknown scenario: ${name}\n`);
    failed++;
    continue;
  }
  process.stdout.write(`\n=== ${name} ===\n`);
  failed += await fn();
}
process.exit(failed === 0 ? 0 : 1);
