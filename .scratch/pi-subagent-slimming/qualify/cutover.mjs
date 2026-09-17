#!/usr/bin/env node
// Ticket 09 — replace the live Pi subagent service, with a real rollback.
//
//   node cutover.mjs status     # what is configured now vs. what this repo builds
//   node cutover.mjs backup     # snapshot config + state + the installed skill, write a manifest
//   node cutover.mjs apply      # point Codex at this repo's verified build; refresh the skill
//   node cutover.mjs rollback   # restore both byte-exactly from the manifest
//
// `apply` edits exactly one line of ~/.codex/config.toml (the `args` of the
// `[mcp_servers.pi-subagent]` entry) and then re-reads the file to prove nothing
// else moved. It never touches the previously live checkout.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync, cpSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const REPO = "C:\\Users\\qnhxx\\Documents\\AI-Projects\\Code\\pi-subagent";
const SERVER = join(REPO, "dist", "server.js");
const REPO_SKILL = join(REPO, "skills", "pi-subagent");
const CONFIG = join(homedir(), ".codex", "config.toml");
const LIVE_CHECKOUT = "C:\\Users\\qnhxx\\Documents\\Codex\\tools\\pi-subagent";
const STATE_DIR = join(homedir(), ".pi-subagent");
const REGISTRY = join(STATE_DIR, "registry.json");
const INSTALLED_SKILL = join(homedir(), ".skills-manager", "skills", "pi-subagent");
const MANIFEST = join(import.meta.dirname, "_out", "cutover-manifest.json");
const VERIFICATION = join(import.meta.dirname, "_out", "cutover-verification.json");

const sha256 = (p) => createHash("sha256").update(readFileSync(p)).digest("hex");
const line = (s) => process.stdout.write(`${s}\n`);

function readManifest() {
  if (!existsSync(MANIFEST)) throw new Error(`no manifest at ${MANIFEST}; run \`backup\` first`);
  return JSON.parse(readFileSync(MANIFEST, "utf8"));
}

// ---- the config entry (shared with the verifier) ------------------------------

import { parseEntry, rewriteServerPath, serverPath } from "./config-entry.mjs";

// ---- preconditions ---------------------------------------------------------

function activeRuns() {
  const problems = [];
  if (existsSync(REGISTRY)) {
    try {
      const reg = JSON.parse(readFileSync(REGISTRY, "utf8"));
      const running = (reg.sessions ?? []).filter((s) => s.status === "running").map((s) => s.name);
      if (running.length) problems.push(`sessions still marked running: ${running.join(", ")}`);
    } catch (e) {
      problems.push(`registry unreadable: ${e.message}`);
    }
  }
  const ps = execFileSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command",
    "Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | Select-Object -ExpandProperty CommandLine"],
    { encoding: "utf8", timeout: 60_000 });
  const piChildren = ps.split(/\r?\n/).filter((l) => /pi-coding-agent[\\/]dist[\\/]bundle[\\/]cli\.js/.test(l));
  if (piChildren.length) problems.push(`${piChildren.length} live pi process(es): ${piChildren.join(" | ")}`);
  return { problems, piChildren };
}

function liveCheckoutState() {
  const run = (args) => {
    try { return execFileSync("git", ["-C", LIVE_CHECKOUT, ...args], { encoding: "utf8", timeout: 30_000 }).trim(); }
    catch { return "(unavailable)"; }
  };
  return { head: run(["rev-parse", "HEAD"]), status: run(["status", "--porcelain"]) };
}

// ---- commands --------------------------------------------------------------

function cmdStatus() {
  const text = readFileSync(CONFIG, "utf8");
  const configured = serverPath(text);
  const m = existsSync(MANIFEST) ? readManifest() : undefined;
  line(`config:            ${CONFIG}`);
  line(`configured server: ${configured}`);
  line(`this repo's build: ${SERVER} (exists: ${existsSync(SERVER)})`);
  if (existsSync(SERVER)) line(`build sha256:      ${sha256(SERVER)}`);
  line(`installed skill:   ${INSTALLED_SKILL} (version ${skillVersion(INSTALLED_SKILL) ?? "absent"})`);
  line(`repo skill:        ${REPO_SKILL} (version ${skillVersion(REPO_SKILL) ?? "absent"})`);
  line(`manifest:          ${m ? `${MANIFEST} (backed up ${m.createdAt} → ${m.backupDir})` : "(none yet)"}`);
  const { problems, piChildren } = activeRuns();
  line(`live pi processes: ${piChildren.length}`);
  line(`preconditions:     ${problems.length ? `BLOCKED — ${problems.join("; ")}` : "clear (no active Run)"}`);
}

function skillVersion(dir) {
  const p = join(dir, "SKILL.md");
  if (!existsSync(p)) return undefined;
  return /^version:\s*(.+)$/m.exec(readFileSync(p, "utf8"))?.[1]?.trim();
}

function cmdBackup() {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const backupDir = join(STATE_DIR, `cutover-backup-${stamp}`);
  mkdirSync(backupDir, { recursive: true });

  const { problems } = activeRuns();
  if (!existsSync(CONFIG)) throw new Error(`no config to back up at ${CONFIG}`);
  if (!existsSync(SERVER)) throw new Error(`this repo is not built: ${SERVER} missing — run npm run build`);
  if (!existsSync(REPO_SKILL)) throw new Error(`repo skill missing: ${REPO_SKILL}`);
  const configBefore = readFileSync(CONFIG, "utf8");
  const configuredBefore = serverPath(configBefore);

  copyFileSync(CONFIG, join(backupDir, "config.toml"));
  if (existsSync(REGISTRY)) copyFileSync(REGISTRY, join(backupDir, "registry.json"));
  // Legacy tasks.json: recorded if present, deliberately never read or written.
  const tasksPath = join(STATE_DIR, "tasks.json");
  const tasksPresent = existsSync(tasksPath);
  if (tasksPresent) copyFileSync(tasksPath, join(backupDir, "tasks.json"));

  const skillBackup = join(backupDir, "installed-skill");
  let skillFiles = [];
  if (existsSync(INSTALLED_SKILL)) {
    cpSync(INSTALLED_SKILL, skillBackup, { recursive: true });
    skillFiles = walk(INSTALLED_SKILL).map((rel) => ({
      rel, sha256: sha256(join(INSTALLED_SKILL, rel)), bytes: statSync(join(INSTALLED_SKILL, rel)).size,
    }));
  }

  const manifest = {
    createdAt: new Date().toISOString(),
    repo: REPO,
    build: { server: SERVER, sha256: sha256(SERVER), gitHead: execFileSync("git", ["-C", REPO, "rev-parse", "HEAD"], { encoding: "utf8" }).trim() },
    backupDir,
    config: {
      path: CONFIG,
      sha256Before: sha256(CONFIG),
      configuredServerBefore: configuredBefore,
      extraArgsBefore: parseEntry(configBefore).args.slice(1),
      toolTimeoutSecBefore: parseEntry(configBefore).toolTimeoutSec,
      backupPath: join(backupDir, "config.toml"),
      appliedServer: null,
    },
    registry: existsSync(REGISTRY)
      ? { path: REGISTRY, sha256Before: sha256(REGISTRY), backupPath: join(backupDir, "registry.json") }
      : undefined,
    legacyTasks: { path: tasksPath, present: tasksPresent, touched: false },
    skill: {
      path: INSTALLED_SKILL,
      versionBefore: skillVersion(INSTALLED_SKILL),
      backupPath: skillBackup,
      files: skillFiles,
    },
    liveCheckout: { path: LIVE_CHECKOUT, ...liveCheckoutState() },
    preconditions: { problems, clear: problems.length === 0 },
  };
  mkdirSync(dirname(MANIFEST), { recursive: true });
  writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2));

  line(`backup dir:   ${backupDir}`);
  line(`config:       ${CONFIG} (sha256 ${manifest.config.sha256Before.slice(0, 16)}…)`);
  line(`configured:   ${configuredBefore}`);
  line(`state:        ${manifest.registry ? "registry.json copied" : "no registry.json"}`);
  line(`legacy tasks: ${tasksPresent ? "present, copied, never read or written" : "absent"} (untouched)`);
  line(`installed skill backed up: v${manifest.skill.versionBefore ?? "?" } (${skillFiles.length} file(s))`);
  line(`live checkout: ${manifest.liveCheckout.head.slice(0, 12)} with ${manifest.liveCheckout.status ? "local modifications" : "a clean tree"} (not touched)`);
  line(`preconditions: ${manifest.preconditions.clear ? "clear (no active Run)" : `BLOCKED — ${problems.join("; ")}`}`);
  line(`manifest:     ${MANIFEST}`);
}

// Swap the installed skill for the repo's copy. Writes to a sibling first and only
// removes the current one once the replacement is on disk, so a failure here leaves
// the old copy intact rather than deleting it.
function swapSkill(src, dest) {
  if (!existsSync(src)) throw new Error(`skill source missing: ${src}`);
  const staging = `${dest}.staging`;
  rmSync(staging, { recursive: true, force: true });
  cpSync(src, staging, { recursive: true });
  if (!existsSync(join(staging, "SKILL.md"))) throw new Error(`staged skill has no SKILL.md: ${staging}`);
  rmSync(dest, { recursive: true, force: true });
  renameSync(staging, dest);
}

function cmdApply() {
  const m = readManifest();
  const { problems } = activeRuns();
  if (problems.length) throw new Error(`refusing to cut over: ${problems.join("; ")}`);
  if (!existsSync(SERVER)) throw new Error(`this repo is not built: ${SERVER} missing — run npm run build`);

  // The manifest describes a specific starting state. If the config has moved since
  // the backup, applying would silently overwrite somebody else's edit.
  const nowHash = sha256(CONFIG);
  if (m.config.sha256After && nowHash === m.config.sha256After) {
    line("already applied — config matches the recorded post-cutover hash; nothing to do");
    return;
  }
  if (nowHash !== m.config.sha256Before) {
    throw new Error(`config changed since the backup (expected ${m.config.sha256Before.slice(0, 16)}…, found ${nowHash.slice(0, 16)}…); re-run backup`);
  }

  // 1. the installed skill copy (ticket 08 deferred this to the idle cutover). Done
  // first because it is inert: a failure here changes nothing about which server runs.
  swapSkill(REPO_SKILL, INSTALLED_SKILL);

  // 2. the MCP entry: exactly one line, verified by re-reading the file.
  const before = readFileSync(CONFIG, "utf8");
  const after = rewriteServerPath(before, SERVER);
  const changed = diffLines(before, after);
  if (changed.length !== 1) throw new Error(`expected exactly one changed line, got ${changed.length}: ${JSON.stringify(changed)}`);
  writeFileSync(CONFIG, after);
  const reread = readFileSync(CONFIG, "utf8");
  if (serverPath(reread) !== SERVER) throw new Error("config rewrite did not take effect");
  const preservedArgs = parseEntry(reread).args.slice(1);
  if (JSON.stringify(preservedArgs) !== JSON.stringify(m.config.extraArgsBefore ?? [])) {
    throw new Error(`the rewrite changed trailing arguments: ${JSON.stringify(preservedArgs)}`);
  }

  m.appliedAt = new Date().toISOString();
  m.config.appliedServer = SERVER;
  m.config.sha256After = sha256(CONFIG);
  m.skill.versionAfter = skillVersion(INSTALLED_SKILL);
  writeFileSync(MANIFEST, JSON.stringify(m, null, 2));

  line(`applied: config line ${changed[0].line} → ${SERVER}`);
  line(`applied: skill ${INSTALLED_SKILL} v${m.skill.versionBefore ?? "?"} → v${m.skill.versionAfter ?? "?"}`);
  line(`config sha256 now ${m.config.sha256After.slice(0, 16)}… (was ${m.config.sha256Before.slice(0, 16)}…)`);
  line(`live checkout untouched: ${LIVE_CHECKOUT}`);
}

function cmdRollback() {
  const m = readManifest();
  copyFileSync(m.config.backupPath, CONFIG);
  const restored = readFileSync(CONFIG, "utf8");
  if (serverPath(restored) !== m.config.configuredServerBefore) {
    throw new Error("rollback did not restore the original server path");
  }
  if (sha256(CONFIG) !== m.config.sha256Before) throw new Error("rollback was not byte-exact");

  if (m.skill.backupPath && existsSync(m.skill.backupPath)) {
    swapSkill(m.skill.backupPath, INSTALLED_SKILL);
  }
  const drifted = (m.skill.files ?? []).filter((f) => {
    const p = join(INSTALLED_SKILL, f.rel);
    return !existsSync(p) || sha256(p) !== f.sha256;
  });
  if (drifted.length) throw new Error(`skill rollback not byte-exact: ${drifted.map((d) => d.rel).join(", ")}`);

  m.rolledBackAt = new Date().toISOString();
  m.config.appliedServer = null;
  writeFileSync(MANIFEST, JSON.stringify(m, null, 2));

  line(`rolled back: config byte-exact (sha256 ${sha256(CONFIG).slice(0, 16)}… = backup)`);
  line(`rolled back: server path → ${m.config.configuredServerBefore}`);
  line(`rolled back: installed skill → v${skillVersion(INSTALLED_SKILL) ?? "?"} (all ${m.skill.files.length} file(s) byte-exact)`);
  line(`live checkout untouched: ${LIVE_CHECKOUT}`);
}

// ---- helpers ---------------------------------------------------------------

function walk(root, prefix = "") {
  const out = [];
  for (const entry of readdirSync(join(root, prefix), { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) out.push(...walk(root, rel));
    else out.push(rel);
  }
  return out;
}

function diffLines(a, b) {
  const al = a.split("\n"); const bl = b.split("\n");
  const out = [];
  for (let i = 0; i < Math.max(al.length, bl.length); i++) {
    if (al[i] !== bl[i]) out.push({ line: i + 1, before: al[i], after: bl[i] });
  }
  return out;
}

// Post-hoc integrity check: re-read every fact the cutover claims, and write the
// result as evidence rather than leaving it as an assertion in a ticket.
function cmdVerify() {
  const m = readManifest();
  const out = { checkedAt: new Date().toISOString(), checks: [] };
  const ck = (name, ok, detail) => {
    out.checks.push({ name, ok: !!ok, detail });
    line(`${ok ? "  PASS" : "  FAIL"} ${name}${ok || detail === undefined ? "" : ` — ${typeof detail === "string" ? detail : JSON.stringify(detail)}`}`);
  };

  const configured = serverPath(readFileSync(CONFIG, "utf8"));
  ck("the configured entry points at this repository's build", configured === SERVER, configured);
  ck("the config hash matches the recorded post-cutover hash",
    m.config.sha256After ? sha256(CONFIG) === m.config.sha256After : configured === SERVER,
    { now: sha256(CONFIG), recorded: m.config.sha256After ?? null });
  ck("the installed skill is the repository's v3 skill",
    skillVersion(INSTALLED_SKILL) === skillVersion(REPO_SKILL), { installed: skillVersion(INSTALLED_SKILL), repo: skillVersion(REPO_SKILL) });
  ck("the install is not half-cut-over (no staging directory left behind)",
    !existsSync(`${INSTALLED_SKILL}.staging`), `${INSTALLED_SKILL}.staging`);

  if (m.registry) {
    ck("the live registry is byte-identical to the backup taken before the cutover",
      sha256(m.registry.path) === m.registry.sha256Before,
      { now: sha256(m.registry.path), before: m.registry.sha256Before });
  } else {
    ck("no live registry existed at backup time, and none has appeared", !existsSync(REGISTRY), REGISTRY);
  }
  ck("the legacy tasks.json was not created or written",
    existsSync(join(STATE_DIR, "tasks.json")) === !!m.legacyTasks?.present,
    { present: existsSync(join(STATE_DIR, "tasks.json")), atBackup: !!m.legacyTasks?.present });

  const live = liveCheckoutState();
  ck("the previously live checkout was never touched",
    live.head === m.liveCheckout.head && live.status === m.liveCheckout.status,
    { headBefore: m.liveCheckout.head, headNow: live.head, statusMatches: live.status === m.liveCheckout.status });

  const built = sha256(SERVER);
  ck("the build being run is the build that was recorded at backup time",
    built === m.build.sha256, { now: built, recorded: m.build.sha256 });

  out.ok = out.checks.every((c) => c.ok);
  mkdirSync(dirname(VERIFICATION), { recursive: true });
  writeFileSync(VERIFICATION, JSON.stringify({ ...out, manifest: MANIFEST }, null, 2));
  line(`${out.ok ? "OK  " : "FAIL"} cutover verification — ${VERIFICATION}`);
  if (!out.ok) process.exitCode = 1;
}

const cmd = process.argv[2];
const commands = { status: cmdStatus, backup: cmdBackup, apply: cmdApply, rollback: cmdRollback, verify: cmdVerify };
if (!commands[cmd]) {
  line(`usage: node cutover.mjs <${Object.keys(commands).join("|")}>`);
  process.exit(2);
}
try {
  commands[cmd]();
} catch (e) {
  line(`ERROR: ${e.message}`);
  process.exit(1);
}
