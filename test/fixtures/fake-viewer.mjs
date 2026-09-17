// Stand-in Run Window used by test/viewer.test.ts. The manager invokes a
// non-.ps1 viewer script directly (no PowerShell flags), so this script receives
// exactly ["-BundleDir", <dir>]. It mimics the real viewer's seam behaviour:
// write viewer-state.json (starting -> ready), then stay alive until killed,
// consuming viewer-request.json focus requests.
import { readFileSync, writeFileSync, existsSync, unlinkSync, appendFileSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

const argv = process.argv.slice(2);
const bundleIndex = argv.indexOf("-BundleDir");
if (bundleIndex < 0 || !argv[bundleIndex + 1]) {
  process.stderr.write("fake-viewer: -BundleDir is required\n");
  process.exit(2);
}
const bundleDir = argv[bundleIndex + 1];
const mode = process.env.FAKE_VIEWER_MODE ?? "ready";
const log = process.env.FAKE_VIEWER_LOG;

function record(entry) {
  if (!log) return;
  appendFileSync(log, JSON.stringify(entry) + "\n");
}

function writeState(state, extra = {}) {
  writeFileSync(
    join(bundleDir, "viewer-state.json"),
    JSON.stringify({
      runId: join(bundleDir).split(/[\\/]/).pop(),
      instanceId: process.env.FAKE_VIEWER_INSTANCE ?? instanceId,
      pid: process.pid,
      startedAt: Date.now(),
      updatedAt: Date.now(),
      state,
      token: "RUNNING",
      ...extra,
    }),
  );
}

const instanceId = randomUUID();
record({ event: "start", pid: process.pid, instanceId, bundleDir, mode });

// "crash": die before the ready handshake, leaving no state behind.
if (mode === "crash") process.exit(1);

// "silent": accept the launch, report only the early "starting" state the real
// viewer also writes, and never reach ready.
if (mode === "silent") {
  writeState("starting");
  setInterval(() => {}, 1000);
} else if (mode === "slow") {
  // Report "starting" first and become ready shortly afterwards: a second open()
  // inside that window must wait for THIS instance, never spawn a duplicate.
  writeState("starting");
  setTimeout(() => writeState("ready", { token: "RUNNING" }), 400);
  setInterval(() => {}, 1000);
} else if (mode === "failed") {
  writeState("failed", { lastError: "simulated viewer failure" });
} else {
  writeState("starting");
  writeState("ready", { token: "SUCCEEDED", outcome: "succeeded", alertAttemptedAt: null, captureIncomplete: false });
  setInterval(() => {
    const request = join(bundleDir, "viewer-request.json");
    if (existsSync(request)) {
      let payload = "";
      try {
        payload = readFileSync(request, "utf8");
        unlinkSync(request);
      } catch { /* consumed by someone else */ }
      record({ event: "focus", pid: process.pid, instanceId, payload });
      // The real viewer also refreshes its state when it raises the window.
      writeState("ready", { token: "SUCCEEDED", outcome: "succeeded", alertAttemptedAt: null });
    }
  }, 20);
}
