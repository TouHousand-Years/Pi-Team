import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import type { ChildProcess } from "node:child_process";
import { join } from "node:path";
import { writeFileSync } from "node:fs";
import { SessionRegistry } from "../src/registry/session.js";
import { RunRegistry } from "../src/registry/run.js";
import { ProcessTable } from "../src/runner/process-table.js";
import { delegate } from "../src/tools/delegate.js";
import { status } from "../src/tools/status.js";
import { collectOutput } from "../src/runner/spawn.js";
import { TranscriptStore } from "../src/transcript/store.js";
import { readTerminalTail } from "../src/transcript/reader.js";
import { fakePiEnv, tmpCwd, withEnv } from "./helpers.js";

for (const existing of [false, true]) {
  for (const mode of ["sync", "async"] as const) {
    test(`${mode}: ${existing ? "continued" : "new"} session is reserved before viewer readiness`, async () => {
      const tmp = tmpCwd();
      try {
        await withEnv(fakePiEnv(), async () => {
          const sessions = new SessionRegistry();
          const runs = new RunRegistry();
          const procs = new ProcessTable();
          const transcripts = new TranscriptStore(join(tmp.dir, "runs"));
          if (existing) sessions.create({ name: "same", piSessionId: "existing-id", cwd: tmp.dir, goal: "test" });
          let release!: () => void;
          const gate = new Promise<void>(r => { release = r; });
          const deps = { sessions, runs, procs, transcripts, viewer: {
            async open() { await gate; return { status: "ready" as const }; },
          } };
          const input = { session: "same", prompt: "test", goal: "test", cwd: tmp.dir, mode };
          const first = delegate(input, deps);
          try {
            await assert.rejects(() => delegate(input, deps), (e: any) => e.code === "session_busy");
            assert.equal(runs.runningCount(), 1);
            if (existing) {
              assert.equal(sessions.get("same")?.status, "running");
              assert.equal(sessions.get("same")?.msgCount, 1);
            }
          } finally { release(); }
          const result = await first;
          const completed = await runs.waitForCompletion(result.runId, 5000);
          assert.equal(completed?.status, "completed");
          assert.equal(sessions.get("same")?.status, "idle");
          assert.equal(sessions.get("same")?.msgCount, 1);
          const next = await delegate({ ...input, mode: "sync" }, deps);
          assert.equal(next.status, "completed");
          assert.equal(sessions.get("same")?.msgCount, 2);
        });
      } finally { tmp.cleanup(); }
    });
  }
}

test("continued session reservation is released after spawn failure", async () => {
  const tmp = tmpCwd();
  try {
    const deps = { sessions: new SessionRegistry(), runs: new RunRegistry(), procs: new ProcessTable() };
    deps.sessions.create({ name: "same", piSessionId: "existing-id", cwd: tmp.dir, goal: "test" });
    await withEnv({ PI_BIN: "nonexistent-pi-audit-regression" }, async () => {
      const failed = await delegate({ session: "same", prompt: "test", mode: "sync" }, deps);
      assert.equal(failed.status, "error");
      assert.equal(deps.sessions.get("same")?.status, "error");
      assert.equal(deps.runs.runningCount(), 0);
    });
    await withEnv(fakePiEnv(), async () => {
      const next = await delegate({ session: "same", prompt: "retry", mode: "sync" }, deps);
      assert.equal(next.status, "completed");
    });
  } finally { tmp.cleanup(); }
});

for (const unfinished of ["stdout", "stderr"] as const) {
  test(`forced pipe closure does not claim EOF when ${unfinished} is still open`, async () => {
    const child = Object.assign(new EventEmitter(), { stdout: new PassThrough(), stderr: new PassThrough() });
    const collected = collectOutput(child as unknown as ChildProcess);
    child.stdout.write("preserved\n");
    child[unfinished === "stdout" ? "stderr" : "stdout"].end();
    child.emit("exit", 0, null);
    const result = await collected;
    assert.equal(result.sawEof, false);
    assert.deepEqual(result.lines, ["preserved"]);
  });
}

test("unclean capture downgrades the persisted Transcript and status", async () => {
  const tmp = tmpCwd();
  try {
    await withEnv(fakePiEnv(), async () => {
      class BrokenPipeProcesses extends ProcessTable {
        override register(id: string, child: ChildProcess, onExit: () => void) {
          super.register(id, child, onExit);
          // Inject a pipe failure after collectOutput has attached its listeners.
          child.stdout?.once("data", () => child.stdout?.emit("error", new Error("broken pipe")));
        }
      }
      const deps = { sessions: new SessionRegistry(), runs: new RunRegistry(), procs: new BrokenPipeProcesses(),
        transcripts: new TranscriptStore(join(tmp.dir, "runs")) };
      const result = await delegate({ session: "pipe", goal: "test", cwd: tmp.dir, prompt: "test", mode: "sync" }, deps);
      assert.equal(result.status, "completed");
      const terminal = readTerminalTail(deps.transcripts.dir(result.runId));
      assert.equal(terminal?.sawEof, false);
      assert.match(terminal?.captureError ?? "", /EOF/);
      const out = await status({ runId: result.runId }, deps);
      assert.equal(out.transcript?.integrity, "capture-error");
    });
  } finally { tmp.cleanup(); }
});

for (const waitTimeoutMs of [0, 10]) {
  test(`running status reports unavailable capture with waitTimeoutMs=${waitTimeoutMs}`, async () => {
    const tmp = tmpCwd();
    try {
      const path = join(tmp.dir, "not-a-directory");
      writeFileSync(path, "occupied");
      const transcripts = new TranscriptStore(path);
      const runs = new RunRegistry();
      const run = runs.create({ session: "test", startedAt: Date.now() });
      const out = await status({ runId: run.runId, waitTimeoutMs }, { runs, transcripts });
      assert.equal(out.status, "running");
      assert.equal(out.transcript?.available, false);
      assert.equal(out.transcript?.integrity, "unknown");
      assert.match(out.transcript?.reason ?? "", /unusable/);
    } finally { tmp.cleanup(); }
  });
}
