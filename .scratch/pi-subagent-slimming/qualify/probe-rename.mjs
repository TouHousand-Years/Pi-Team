#!/usr/bin/env node
// Diagnostic for the retention-while-open race (ticket 09): while a completed
// Run's window is still open, can retention's atomic rename move the bundle?
import { spawnSync } from "node:child_process";
import { closeSync, existsSync, mkdirSync, openSync, readdirSync, renameSync, statSync } from "node:fs";
import { join } from "node:path";
import {
  bundleDir, call, pidAlive, readViewerState, scratch, sleep, startServer,
} from "./lib.mjs";

const dir = scratch("probe-rename");
const registry = join(dir, "registry.json");
const transcripts = join(dir, "runs");
const cwd = scratch("probe-rename-cwd");

const { client } = await startServer({ registry, transcripts, viewer: true });
const r = await call(client, "pi_delegate", {
  prompt: "Use the bash tool to run exactly: echo PROBE_OK. Then reply with exactly: PROBE_REPLY_OK",
  session: "qualify-probe", cwd,
  goal: "qualification: why the bundle rename fails while the window is open",
  constraints: { noSkills: true }, mode: "sync", runTimeoutMs: 240_000,
}, 300_000);
const runId = r.json.runId;
const bundle = bundleDir(transcripts, runId);
mkdirSync(join(transcripts, ".trash"), { recursive: true });
const st = readViewerState(bundle);
console.log("runId", runId, "status", r.json.status, "viewer", JSON.stringify(st));

function exclusiveTest(path) {
  try {
    const fd = openSync(path, "r+");
    closeSync(fd);
    return "free";
  } catch (e) {
    return `${e.code}: ${e.message}`;
  }
}

function renameAttempt(label) {
  const trash = join(transcripts, ".trash");
  try {
    renameSync(bundle, join(trash, `${runId}.${Date.now()}`));
    console.log(`${label}: RENAME OK`);
    return { ok: true };
  } catch (e) {
    console.log(`${label}: RENAME FAILED ${e.code} ${e.message}`);
    return { ok: false, code: e.code, message: e.message };
  }
}

// 1. What does the bundle look like, and who is holding what?
console.log("bundle entries:", readdirSync(bundle).map((n) => {
  const p = join(bundle, n);
  const s = statSync(p);
  return `${n}(${s.isDirectory() ? "dir" : `${s.size}B`})`;
}).join(", "));
for (const name of readdirSync(bundle)) {
  const p = join(bundle, name);
  if (!statSync(p).isFile()) continue;
  console.log(`  exclusive r+ ${name}: ${exclusiveTest(p)}`);
}
console.log("  exclusive r+ bundle dir handle: ", (() => {
  try { const fd = openSync(bundle, "r"); closeSync(fd); return "free"; } catch (e) { return `${e.code}: ${e.message}`; }
})());

// 2. Retry the rename for a while, with the window alive.
const attempts = [];
for (let i = 0; i < 12; i++) {
  const res = renameAttempt(`window-alive attempt ${i + 1} (pid alive=${pidAlive(st.pid)})`);
  attempts.push(res);
  if (res.ok) break;
  await sleep(1000);
}

// 3. Kill the window, then try again — this isolates the window as the cause.
if (!attempts.at(-1)?.ok) {
  spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", `Stop-Process -Id ${st.pid} -Force -ErrorAction SilentlyContinue`], { timeout: 30_000 });
  await sleep(1500);
  console.log("viewer pid alive after kill:", pidAlive(st.pid));
  renameAttempt("after the window is gone");
}

console.log(JSON.stringify({ runId, viewerState: st, attempts, bundleStillThere: existsSync(bundle) }, null, 2));
await client.close();
