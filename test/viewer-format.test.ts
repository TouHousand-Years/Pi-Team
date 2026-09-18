// Viewer formatter / replay matrix (ticket 07).
//
// These tests drive the real, shipped PowerShell viewer in its headless
// -Replay mode against bundles written in the exact Transcript v1 on-disk
// format. The production viewer is Windows-only (ticket 04, round 5), so the
// suite skips elsewhere; everything else in this file is ordinary Node.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const VIEWER = resolve("viewer/run-window.ps1");
const POWERSHELL = process.env.PI_SUBAGENT_POWERSHELL ?? "powershell.exe";
const ON_WINDOWS = process.platform === "win32";
const SKIP = ON_WINDOWS ? false : "the production viewer is Windows-only";

const PS_ARGS = ["-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass", "-File", VIEWER];

function tmpDir(): string {
  return mkdtempSync(join(tmpdir(), "pi-viewer-"));
}

// ===== bundle construction (exact Transcript v1 bytes) =====

type Entry = string | Record<string, unknown>;

interface BundleOpts {
  terminal?: "none" | {
    outcome: "succeeded" | "failed" | "protocol-error" | "incomplete";
    captureError?: string;
    exitCode?: number | null;
    signal?: string | null;
    sha?: string;
  };
  trailing?: string;
  session?: string;
}

function stdoutRecord(seq: number, text: string) {
  return {
    v: 1, seq, tUtc: "2026-01-01T00:00:00.000Z", tMono: seq, ch: "stdout", kind: "bytes",
    bytes: { b64: Buffer.from(text, "utf8").toString("base64"), groupId: `g${seq}`, part: 1, final: true, byteCount: Buffer.byteLength(text) },
  };
}

function bytePart(seq: number, ch: string, groupId: string, part: number, final: boolean, bytes: Buffer) {
  return { v: 1, seq, tUtc: "2026-01-01T00:00:00.000Z", tMono: seq, ch, kind: "bytes", bytes: { b64: bytes.toString("base64"), groupId, part, final, byteCount: bytes.length } };
}

function metaRecord(seq: number, kind: string, payload: Record<string, unknown>) {
  return { v: 1, seq, tUtc: "2026-01-01T00:00:00.000Z", tMono: seq, ch: "meta", kind, ...payload };
}

function launchRecord(seq: number) {
  return metaRecord(seq, "launch", {
    launch: {
      promptSubmitted: "Fix the parser.\nsecond line of the submitted prompt",
      promptEffective: "Fix the parser.",
      cwd: "C:/work",
      constraints: { tools: ["bash"], thinking: "medium" },
      stdin: "none",
    },
  });
}

function writeBundle(dir: string, runId: string, entries: Entry[], opts: BundleOpts = {}): void {
  mkdirSync(dir, { recursive: true });
  const hash = createHash("sha256");
  let body = "";
  let lastSeq = 0;
  for (const entry of entries) {
    const line = typeof entry === "string" ? entry : JSON.stringify(entry);
    body += line + "\n";
    hash.update(Buffer.from(line + "\n", "utf8"));
    if (typeof entry !== "string") lastSeq = (entry as { seq: number }).seq;
  }
  let terminalSummary: Record<string, unknown> | undefined;
  if (opts.terminal !== "none") {
    const t = opts.terminal ?? { outcome: "succeeded" as const };
    const terminal = {
      outcome: t.outcome,
      exitCode: t.exitCode === undefined ? 0 : t.exitCode,
      signal: t.signal === undefined ? null : t.signal,
      startedAt: 1,
      endedAt: 2,
      finalSeq: lastSeq + 1,
      stdoutBytes: 1,
      stderrBytes: 0,
      sawEof: true,
      ...(t.captureError ? { captureError: t.captureError } : {}),
      piSettlement: { agentEnd: true, agentSettled: true },
      sha256: t.sha ?? hash.digest("hex"),
    };
    body += JSON.stringify(metaRecord(lastSeq + 1, "terminal", { terminal })) + "\n";
    terminalSummary = { outcome: t.outcome, endedAt: 2, finalSeq: lastSeq + 1, sha256: terminal.sha256 };
  }
  if (opts.trailing) body += opts.trailing;
  writeFileSync(join(dir, "transcript.jsonl"), body, "utf8");
  writeFileSync(join(dir, "manifest.json"), JSON.stringify({
    version: 1,
    runId,
    session: opts.session ?? "sess-name",
    createdAt: 1,
    ...(terminalSummary ? { finalizedAt: 2, terminal: terminalSummary } : {}),
  }), "utf8");
}

// ===== replay driver =====

interface ReplayReport {
  runId: string;
  session: string;
  header: string[];
  terminal: boolean;
  outcome: string | null;
  token: string;
  integrityOk: boolean;
  integrityReasons: string[];
  soundDecision: string;
  soundWouldAttempt: boolean;
  soundSuppressed: boolean;
  sourceReleased: boolean;
  sourceCleaned: boolean;
  records: number;
  hashExpected: string | null;
  hashComputed: string;
  hashLines: number;
  errors: string[];
}

interface ReplayResult {
  report: ReplayReport;
  text: string;
  status: number;
}

function replay(bundleDir: string, opts: { timeoutMs?: number } = {}): ReplayResult {
  const out = join(bundleDir, "rendered.txt");
  const res = spawnSync(
    POWERSHELL,
    [...PS_ARGS, "-Replay", "-BundleDir", bundleDir, "-OutPath", out, "-ReplayTimeoutMs", String(opts.timeoutMs ?? 1500)],
    { encoding: "utf8", timeout: 120000 },
  );
  assert.equal(res.status, 0, `viewer replay exited ${res.status}: ${res.stderr}`);
  const lines = (res.stdout ?? "").split("\n").map((l) => l.trim()).filter(Boolean);
  const jsonLine = lines[lines.length - 1];
  assert.ok(jsonLine?.startsWith("{"), `viewer replay printed no JSON summary; stdout=${res.stdout} stderr=${res.stderr}`);
  return { report: JSON.parse(jsonLine) as ReplayReport, text: readFileSync(out, "utf8"), status: res.status ?? 0 };
}

function assertOnlyInitialInput(text: string): void {
  assert.equal(
    text.replace(/\r\n/g, "\n").trimEnd(),
    "== initial input\n   text: Fix the parser.\n   text: second line of the submitted prompt",
  );
}

// A representative healthy Pi 0.85.1 lifecycle, using the exact wire shapes
// recorded in the Pi event-surface research.
function happyEntries(): Entry[] {
  const events: unknown[] = [
    { type: "session", version: 3, id: "sess-1", timestamp: "2026-01-01T00:00:00.000Z", cwd: "C:/work" },
    { type: "agent_start" },
    { type: "turn_start" },
    { type: "message_start", message: { role: "user", content: [{ type: "text", text: "Fix the parser." }] } },
    { type: "message_end", message: { role: "user" } },
    { type: "message_start", message: { role: "assistant", api: "openai", provider: "p", model: "mock", content: [{ type: "thinking", thinking: "Let me think. " }] } },
    { type: "message_update", usage: { inputTokens: 1 }, assistantMessageEvent: { type: "thinking_start", contentIndex: 0 } },
    { type: "message_update", assistantMessageEvent: { type: "thinking_delta", contentIndex: 0, delta: "Let me think. " } },
    { type: "message_update", assistantMessageEvent: { type: "thinking_delta", contentIndex: 0, delta: "I should read it." } },
    { type: "message_update", assistantMessageEvent: { type: "thinking_end", contentIndex: 0, content: "Let me think. I should read it." } },
    { type: "message_update", assistantMessageEvent: { type: "text_start", contentIndex: 1 } },
    { type: "message_update", assistantMessageEvent: { type: "text_delta", contentIndex: 1, delta: "I will read " } },
    { type: "message_update", assistantMessageEvent: { type: "text_delta", contentIndex: 1, delta: "the file." } },
    { type: "message_update", assistantMessageEvent: { type: "text_end", contentIndex: 1, content: "I will read the file." } },
    { type: "message_update", assistantMessageEvent: { type: "toolcall_start", contentIndex: 2, id: "call_1", toolName: "read" } },
    { type: "message_update", assistantMessageEvent: { type: "toolcall_delta", contentIndex: 2, delta: "{\"path\":" } },
    { type: "message_update", assistantMessageEvent: { type: "toolcall_delta", contentIndex: 2, delta: "\"a.txt\"}" } },
    { type: "message_update", assistantMessageEvent: { type: "toolcall_end", contentIndex: 2, toolCall: { id: "call_1", name: "read", arguments: { path: "a.txt" } } } },
    { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "I will read the file." }], stopReason: "toolUse", usage: { inputTokens: 10, outputTokens: 4, totalTokens: 14 } } },
    { type: "tool_execution_start", toolCallId: "call_1", toolName: "read", args: { path: "a.txt" } },
    { type: "tool_execution_update", toolCallId: "call_1", toolName: "read", partialResult: { content: [{ type: "text", text: "line one\n" }] } },
    { type: "tool_execution_end", toolCallId: "call_1", toolName: "read", result: { content: [{ type: "text", text: "line one\n" }], details: {} }, isError: false },
    { type: "message_start", message: { role: "toolResult", toolCallId: "call_1", toolName: "read", content: [{ type: "text", text: "line one\n" }] } },
    { type: "message_end", message: { role: "toolResult", toolCallId: "call_1" } },
    { type: "turn_end", message: { role: "assistant", stopReason: "toolUse", usage: { totalTokens: 14 } }, toolResults: [{ toolCallId: "call_1" }] },
    { type: "turn_start" },
    { type: "message_start", message: { role: "assistant", model: "mock" } },
    { type: "message_update", assistantMessageEvent: { type: "text_start", contentIndex: 0 } },
    { type: "message_update", assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "The parser is fine." } },
    { type: "message_update", assistantMessageEvent: { type: "text_end", contentIndex: 0, content: "The parser is fine." } },
    { type: "message_end", message: { role: "assistant", stopReason: "stop", usage: { inputTokens: 20, outputTokens: 8, totalTokens: 28 } } },
    { type: "turn_end", message: { role: "assistant", stopReason: "stop" }, toolResults: [] },
    { type: "agent_end", messages: [{ role: "user" }, { role: "assistant" }], willRetry: false },
    { type: "agent_settled" },
  ];

  const entries: Entry[] = [launchRecord(1), metaRecord(2, "state", { state: "starting" }), metaRecord(3, "state", { state: "pi-session-established", detail: "sess-1" })];
  let seq = 4;
  for (const ev of events) entries.push({ ...stdoutRecord(seq++, JSON.stringify(ev) + "\n") });
  // stderr bytes are captured on a separate channel and interleave by sequence.
  const stderrSeq = seq;
  entries.push(bytePart(stderrSeq, "stderr", "g-stderr", 1, true, Buffer.from("a diagnostic on stderr\n", "utf8")));
  return entries;
}

test("viewer formatter: healthy Run shows only initial input, thinking, assistant text, and tool calls", { skip: SKIP }, () => {
  const dir = join(tmpDir(), "run-happy");
  writeBundle(dir, "run-happy", happyEntries());
  const { report, text } = replay(dir);

  // Evidence integrity: the viewer hashed the pre-terminal bytes itself.
  assert.equal(report.integrityOk, true, report.integrityReasons.join("; "));
  assert.equal(report.integrityReasons.length, 0);
  assert.equal(report.token, "SUCCEEDED");
  assert.equal(report.outcome, "succeeded");
  assert.equal(report.soundDecision, "success");
  assert.equal(report.hashComputed, report.hashExpected);
  assert.equal(report.hashLines, report.records - 1);
  assert.deepEqual(report.errors, []);
  assert.equal(report.session, "sess-name");

  assert.match(text, /== initial input\n\s+text: Fix the parser\.\n\s+text: second line of the submitted prompt/);

  // Streaming fragments are withheld while healthy, then reconciled into the
  // complete event - and never appear as a second raw JSON copy.
  assert.doesNotMatch(text, /text_delta/);
  assert.doesNotMatch(text, /"type":"message_update"/);
  assert.doesNotMatch(text, /thinking_delta/);
  assert.match(text, /== assistant text\n\s+text: I will read the file\./);
  assert.match(text, /== thinking\n\s+text: Let me think\. I should read it\./);

  // Tool calls render once, from toolcall_end, including their arguments.
  assert.match(text, /== tool call read id=call_1\n\s+arguments:\n\s+path: a\.txt/);

  // Launch/session metadata, lifecycle events, tool results, diagnostics, usage,
  // and terminal evidence remain in the transcript/report, not the body.
  assert.doesNotMatch(text, /line one|promptSubmitted|message_start|message_end|tool_execution|agent_end|usage|stderr|terminal|sha256|agentSettled/);

  // Every assistant answer text appears exactly once.
  assert.equal(text.split("I will read the file.").length - 1, 1);
  assert.equal(text.split("The parser is fine.").length - 1, 1);
});

test("viewer formatter: unmatched assistant fragments stay visible while capture diagnostics stay out of the body", { skip: SKIP }, () => {
  const dir = join(tmpDir(), "run-fragmented");
  const entries: Entry[] = [
    launchRecord(1),
    stdoutRecord(2, JSON.stringify({ type: "agent_start" }) + "\n"),
    stdoutRecord(3, JSON.stringify({ type: "message_start", message: { role: "assistant", model: "mock" } }) + "\n"),
    stdoutRecord(4, JSON.stringify({ type: "message_update", assistantMessageEvent: { type: "text_start", contentIndex: 0 } }) + "\n"),
    stdoutRecord(5, JSON.stringify({ type: "message_update", assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "half an answer" } }) + "\n"),
    metaRecord(6, "capture-error", { error: "write failed: disk full" }),
    // Sequence 8 arrives after a gap at 7: readable records keep rendering, but
    // integrity is permanently downgraded.
    stdoutRecord(8, JSON.stringify({ type: "agent_settled" }) + "\n"),
  ];
  writeBundle(dir, "run-fragmented", entries, { terminal: { outcome: "incomplete", captureError: "write failed: disk full" } });
  const { report, text } = replay(dir);

  assert.equal(report.integrityOk, false);
  assert.equal(report.token, "INCOMPLETE");
  assert.equal(report.soundDecision, "warning");
  assert.ok(report.integrityReasons.some((r) => r.startsWith("capture-error:")), report.integrityReasons.join("; "));
  assert.ok(report.integrityReasons.some((r) => r.startsWith("sequence-gap:")), report.integrityReasons.join("; "));

  // The withheld output fragment is still shown as assistant text.
  assert.match(text, /== assistant text\n\s+text: half an answer/);
  assert.match(text, /half an answer/);
  assert.equal(text.split("half an answer").length - 1, 1);
  assert.doesNotMatch(text, /capture error|agent_settled|terminal outcome/);
});

test("viewer formatter: filtered byte-stream events still preserve integrity bookkeeping", { skip: SKIP }, () => {
  const dir = join(tmpDir(), "run-bytes");
  const line = JSON.stringify({ type: "future_event", text: "你好，世界", n: 1 }) + "\n";
  const bytes = Buffer.from(line, "utf8");
  const cut = line.indexOf("你") + 1; // split INSIDE the 3-byte character
  const entries: Entry[] = [
    launchRecord(1),
    bytePart(2, "stdout", "gA", 1, false, bytes.subarray(0, cut)),
    bytePart(3, "stdout", "gA", 2, true, bytes.subarray(cut)),
    // A second group that never receives its final part.
    bytePart(4, "stdout", "gB", 1, false, Buffer.from("{\"type\":", "utf8")),
    bytePart(5, "stderr", "gC", 1, true, Buffer.from("boom\n", "utf8")),
  ];
  writeBundle(dir, "run-bytes", entries);
  const { report, text } = replay(dir);

  // Unknown events and stream diagnostics do not enter the focused body.
  assert.doesNotMatch(text, /你好，世界|future_event/);
  assert.equal(text.includes("\uFFFD"), false, "no replacement character may appear for a reassembled character");

  // An unterminated group remains reported through integrity state.
  assert.ok(report.integrityReasons.some((r) => r.startsWith("incomplete byte group gB")), report.integrityReasons.join("; "));
  assert.doesNotMatch(text, /incomplete byte group|stderr|boom/);
});

test("viewer formatter: tool output, unknown events, malformed lines and foreign versions stay out of the body", { skip: SKIP }, () => {
  const dir = join(tmpDir(), "run-fallbacks");
  const entries: Entry[] = [
    launchRecord(1),
    stdoutRecord(2, JSON.stringify({ type: "tool_execution_start", toolCallId: "c9", toolName: "bash", args: { command: "x" } }) + "\n"),
    stdoutRecord(3, JSON.stringify({ type: "tool_execution_update", toolCallId: "c9", toolName: "bash", partialResult: { content: [{ type: "text", text: "streamed fragment" }] } }) + "\n"),
    stdoutRecord(4, JSON.stringify({ type: "tool_execution_end", toolCallId: "c9", toolName: "bash", result: { content: [{ type: "text", text: "final result" }] }, isError: true }) + "\n"),
    stdoutRecord(5, JSON.stringify({ type: "future_event", payload: { n: 1 } }) + "\n"),
    "not json {",                                                     // malformed line: ignored by the body, not an integrity failure
    stdoutRecord(7, JSON.stringify({ type: "message_update", assistantMessageEvent: { type: "brand_new_delta", contentIndex: 0 } }) + "\n"),
    { ...stdoutRecord(8, JSON.stringify({ type: "session", version: 4, id: "future" }) + "\n"), v: 2 },  // foreign schema version
  ];
  writeBundle(dir, "run-fallbacks", entries);
  const { report, text } = replay(dir);

  assertOnlyInitialInput(text);
  assert.ok(report.integrityReasons.some((r) => r.startsWith("foreign-record-version")), report.integrityReasons.join("; "));
  // Unknown and malformed content alone is not a completeness failure.
  assert.equal(report.integrityReasons.some((r) => r.includes("unparsed") || r.includes("unknown")), false);
});

test("viewer formatter: a still-running bundle reports no terminal record without inventing completion", { skip: SKIP }, () => {
  const dir = join(tmpDir(), "run-running");
  writeBundle(dir, "run-running", [launchRecord(1), stdoutRecord(2, JSON.stringify({ type: "agent_start" }) + "\n")], { terminal: "none" });
  const { report, text } = replay(dir);

  assert.equal(report.terminal, false);
  assert.equal(report.outcome, null);
  assert.equal(report.token, "RUNNING");
  assert.equal(report.soundDecision, "none");
  assert.deepEqual(report.integrityReasons, ["no-terminal-record"]);
  assertOnlyInitialInput(text);
});

test("viewer formatter: the window header exposes Run identity and launch metadata", { skip: SKIP }, () => {
  const dir = join(tmpDir(), "run-header");
  writeBundle(dir, "run-header-id", [launchRecord(1)], { terminal: "none" });
  const { report } = replay(dir);
  assert.equal(report.header.length, 4);
  assert.equal(report.header[0], "Run      run-header-id");
  assert.match(report.header[1], /^Session  sess-name {4}cwd C:\/work/);
  assert.match(report.header[2], /constraints=tools=\[bash\] thinking=medium/);
  assert.equal(report.header[3], "Prompt   Fix the parser.");
});

test("viewer self-test: Unicode round-trip, font coverage and formatter honesty pass", { skip: SKIP }, () => {
  const res = spawnSync(POWERSHELL, [...PS_ARGS, "-SelfTest"], { encoding: "utf8", timeout: 120000 });
  assert.equal(res.status, 0, res.stdout + res.stderr);
  assert.match(res.stdout, /SELFTEST PASS/);
  assert.match(res.stdout, /unicode-roundtrip chars=40053/);
  assert.match(res.stdout, /formatter-honesty=ok/);
});

test("viewer formatter: every terminal class is classified and never claims completion it cannot support", { skip: SKIP }, () => {
  const cases: { outcome: "failed" | "protocol-error" | "incomplete" | "succeeded"; token: string; sound: string }[] = [
    { outcome: "succeeded", token: "SUCCEEDED", sound: "success" },
    { outcome: "failed", token: "FAILED", sound: "warning" },
    { outcome: "protocol-error", token: "PROTOCOL ERROR", sound: "warning" },
    { outcome: "incomplete", token: "INCOMPLETE", sound: "warning" },
  ];
  for (const c of cases) {
    const dir = join(tmpDir(), `run-terminal-${c.outcome}`);
    writeBundle(dir, `run-${c.outcome}`, [
      launchRecord(1),
      stdoutRecord(2, JSON.stringify({ type: "agent_end", messages: [], willRetry: false }) + "\n"),
    ], { terminal: { outcome: c.outcome, exitCode: c.outcome === "succeeded" ? 0 : 1, signal: c.outcome === "incomplete" ? "SIGTERM" : null } });
    const { report, text } = replay(dir);
    assert.equal(report.token, c.token, `${c.outcome}: ${JSON.stringify(report.integrityReasons)}`);
    assert.equal(report.outcome, c.outcome);
    assert.equal(report.soundDecision, c.sound, c.outcome);
    assert.equal(report.soundWouldAttempt, true, c.outcome);
    assert.equal(report.integrityOk, true, c.outcome);
    assertOnlyInitialInput(text);
  }
});

test("viewer formatter: the one-shot sound is suppressed by a durable earlier attempt", { skip: SKIP }, () => {
  const dir = join(tmpDir(), "run-alerted");
  writeBundle(dir, "run-alerted", [launchRecord(1), stdoutRecord(2, JSON.stringify({ type: "agent_end", messages: [] }) + "\n")], {
    terminal: { outcome: "succeeded" },
  });

  const first = replay(dir);
  assert.equal(first.report.soundDecision, "success");
  assert.equal(first.report.soundWouldAttempt, true);
  assert.equal(first.report.soundSuppressed, false);

  // A previous instance already attempted the sound for this Run: reopening must
  // not attempt it again.
  writeFileSync(join(dir, "viewer-state.json"), JSON.stringify({
    runId: "run-alerted", instanceId: "prior", pid: 999999, startedAt: 1, updatedAt: 1,
    state: "exited", alertAttemptedAt: 12345,
  }));
  const second = replay(dir);
  assert.equal(second.report.soundDecision, "success");
  assert.equal(second.report.soundWouldAttempt, false);
  assert.equal(second.report.soundSuppressed, true);
});

test("viewer formatter: an unterminated trailing line waits for more bytes, then reports truncation once terminal", { skip: SKIP }, () => {
  const cutRecord = '{"type":"message_update","assistantMessageEvent":{"type":"text_del';
  const cutStream = '{"type":"agent_settled"' + "\n" + '{"type":"message_update","assistantMessageEvent":{"type":"text_del';

  // Still running: both an unterminated stream line and an unfinished journal
  // record are pending, so neither is shown and neither is damage yet.
  const running = join(tmpDir(), "run-partial-running");
  writeBundle(running, "run-partial-running", [
    launchRecord(1),
    stdoutRecord(2, JSON.stringify({ type: "agent_start" }) + "\n"),
    stdoutRecord(3, cutStream),
  ], { terminal: "none", trailing: cutRecord });
  const live = replay(running);
  assert.equal(live.report.terminal, false);
  // A Run that has not reached a terminal record cannot vouch for completeness,
  // but a pending fragment is NOT damage: only the missing terminal is named.
  assert.deepEqual(live.report.integrityReasons, ["no-terminal-record"]);
  assert.doesNotMatch(live.text, /text_del/);

  // Terminal: the same bytes are truncated evidence and are reported, once each.
  const done = join(tmpDir(), "run-partial-done");
  writeBundle(done, "run-partial-done", [
    launchRecord(1),
    stdoutRecord(2, JSON.stringify({ type: "agent_start" }) + "\n"),
    stdoutRecord(3, cutStream),
  ], { trailing: cutRecord });
  const closed = replay(done);
  assert.equal(closed.report.terminal, true);
  const reasons = closed.report.integrityReasons.join("; ");
  assert.ok(reasons.includes("trailing-partial-line in stdout"), reasons);
  assert.ok(reasons.includes("trailing-partial-line in journal"), reasons);
  assert.equal(closed.report.token, "INCOMPLETE");
  assert.doesNotMatch(closed.text, /text_del|partial unterminated/);
});

test("viewer formatter: a completed terminal Run releases its bundle for retention", { skip: SKIP }, () => {
  const dir = join(tmpDir(), "run-released");
  writeBundle(dir, "run-released", [launchRecord(1)], { terminal: { outcome: "succeeded" } });
  const { report } = replay(dir);
  assert.equal(report.sourceReleased, true);
  assert.equal(report.sourceCleaned, false);
});

test("viewer formatter: a message that exists only in agent_end is recovered, never silently lost", { skip: SKIP }, () => {
  // The stream never delivered message_start/message_end for this assistant
  // message, and (unlike a real capture) there is no sequence gap to warn about.
  const dir = join(tmpDir(), "run-recover");
  writeBundle(dir, "run-recover", [
    launchRecord(1),
    stdoutRecord(2, JSON.stringify({ type: "agent_start" }) + "\n"),
    stdoutRecord(3, JSON.stringify({
      type: "agent_end", willRetry: false,
      messages: [{ role: "assistant", content: [{ type: "text", text: "only in agent_end" }] }],
    }) + "\n"),
  ]);
  const { report, text } = replay(dir);
  assert.equal(report.integrityOk, true, report.integrityReasons.join("; "));
  assert.match(text, /== assistant text\n\s+text: only in agent_end/);
  // Rendered exactly once: the recovery block, not a second copy of the message.
  assert.equal(text.split("text: only in agent_end").length - 1, 1);
});

test("viewer formatter: non-text tool updates stay out of the body", { skip: SKIP }, () => {
  const dir = join(tmpDir(), "run-nontext-update");
  writeBundle(dir, "run-nontext-update", [
    launchRecord(1),
    stdoutRecord(2, JSON.stringify({ type: "tool_execution_start", toolCallId: "c1", toolName: "read", args: {} }) + "\n"),
    stdoutRecord(3, JSON.stringify({
      type: "tool_execution_update", toolCallId: "c1", toolName: "read",
      partialResult: { content: [{ type: "image", data: "AAAA", mimeType: "image/png" }], details: { progress: 0.5 } },
    }) + "\n"),
    stdoutRecord(4, JSON.stringify({
      type: "tool_execution_end", toolCallId: "c1", toolName: "read", isError: false,
      result: { content: [{ type: "text", text: "final" }], details: {} },
    }) + "\n"),
  ]);
  const { text } = replay(dir);
  assertOnlyInitialInput(text);
});

test("viewer formatter: tool execution updates and final results stay out of the body", { skip: SKIP }, () => {
  const dir = join(tmpDir(), "run-cumulative");
  writeBundle(dir, "run-cumulative", [
    launchRecord(1),
    stdoutRecord(2, JSON.stringify({ type: "tool_execution_start", toolCallId: "c2", toolName: "bash", args: {} }) + "\n"),
    stdoutRecord(3, JSON.stringify({ type: "tool_execution_update", toolCallId: "c2", toolName: "bash", partialResult: { content: [{ type: "text", text: "HI\n" }] } }) + "\n"),
    stdoutRecord(4, JSON.stringify({ type: "tool_execution_update", toolCallId: "c2", toolName: "bash", partialResult: { content: [{ type: "text", text: "HI\nmore\n" }] } }) + "\n"),
    stdoutRecord(5, JSON.stringify({
      type: "tool_execution_end", toolCallId: "c2", toolName: "bash", isError: false,
      result: { content: [{ type: "text", text: "HI\nmore\n" }], details: {} },
    }) + "\n"),
  ]);
  const { text } = replay(dir);
  assertOnlyInitialInput(text);
});

test("viewer formatter: a high-volume Run renders every record exactly once", { skip: SKIP }, () => {
  const dir = join(tmpDir(), "run-volume");
  const entries: Entry[] = [launchRecord(1)];
  entries.push(stdoutRecord(2, JSON.stringify({ type: "agent_start" }) + "\n"));
  let seq = 3;
  const turns = 400;
  for (let i = 0; i < turns; i++) {
    entries.push(stdoutRecord(seq++, JSON.stringify({ type: "message_start", message: { role: "assistant", model: "mock" } }) + "\n"));
    entries.push(stdoutRecord(seq++, JSON.stringify({ type: "message_update", assistantMessageEvent: { type: "text_start", contentIndex: 0 } }) + "\n"));
    entries.push(stdoutRecord(seq++, JSON.stringify({ type: "message_update", assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: `chunk ${i}` } }) + "\n"));
    entries.push(stdoutRecord(seq++, JSON.stringify({ type: "message_update", assistantMessageEvent: { type: "text_end", contentIndex: 0, content: `rendered line ${i}` } }) + "\n"));
    entries.push(stdoutRecord(seq++, JSON.stringify({ type: "message_end", message: { role: "assistant", stopReason: "stop" } }) + "\n"));
  }
  entries.push(stdoutRecord(seq++, JSON.stringify({ type: "agent_end", messages: [{ role: "assistant" }], willRetry: false }) + "\n"));
  writeBundle(dir, "run-volume", entries);

  const started = Date.now();
  // 2000+ records: the drain is bounded per tick, so give the replay loop room.
  const { report, text } = replay(dir, { timeoutMs: 60000 });
  const elapsed = Date.now() - started;

  assert.equal(report.integrityOk, true, report.integrityReasons.join("; "));
  assert.equal(report.hashComputed, report.hashExpected);
  assert.equal(report.records, 2 + turns * 5 + 1 + 1);
  // No logical truncation: the first and last turn are both present, exactly once.
  assert.equal(text.split("rendered line 0\n").length - 1, 1);
  assert.equal(text.split(`rendered line ${turns - 1}\n`).length - 1, 1);
  assert.equal(text.split("== assistant text").length - 1, turns);
  assert.ok(elapsed < 120000, `high-volume render took ${elapsed}ms`);
});
