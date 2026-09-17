// Run Window integration (ticket 07): platform gating, launch + ready handshake,
// one instance per Run, reopen/focus, failure isolation from Runs.
//
// The PowerShell viewer is substituted with test/fixtures/fake-viewer.mjs so
// this file exercises the real ViewerManager without opening a GUI window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { ViewerManager, VIEWER_READY_WAIT_MS, viewerCommand } from "../src/viewer/manager.js";
import { readViewerState, requestFocus, viewerStatePath, VIEWER_REQUEST_FILE } from "../src/viewer/state.js";
import { TranscriptStore } from "../src/transcript/store.js";
import { TranscriptWriter } from "../src/transcript/writer.js";
import { delegate } from "../src/tools/delegate.js";
import { status } from "../src/tools/status.js";
import { SessionRegistry } from "../src/registry/session.js";
import { RunRegistry } from "../src/registry/run.js";
import { ProcessTable } from "../src/runner/process-table.js";
import { pidAlive } from "../src/transcript/recovery.js";
import { fakePiEnv, tmpCwd, withEnv } from "./helpers.js";

const FAKE_VIEWER = resolve("test/fixtures/fake-viewer.mjs");

interface ViewerHarness {
  manager: ViewerManager;
  bundleDir: string;
  log: string;
  invocations: () => { event: string; pid: number; instanceId: string; mode: string }[];
  cleanups: (() => void)[];
}

function viewerHarness(mode = "ready"): ViewerHarness {
  const dir = mkdtempSync(join(tmpdir(), "pi-viewer-mgr-"));
  const bundleDir = join(dir, "bundle");
  mkdirSync(bundleDir, { recursive: true });
  const log = join(dir, "viewer-log.jsonl");
  const saved: Record<string, string | undefined> = {};
  const setEnv = (k: string, v: string) => { saved[k] = process.env[k]; process.env[k] = v; };
  setEnv("PI_SUBAGENT_POWERSHELL", process.execPath);   // node stands in for powershell.exe
  setEnv("PI_SUBAGENT_VIEWER_SCRIPT", FAKE_VIEWER);
  setEnv("FAKE_VIEWER_MODE", mode);
  setEnv("FAKE_VIEWER_LOG", log);

  return {
    manager: new ViewerManager(),
    bundleDir,
    log,
    invocations: () => {
      if (!existsSync(log)) return [];
      return readFileSync(log, "utf8").split("\n").filter(Boolean)
        .map((l) => JSON.parse(l))
        .filter((e) => e.event === "start" || e.event === "focus");
    },
    cleanups: [() => {
      for (const k of Object.keys(saved)) {
        if (saved[k] === undefined) delete process.env[k];
        else process.env[k] = saved[k];
      }
      rmSync(dir, { recursive: true, force: true });
    }],
  };
}

function killViewers(h: ViewerHarness): void {
  const st = readViewerState(h.bundleDir);
  if (st && pidAlive(st.pid)) {
    try { process.kill(st.pid); } catch { /* already gone */ }
  }
}

function seedBundle(bundleDir: string, runId: string): void {
  const w = TranscriptWriter.create(bundleDir, {
    runId, session: "s", cwd: "C:/work", promptSubmitted: "p", promptEffective: "p",
  });
  w.state("starting");
}

async function withHarness(mode: string, fn: (h: ViewerHarness) => Promise<void>): Promise<void> {
  const h = viewerHarness(mode);
  try {
    await fn(h);
  } finally {
    killViewers(h);
    for (const c of h.cleanups) c();
  }
}

// ===== launch command =====

test("viewer manager: the real launch command is STA, shell-free and passes the bundle as one argv element", () => {
  const cmd = viewerCommand("C:/repo/viewer/run-window.ps1", "powershell.exe", "C:/Users/a b/runs/run-1");
  assert.equal(cmd.command, "powershell.exe");
  assert.deepEqual(cmd.args, [
    "-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass",
    "-File", "C:/repo/viewer/run-window.ps1",
    "-BundleDir", "C:/Users/a b/runs/run-1",
  ]);
  // A bundle path with spaces, quotes or shell metacharacters stays one argv
  // element: nothing is interpolated through a shell.
  const nasty = viewerCommand("C:/repo/viewer/run-window.ps1", "powershell.exe", "C:/x/\"a&b\"|c;d");
  assert.equal(nasty.args[nasty.args.length - 1], "C:/x/\"a&b\"|c;d");

  // A stand-in viewer script is invoked directly (the automated-test seam).
  const stub = viewerCommand("C:/repo/test/fixtures/fake-viewer.mjs", "node.exe", "C:/b");
  assert.deepEqual(stub, { command: "node.exe", args: ["C:/repo/test/fixtures/fake-viewer.mjs", "-BundleDir", "C:/b"] });
});

// ===== gating =====

test("viewer manager: reports why the window is unavailable instead of failing a Run", () => {
  const missing = new ViewerManager({ script: "C:/definitely/not/here/run-window.ps1" });
  assert.equal(missing.available, false);
  assert.match(missing.unavailableReason() ?? "", /viewer script not found/);

  const disabled = new ViewerManager({ enabled: false });
  assert.equal(disabled.available, false);
  assert.match(disabled.unavailableReason() ?? "", /PI_SUBAGENT_VIEWER=off/);
  assert.deepEqual(
    { available: disabled.describe("C:/tmp").available, state: disabled.describe("C:/tmp").state },
    { available: false, state: "unavailable" },
  );

  if (process.platform !== "win32") {
    const off = new ViewerManager({ script: resolve("viewer/run-window.ps1") });
    assert.match(off.unavailableReason() ?? "", /Windows-only/);
  }
});

test("viewer manager: open() returns unavailable and never throws when the platform cannot show a window", async () => {
  const m = new ViewerManager({ enabled: false });
  assert.deepEqual(await m.open({ runId: "r", bundleDir: "C:/tmp" }), {
    status: "unavailable", reason: "disabled by PI_SUBAGENT_VIEWER=off",
  });
});

// ===== launch + handshake =====

test("viewer manager: launches with an argument array and completes the ready handshake", async () => {
  await withHarness("ready", async (h) => {
    const result = await h.manager.open({ runId: "run-1", bundleDir: h.bundleDir });
    assert.equal(result.status, "ready", JSON.stringify(result));
    assert.ok(result.pid && result.pid > 0);

    const launches = h.invocations().filter((e) => e.event === "start");
    assert.equal(launches.length, 1);
    assert.equal(launches[0].mode, "ready");

    const state = readViewerState(h.bundleDir);
    assert.equal(state?.state, "ready");
    assert.equal(state?.pid, result.pid);

    const described = h.manager.describe(h.bundleDir);
    assert.equal(described.available, true);
    assert.equal(described.state, "ready");
    assert.equal(described.pid, result.pid);
    assert.equal(described.alertAttemptedAt, null);
  });
});

test("viewer manager: a live viewer for the Run is focused, never duplicated", async () => {
  await withHarness("ready", async (h) => {
    const first = await h.manager.open({ runId: "run-1", bundleDir: h.bundleDir });
    assert.equal(first.status, "ready");

    const second = await h.manager.open({ runId: "run-1", bundleDir: h.bundleDir });
    assert.equal(second.status, "focused");
    assert.equal(second.pid, first.pid);

    // Exactly one viewer process was ever launched, and the focus request was
    // consumed by it.
    const started = h.invocations().filter((e) => e.event === "start");
    assert.equal(started.length, 1);
    const focus = await waitFor(() => {
      const events = h.invocations().filter((e) => e.event === "focus");
      return events.length > 0 ? events : undefined;
    }, 2000);
    assert.equal(focus.length, 1);
    assert.equal(focus[0].pid, first.pid);
    assert.equal(existsSync(join(h.bundleDir, VIEWER_REQUEST_FILE)), false);
  });
});

test("viewer manager: an instance that is alive but not yet ready is reused, never duplicated", async () => {
  await withHarness("slow", async (h) => {
    // First open gives up waiting while the window is still coming up.
    const first = await h.manager.open({ runId: "run-1", bundleDir: h.bundleDir, waitReadyMs: 100 });
    assert.equal(first.status, "starting");

    // A second open must join that same instance and wait for it to become ready.
    const second = await h.manager.open({ runId: "run-1", bundleDir: h.bundleDir, waitReadyMs: 2000 });
    assert.equal(second.status, "ready", JSON.stringify(second));
    assert.equal(second.pid, first.pid);
    assert.equal(h.invocations().filter((e) => e.event === "start").length, 1);
  });
});

test("viewer manager: after the live viewer exits, a reopen creates a replacement instance", async () => {
  await withHarness("ready", async (h) => {
    const first = await h.manager.open({ runId: "run-1", bundleDir: h.bundleDir });
    assert.equal(first.status, "ready");
    const firstInstance = readViewerState(h.bundleDir)?.instanceId;

    // Confirm the prior viewer exited, then reopen.
    killViewers(h);
    await waitFor(() => (!pidAlive(first.pid!) ? true : undefined), 5000);
    assert.equal(h.manager.describe(h.bundleDir).state, "exited");

    const second = await h.manager.open({ runId: "run-1", bundleDir: h.bundleDir });
    assert.equal(second.status, "ready", JSON.stringify(second));
    assert.notEqual(second.pid, first.pid);
    const secondInstance = readViewerState(h.bundleDir)?.instanceId;
    assert.notEqual(secondInstance, firstInstance);
    assert.equal(h.invocations().filter((e) => e.event === "start").length, 2);
  });
});

test("viewer manager: a viewer that dies before its ready handshake is reported, not waited on forever", async () => {
  await withHarness("crash", async (h) => {
    const started = Date.now();
    const result = await h.manager.open({ runId: "run-1", bundleDir: h.bundleDir });
    assert.equal(result.status, "failed");
    assert.match(result.reason ?? "", /exited before its ready handshake/);
    assert.ok(Date.now() - started < VIEWER_READY_WAIT_MS, "a dead viewer must not consume the whole budget");
  });
});

test("viewer manager: a viewer that never reports ready is bounded by the two-second handshake budget", async () => {
  await withHarness("silent", async (h) => {
    const started = Date.now();
    const result = await h.manager.open({ runId: "run-1", bundleDir: h.bundleDir, waitReadyMs: 400 });
    const elapsed = Date.now() - started;
    assert.equal(result.status, "starting");
    assert.ok(elapsed >= 400 && elapsed < 2000, `elapsed ${elapsed}ms`);
    assert.equal(h.manager.describe(h.bundleDir).state, "starting");
  });
});

// ===== delegate integration =====

test("delegate: the Run Window is opened after the bundle exists and before Pi starts", async () => {
  const c = tmpCwd();
  await withEnv(fakePiEnv("success"), async () => {
    const sessions = new SessionRegistry();
    const runs = new RunRegistry();
    const procs = new ProcessTable();
    const store = new TranscriptStore(join(mkdtempSync(join(tmpdir(), "pi-viewer-tr-")), "runs"));

    let bundleAtOpen: string | undefined;
    let sawAnyRecordAtOpen: string | undefined;
    const launcher = {
      async open(input: { runId: string; bundleDir: string }) {
        bundleAtOpen = input.bundleDir;
        sawAnyRecordAtOpen = readFileSync(join(input.bundleDir, "transcript.jsonl"), "utf8");
        return { status: "ready" as const, pid: 1 };
      },
    };

    const out = await delegate(
      { prompt: "do", session: "s1", cwd: c.dir, goal: "g", mode: "sync" },
      { sessions, runs, procs, transcripts: store, viewer: launcher },
    );
    assert.equal(out.status, "completed", JSON.stringify(out));

    assert.equal(bundleAtOpen, store.dir(out.runId));
    // The launch record is already durable, and Pi has not been spawned yet.
    assert.match(sawAnyRecordAtOpen ?? "", /"kind":"launch"/);
    assert.doesNotMatch(sawAnyRecordAtOpen ?? "", /pi-spawned/);
    const full = readFileSync(join(store.dir(out.runId), "transcript.jsonl"), "utf8");
    assert.match(full, /pi-spawned/);
  });
  c.cleanup();
});

test("delegate: a viewer that throws or fails never affects the Run", async () => {
  const c = tmpCwd();
  await withEnv(fakePiEnv("success"), async () => {
    const sessions = new SessionRegistry();
    const runs = new RunRegistry();
    const procs = new ProcessTable();

    const out = await delegate(
      { prompt: "do", session: "s1", cwd: c.dir, goal: "g", mode: "sync" },
      {
        sessions, runs, procs,
        viewer: { async open() { throw new Error("viewer exploded"); } },
      },
    );
    assert.equal(out.status, "completed", JSON.stringify(out));
    assert.ok(out.result);
  });
  c.cleanup();
});

// ===== status integration =====

test("status: openWindow reopens the window; a failing viewer never breaks status", async () => {
  const runs = new RunRegistry();
  const r = runs.create({ session: "s", startedAt: 1 });
  runs.complete(r.runId, { status: "completed", result: "ok", endedAt: 2 });

  const opened: string[] = [];
  const stub = {
    async open(input: { runId: string }) { opened.push(input.runId); return { status: "focused" as const, pid: 5 }; },
    describe: () => ({ available: true, state: "ready" as const, pid: 5, token: "SUCCEEDED", alertAttemptedAt: 7 }),
  };
  const store = new TranscriptStore(join(mkdtempSync(join(tmpdir(), "pi-viewer-st-")), "runs"));

  const out = await status({ runId: r.runId, openWindow: true }, { runs, transcripts: store, viewer: stub });
  assert.deepEqual(opened, [r.runId]);
  assert.equal(out.status, "completed");
  assert.equal(out.viewer?.state, "ready");
  assert.equal(out.viewer?.alertAttemptedAt, 7);
  assert.equal(out.timing?.startedAt, 1);
  assert.equal(out.timing?.endedAt, 2);
  assert.equal(out.transcript?.available, false);

  // A viewer that throws is isolated.
  const boom = { async open() { throw new Error("no window"); }, describe: () => ({ available: false, state: "unavailable" as const }) };
  const out2 = await status({ runId: r.runId, openWindow: true }, { runs, transcripts: store, viewer: boom });
  assert.equal(out2.status, "completed");

  // Ordinary status reads have no window side effect.
  const out3 = await status({ runId: r.runId }, { runs, transcripts: store, viewer: stub });
  assert.equal(out3.status, "completed");
  assert.deepEqual(opened, [r.runId]);
});

test("status: with no viewer configured the surface is unchanged", async () => {
  const runs = new RunRegistry();
  const r = runs.create({ session: "s", startedAt: 1 });
  runs.complete(r.runId, { status: "completed", result: "ok", endedAt: 2 });
  const out = await status({ runId: r.runId }, { runs });
  assert.equal(out.viewer, undefined);
  assert.equal(out.transcript, undefined);
  assert.equal(out.timing?.startedAt, 1);
});

test("status: terminal timing and the Pi settlement observation come from the transcript tail", async () => {
  const dir = mkdtempSync(join(tmpdir(), "pi-viewer-tail-"));
  const store = new TranscriptStore(join(dir, "runs"));
  const runs = new RunRegistry();
  const r = runs.create({ session: "s", startedAt: 111 });

  const w = TranscriptWriter.create(store.dir(r.runId), { runId: r.runId, session: "s", cwd: "C:/w", promptSubmitted: "p", promptEffective: "p" });
  w.stdoutData(Buffer.from('{"type":"agent_end"}\n', "utf8"));
  w.finalize({
    outcome: "succeeded", exitCode: 0, signal: null, startedAt: 111, endedAt: 222, sawEof: true,
    piSettlement: { agentEnd: true, agentSettled: false, lastStdoutType: "agent_end" },
  });
  runs.complete(r.runId, { status: "completed", result: "ok", endedAt: 222 });

  const out = await status({ runId: r.runId }, { runs, transcripts: store });
  assert.equal(out.transcript?.integrity, "integrity-ok");
  assert.equal(out.transcript?.startedAt, 111);
  assert.equal(out.transcript?.endedAt, 222);
  assert.deepEqual(out.transcript?.piSettlement, { agentEnd: true, agentSettled: false, lastStdoutType: "agent_end" });
});

// ===== focus request seam =====

test("viewer state: a focus request is atomic and replaces any earlier request", () => {
  const dir = mkdtempSync(join(tmpdir(), "pi-viewer-focus-"));
  requestFocus(dir, 1);
  requestFocus(dir, 2);
  const payload = JSON.parse(readFileSync(join(dir, VIEWER_REQUEST_FILE), "utf8"));
  assert.equal(payload.focusAt, 2);
  assert.equal(existsSync(viewerStatePath(dir)), false);
});

async function waitFor<T>(fn: () => T | undefined, timeoutMs: number): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = fn();
    if (value !== undefined) return value;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error("waitFor timed out");
}
