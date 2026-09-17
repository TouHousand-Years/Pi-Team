// Ticket 09 qualification helpers.
//
// Everything here drives the *real* shipped artifacts: the compiled MCP server
// (dist/server.js) over a real stdio client, the real Pi 0.85.1 CLI, and the
// real PowerShell Run Window. Nothing is mocked; the only fakes are the ones the
// test suite already owns.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO = resolve(HERE, "..", "..", "..");
export const SERVER = join(REPO, "dist", "server.js");
export const VIEWER = join(REPO, "viewer", "run-window.ps1");
export const OUT_DIR = join(HERE, "_out");

// The live Codex configuration's PI_BIN, verbatim (see ~/.codex/config.toml).
export const PI_NODE = process.env.QUALIFY_PI_NODE
  ?? "C:\\Users\\qnhxx\\.cache\\codex-runtimes\\codex-primary-runtime\\dependencies\\node\\bin\\node.exe";
export const PI_CLI = process.env.QUALIFY_PI_CLI
  ?? "C:\\Users\\qnhxx\\AppData\\Roaming\\npm\\node_modules\\@earendil-works\\pi-coding-agent\\dist\\bundle\\cli.js";
export const PI_BIN = `${PI_NODE} ${PI_CLI}`;

export const LIVE_REGISTRY = "C:\\Users\\qnhxx\\.pi-subagent\\registry.json";
export const POWERSHELL = process.env.PI_SUBAGENT_POWERSHELL ?? "powershell.exe";

// Scratch state lives outside the repo: transcripts are large and are evidence,
// not source. The report records the path so a human can re-inspect it.
export const RUN_ROOT = join(
  process.env.QUALIFY_ROOT ?? join(tmpdir(), "pi-subagent-qualify"),
  new Date().toISOString().replace(/[:.]/g, "-"),
);

export function scratch(label) {
  const dir = join(RUN_ROOT, label);
  mkdirSync(dir, { recursive: true });
  return dir;
}

export function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

export function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

// ===== report =====

export function newReport(scenario, extra = {}) {
  return {
    scenario,
    startedAt: new Date().toISOString(),
    env: {
      repo: REPO,
      server: SERVER,
      serverSha256: existsSync(SERVER) ? sha256(readFileSync(SERVER)) : null,
      piBin: PI_BIN,
      platform: process.platform,
      node: process.version,
    },
    checks: [],
    ...extra,
  };
}

export function check(report, name, ok, detail) {
  report.checks.push({ name, ok: !!ok, detail });
  process.stdout.write(`${ok ? "  PASS" : "  FAIL"} ${name}${ok || detail === undefined ? "" : ` — ${typeof detail === "string" ? detail : JSON.stringify(detail)}`}\n`);
  return !!ok;
}

export function finish(report) {
  report.endedAt = new Date().toISOString();
  report.failed = report.checks.filter((c) => !c.ok).map((c) => c.name);
  report.ok = report.failed.length === 0;
  mkdirSync(OUT_DIR, { recursive: true });
  const path = join(OUT_DIR, `${report.scenario}.json`);
  writeFileSync(path, JSON.stringify(report, null, 2));
  process.stdout.write(
    `${report.ok ? "OK  " : "FAIL"} ${report.scenario}: ${report.checks.length - report.failed.length}/${report.checks.length} checks — ${path}\n`,
  );
  return report.ok ? 0 : 1;
}

// ===== server under test =====

export async function startServer({ registry, transcripts, viewer = true, session = "qualify" }) {
  const env = {
    ...process.env,
    PI_BIN,
    PI_SUBAGENT_REGISTRY: registry,
    PI_SUBAGENT_TRANSCRIPTS: transcripts,
  };
  if (!viewer) env.PI_SUBAGENT_VIEWER = "off";
  else delete env.PI_SUBAGENT_VIEWER;
  delete env.PI_SUBAGENT_VIEWER_SCRIPT;

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [SERVER],
    cwd: REPO,
    env,
    stderr: "pipe",
  });
  const client = new Client({ name: `pi-subagent-${session}`, version: "1.0.0" }, { capabilities: {} });
  await client.connect(transport);
  const stderr = [];
  transport.stderr?.on("data", (b) => stderr.push(b.toString("utf8")));
  return { client, transport, stderr, env };
}

// callTool with an explicit per-request timeout: the SDK's default is 60s, and
// this qualification deliberately exercises longer waits.
export async function call(client, name, args, timeoutMs = 300_000) {
  const t0 = Date.now();
  let res;
  try {
    res = await client.callTool({ name, arguments: args }, undefined, { timeout: timeoutMs });
  } catch (e) {
    return { name, args, elapsedMs: Date.now() - t0, transportError: String(e?.message ?? e) };
  }
  const elapsedMs = Date.now() - t0;
  const text = (res.content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("");
  let json;
  try { json = JSON.parse(text); } catch { /* non-JSON payload stays visible as text */ }
  return { name, args, elapsedMs, isError: !!res.isError, text, json };
}

// ===== artifacts =====

export function bundleDir(transcripts, runId) {
  return join(transcripts, runId);
}

export function readManifest(dir) {
  return readJson(join(dir, "manifest.json"));
}

export function readViewerState(dir) {
  const p = join(dir, "viewer-state.json");
  return existsSync(p) ? readJson(p) : undefined;
}

// The launch record proves which Pi session id the server actually handed to Pi
// (this is how legacy-registry continuity is observed without waiting on Pi).
export function launchRecord(dir) {
  const path = join(dir, "transcript.jsonl");
  if (!existsSync(path)) return undefined;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line) continue;
    try {
      const rec = JSON.parse(line);
      if (rec.kind === "launch") return rec.launch;
    } catch { /* malformed lines are the viewer's problem, not ours */ }
  }
  return undefined;
}

export function terminalRecord(dir) {
  const path = join(dir, "transcript.jsonl");
  if (!existsSync(path)) return undefined;
  let terminal;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line) continue;
    try {
      const rec = JSON.parse(line);
      if (rec.kind === "terminal") terminal = rec.terminal;
    } catch { /* ditto */ }
  }
  return terminal;
}

// Headless replay through the shipped viewer: the same integrity/hash verdict the
// window itself computes, minus the GUI.
export function replay(bundleDirPath, { timeoutMs = 4000 } = {}) {
  const out = join(bundleDirPath, "rendered.txt");
  const res = spawnSync(
    POWERSHELL,
    ["-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass", "-File", VIEWER,
      "-Replay", "-BundleDir", bundleDirPath, "-OutPath", out, "-ReplayTimeoutMs", String(timeoutMs)],
    { encoding: "utf8", timeout: 180_000 },
  );
  const lines = (res.stdout ?? "").split("\n").map((l) => l.trim()).filter(Boolean);
  const jsonLine = lines.at(-1);
  let report;
  if (jsonLine?.startsWith("{")) report = JSON.parse(jsonLine);
  return {
    status: res.status,
    report,
    text: existsSync(out) ? readFileSync(out, "utf8") : "",
    stderr: res.stderr,
  };
}

// Every top-level window PowerShell knows about, so "one window per Run" can be
// checked against reality rather than against our own bookkeeping.
export function windowTitles() {
  const res = spawnSync(POWERSHELL, [
    "-NoProfile", "-NonInteractive", "-Command",
    "Get-Process | Where-Object { $_.MainWindowTitle } | Select-Object Id,ProcessName,MainWindowTitle | ConvertTo-Json -Compress",
  ], { encoding: "utf8", timeout: 60_000 });
  const text = (res.stdout ?? "").trim();
  if (!text) return [];
  const parsed = JSON.parse(text);
  return (Array.isArray(parsed) ? parsed : [parsed]).map((p) => ({
    pid: p.Id, process: p.ProcessName, title: p.MainWindowTitle,
  }));
}

export function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    // ESRCH is the only signal that means "no such process". EPERM means it exists
    // but is not ours, which is very much alive.
    return e?.code !== "ESRCH";
  }
}

export function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

export function listDirs(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
}

export async function waitFor(fn, { timeoutMs = 30_000, intervalMs = 500, what = "condition" } = {}) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = fn();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out after ${timeoutMs}ms waiting for ${what}`);
    await sleep(intervalMs);
  }
}

// Launch the production window exactly the way ViewerManager does (same argv,
// same STA mode, no shell interpolation), for cases where the Run under test is
// not addressable through pi_status.
export async function launchWindow(bundleDir, { waitMs = 20_000 } = {}) {
  const child = spawn(POWERSHELL, [
    "-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass",
    "-File", VIEWER, "-BundleDir", bundleDir,
  ], { stdio: "ignore", windowsHide: true });
  child.unref?.();
  await waitFor(() => {
    const st = readViewerState(bundleDir);
    return st?.state === "ready" ? st : undefined;
  }, { timeoutMs: waitMs, what: "viewer ready handshake" });
  return readViewerState(bundleDir);
}

export function killWindow(pid) {
  spawnSync(POWERSHELL, ["-NoProfile", "-NonInteractive", "-Command", `Stop-Process -Id ${pid} -Force -ErrorAction SilentlyContinue`],
    { encoding: "utf8", timeout: 30_000 });
}
