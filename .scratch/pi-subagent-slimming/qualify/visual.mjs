#!/usr/bin/env node
// Ticket 09 — human visual acceptance of the production Run Window.
//
// This is the one gate the machine cannot close: glyph appearance, formatted-only
// display, complete titles, mid-stream continuity and terminal status colours have
// to be looked at. This script therefore *leaves real windows on screen* and stays
// alive so they survive, then writes a checklist naming exactly what to look at.
//
//   node visual.mjs            # hold for 45 minutes
//   node visual.mjs 90         # hold for 90 minutes
//
// Stop early with the command printed in _out/visual-acceptance.md.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  OUT_DIR, REPO, RUN_ROOT, bundleDir, call, pidAlive, readViewerState, replay,
  scratch, sleep, startServer, windowTitles,
} from "./lib.mjs";

const HOLD_MINUTES = Number(process.argv[2] ?? 45);
const dir = scratch("visual");
const registry = join(dir, "registry.json");
const transcripts = join(dir, "runs");
const cwd = scratch("visual-cwd");
const visualOut = join(OUT_DIR, "visual");
mkdirSync(visualOut, { recursive: true });

const GLYPH_LINE = "GLYPHS 中文测试 — 日本語テスト — emoji 🎯🚀 — math ∑∆π≈1.414 — box ┌─┐└─┘ — accents éüñ";
const RUNNING_GOAL = 10;
const RUNNING_STEP_SECONDS = 50;

const { client } = await startServer({ registry, transcripts, viewer: true, session: "visual" });
const windows = [];

function noteWindow(runId, label) {
  const bundle = bundleDir(transcripts, runId);
  const st = readViewerState(bundle);
  windows.push({ label, runId, bundle, viewerState: st });
  return st;
}

// --- 1. a successful Run with content that exercises glyph coverage -----------
const ok = await call(client, "pi_delegate", {
  prompt: `First use the bash tool once to run exactly: echo GLYPH_CHECK. Then reply with exactly this line, `
    + `copied character for character and nothing else:\n${GLYPH_LINE}`,
  session: "visual-success", cwd,
  goal: "human visual acceptance: successful Run with multibyte content",
  constraints: { noSkills: true }, mode: "sync", runTimeoutMs: 240_000,
}, 300_000);
console.log("success run:", ok.json?.status, ok.elapsedMs, "ms");
noteWindow(ok.json.runId, "SUCCEEDED — multibyte glyph coverage, thinking/tool/answer/usage");

// --- 2. a long Run so a RUNNING window is on screen while the human looks -----
const steps = Array.from({ length: RUNNING_GOAL }, (_, i) =>
  `(${i + 1}) powershell -NoProfile -Command "Start-Sleep -Seconds ${RUNNING_STEP_SECONDS}; Write-Output STEP_${i + 1}"`).join(", ");
const running = await call(client, "pi_delegate", {
  prompt: `Use the bash tool to run these ${RUNNING_GOAL} commands one at a time, each in its own separate tool call, `
    + `waiting for each to finish before starting the next: ${steps}. `
    + `After the last one, reply with exactly: LONG_RUN_DONE`,
  session: "visual-running", cwd,
  goal: "human visual acceptance: a live RUNNING window with a long event stream",
  constraints: { noSkills: true }, mode: "async",
}, 60_000);
console.log("running run:", running.json?.status, running.json?.runId);
noteWindow(running.json.runId, "RUNNING — live tailing, fragment suppression, mid-stream continuity");

// --- 3. a failed Run so every terminal colour/word is on screen ---------------
const bad = await call(client, "pi_delegate", {
  prompt: "Use the bash tool to run exactly: powershell -NoProfile -Command \"Start-Sleep -Seconds 120; Write-Output LATE\". Then reply with exactly: NEVER",
  session: "visual-incomplete", cwd,
  goal: "human visual acceptance: an incomplete Run's terminal presentation",
  constraints: { noSkills: true }, mode: "sync", runTimeoutMs: 12_000,
}, 180_000);
console.log("incomplete run:", bad.json?.status, bad.json?.error?.code);
noteWindow(bad.json.runId, "INCOMPLETE — terminal status colour and warning presentation");

// Every fact a human can check against the screen, dumped next to it.
for (const w of windows) {
  const rep = replay(w.bundle);
  writeFileSync(join(visualOut, `${w.label.split(" ")[0]}.txt`), rep.text ?? "");
  w.renderedTextPath = join(visualOut, `${w.label.split(" ")[0]}.txt`);
  w.replay = { token: rep.report?.token, integrityOk: rep.report?.integrityOk, reasons: rep.report?.integrityReasons, records: rep.report?.records };
  w.hash = { expected: rep.report?.hashExpected, computed: rep.report?.hashComputed };
}

const titles = windowTitles();
const mine = titles.filter((t) => windows.some((w) => t.title.includes(w.runId)));
const stopCommand = `powershell -NoProfile -Command "Stop-Process -Id ${process.pid} -Force"`;

const lines = [
  "# Ticket 09 — human visual acceptance of the production Run Window",
  "",
  `Generated ${new Date().toISOString()} by \`qualify/visual.mjs\`.`,
  "",
  "Three real Run Windows are open on this desktop, each produced by the real",
  "`pi_delegate` → `src/viewer/manager.ts` → `viewer/run-window.ps1` path with the real",
  "Pi 0.85.1 CLI. They stay open until closed by hand; the MCP server backing them is",
  `held alive for ${HOLD_MINUTES} minutes.`,
  "",
  "## Windows on screen",
  "",
  "| Window | Run id | Transcript | Verdict the window should show |",
  "| --- | --- | --- | --- |",
  ...windows.map((w) => `| ${w.label} | \`${w.runId}\` | \`${w.bundle}\` | ${w.replay.token} (integrity ${w.replay.integrityOk}) |`),
  "",
  "`integrityOk: false` with reason `no-terminal-record` on the **RUNNING** window is",
  "the expected verdict for a Run that has not finished — it must not invent completion.",
  "",
  "## What to check (the part no script can decide)",
  "",
  "1. **Glyphs** — in the SUCCEEDED window look for the prompt line and Pi's answer:",
  `   \`${GLYPH_LINE}\``,
  "   CJK, emoji, math symbols, box drawing and accents must all be readable — no",
  "   boxes, no mojibake, no U+FFFD replacement characters.",
  "2. **Complete titles** — each title bar shows `[TOKEN] Pi — <session> — <prompt> — <run id>`",
  "   with the full Run id, not a truncation.",
  "3. **Formatted-only, no duplication** — the SUCCEEDED and RUNNING windows must show each",
  "   payload exactly once: prompt, launch metadata, lifecycle lines, thinking, tool call,",
  "   tool result, the answer, usage. There must be no raw-JSON second copy and no",
  "   `message_update` fragment spam while the Run is healthy.",
  "4. **Mid-stream** — in the RUNNING window, confirm the stream keeps advancing and that",
  "   nothing already-rendered is re-rendered as new bytes arrive.",
  "5. **Terminal presentation** — SUCCEEDED and INCOMPLETE must be visually distinct",
  "   (status colour and word), and the INCOMPLETE window must say why rather than claim",
  "   success.",
  "6. **Read-only** — scrolling, selection, copy and the wrap toggle work; nothing can send",
  "   input, retry or cancel.",
  "",
  "## Machine-checked facts to compare against (same bundles)",
  "",
  "```json",
  JSON.stringify(windows.map(({ label, runId, replay: rv, hash: h }) => ({ label, runId, ...rv, ...h })), null, 2),
  "```",
  "",
  "Rendered transcript text for each bundle (what the window should be showing, byte for",
  "byte, produced by the same formatter in `-Replay` mode):",
  ...windows.map((w) => `- \`${w.renderedTextPath}\``),
  "",
  "## Window processes",
  "",
  "```json",
  JSON.stringify(mine, null, 2),
  "```",
  "",
  "## Stopping this hold",
  "",
  "Closing the hold also closes the windows (they are children of the MCP server).",
  "",
  "```",
  stopCommand,
  "```",
  "",
  `State root: \`${RUN_ROOT}\``,
  `Repo under test: \`${REPO}\``,
  "",
];
const instructionPath = join(OUT_DIR, "visual-acceptance.md");
writeFileSync(instructionPath, lines.join("\n"));
console.log(`\nwindows: ${windows.length}, titles matched: ${mine.length}`);
console.log(`checklist: ${instructionPath}`);

for (const w of windows) {
  if (w.viewerState?.pid && !pidAlive(w.viewerState.pid)) console.log(`WARNING: window for ${w.runId} is not alive`);
}

// Hold: keep the MCP server (and therefore the windows) alive for the human.
const holdMs = HOLD_MINUTES * 60_000;
console.log(`holding for ${HOLD_MINUTES} minutes so the windows stay on screen...`);
await sleep(holdMs);
console.log("hold finished; closing the server and its windows");
await client.close();
process.exit(0);
