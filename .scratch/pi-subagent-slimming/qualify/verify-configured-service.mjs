#!/usr/bin/env node
// Verification of the *configured* live service (ticket 09).
//
// Unlike every other scenario, this one does not decide for itself what to launch:
// it reads `~/.codex/config.toml`, extracts the `[mcp_servers.pi-subagent]` entry
// verbatim (command, args, env), spawns exactly that, and checks that the two-tool
// surface answers and that one real Run completes through it. That is what makes it
// a cutover check rather than an assumption.
//
//   node verify-configured-service.mjs [path/to/config.toml]
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { readEntry } from "./config-entry.mjs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const CONFIG = process.argv[2] ?? join(homedir(), ".codex", "config.toml");
const OUT = join(HERE, "_out", "verify-configured-service.json");

const cfg = readEntry(CONFIG);
const results = { configPath: CONFIG, entry: cfg, checks: [] };
const check = (name, ok, detail) => {
  results.checks.push({ name, ok: !!ok, detail });
  process.stdout.write(`${ok ? "  PASS" : "  FAIL"} ${name}${ok || detail === undefined ? "" : ` — ${typeof detail === "string" ? detail : JSON.stringify(detail)}`}\n`);
};

const serverPath = cfg.args?.[0];
check("the configured pi-subagent entry names a server script", typeof serverPath === "string" && serverPath.length > 0, cfg);
check("the configured server script exists on disk", !!serverPath && existsSync(serverPath), { serverPath });
check("the configured PI_BIN is set", typeof cfg.env.PI_BIN === "string" && cfg.env.PI_BIN.length > 0, cfg.env.PI_BIN);
check("the host tool timeout can hold a 240 s sync Run",
  Number.isFinite(cfg.toolTimeoutSec) && cfg.toolTimeoutSec * 1000 > 240_000, cfg.toolTimeoutSec);

const stateDir = join(tempStateRoot(), new Date().toISOString().replace(/[:.]/g, "-"));
mkdirSync(stateDir, { recursive: true });
// Every state path is redirected into a temp dir so verifying the configured service
// never appends to the live registry, transcripts, or the legacy tasks.json — which
// the retired build would otherwise create.
const env = {
  ...process.env,
  ...cfg.env,
  PI_SUBAGENT_REGISTRY: join(stateDir, "registry.json"),
  PI_SUBAGENT_TRANSCRIPTS: join(stateDir, "runs"),
  PI_SUBAGENT_TASKS: join(stateDir, "tasks.json"),
};

const transport = new StdioClientTransport({
  command: cfg.command,
  args: cfg.args,
  env,
  cwd: dirname(serverPath ?? "."),
  stderr: "pipe",
});
const client = new Client({ name: "verify-configured-service", version: "1.0.0" }, { capabilities: {} });
const stderr = [];
try {
  await client.connect(transport);
  transport.stderr?.on("data", (b) => stderr.push(b.toString("utf8")));
  results.serverVersion = await client.getServerVersion();

  const tools = await client.listTools();
  const names = tools.tools.map((t) => t.name).sort();
  check("the configured service exposes exactly pi_delegate and pi_status",
    JSON.stringify(names) === JSON.stringify(["pi_delegate", "pi_status"]), names);

  const cwd = join(stateDir, "cwd");
  mkdirSync(cwd, { recursive: true });
  const t0 = Date.now();
  const res = await client.callTool({
    name: "pi_delegate",
    arguments: {
      prompt: "Use the bash tool to run exactly: echo CUTOVER_OK. Then reply with exactly: CUTOVER_REPLY_OK",
      session: "verify-cutover", cwd,
      goal: "cutover verification: a real Run through the configured service",
      constraints: { noSkills: true }, mode: "sync", runTimeoutMs: 240_000,
    },
  }, undefined, { timeout: 300_000 });
  const elapsedMs = Date.now() - t0;
  const payload = JSON.parse((res.content ?? []).find((c) => c.type === "text")?.text ?? "{}");
  results.run = { runId: payload.runId, status: payload.status, elapsedMs, error: payload.error };
  check("a real Run completes through the configured service",
    payload.status === "completed" && /CUTOVER_REPLY_OK/.test(payload.result ?? ""), results.run);

  const bundle = join(stateDir, "runs", payload.runId ?? "none");
  const manifest = existsSync(join(bundle, "manifest.json"))
    ? JSON.parse(readFileSync(join(bundle, "manifest.json"), "utf8")) : undefined;
  results.transcript = manifest?.terminal;
  check("its Transcript is complete and verified",
    manifest?.terminal?.outcome === "succeeded" && !manifest?.terminal?.captureError, manifest?.terminal);

  const vs = existsSync(join(bundle, "viewer-state.json"))
    ? JSON.parse(readFileSync(join(bundle, "viewer-state.json"), "utf8")) : undefined;
  results.viewerState = vs;
  check("its Run Window opened", vs?.state === "ready", vs);
  results.stateDir = stateDir;
  results.stderr = stderr.join("");
  check("the configured service printed no unhandled failure", !/uncaught|unhandled/i.test(results.stderr), results.stderr);
} catch (e) {
  check("the configured service starts and answers", false, String(e?.message ?? e));
} finally {
  await client.close();
}

results.ok = results.checks.every((c) => c.ok) && results.checks.length > 0;
mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, JSON.stringify(results, null, 2));
process.stdout.write(`${results.ok ? "OK  " : "FAIL"} configured service — ${OUT}\n`);
process.exit(results.ok ? 0 : 1);

function tempStateRoot() {
  return join(process.env.TEMP ?? "/tmp", "pi-subagent-cutover-verify");
}
