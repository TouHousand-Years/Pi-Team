import { test } from "node:test";
import assert from "node:assert/strict";
import { closeSync, mkdtempSync, mkdirSync, openSync, rmSync, writeFileSync, existsSync, readFileSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { TranscriptWriter } from "../src/transcript/writer.js";
import { replay, readManifest } from "../src/transcript/reader.js";
import { TranscriptStore } from "../src/transcript/store.js";
import { reconcileStale } from "../src/transcript/recovery.js";
import { spawnDelegate, collectOutput } from "../src/runner/spawn.js";
import { delegate } from "../src/tools/delegate.js";
import { status } from "../src/tools/status.js";
import { SessionRegistry } from "../src/registry/session.js";
import { RunRegistry } from "../src/registry/run.js";
import { ProcessTable } from "../src/runner/process-table.js";
import { fakePiEnv, tmpCwd, withEnv } from "./helpers.js";

function tmpDir() { return mkdtempSync(join(tmpdir(), "pi-transcript-")); }

function beginInput(runId: string) {
  return {
    runId,
    session: "s1",
    cwd: "C:\\work",
    promptSubmitted: "提交的 prompt（含中文）",
    promptEffective: "提交的 prompt（含中文）",
  };
}

// 手工构造 transcript.jsonl（精确控制坏行/空洞/篡改），并按规则追加 terminal。
// entries 中的 string 原样插入（坏行），其余对象 JSON 序列化；hash 按最终行字节计算。
function craftTranscript(dir: string, entries: unknown[], opts: { sha?: string; omitTerminal?: boolean; trailing?: string } = {}) {
  mkdirSync(dir, { recursive: true });
  const hash = createHash("sha256");
  const lines: string[] = [];
  for (const entry of entries) {
    lines.push(typeof entry === "string" ? entry : JSON.stringify(entry));
  }
  let body = "";
  for (const line of lines) {
    body += line + "\n";
    hash.update(Buffer.from(line + "\n", "utf8"));
  }
  if (!opts.omitTerminal) {
    const lastSeq = entries.length > 0 && typeof entries[entries.length - 1] !== "string"
      ? (entries[entries.length - 1] as any).seq
      : 0;
    const terminal = {
      v: 1, seq: lastSeq + 1, tUtc: "2026-01-01T00:00:00.000Z", tMono: 1,
      ch: "meta", kind: "terminal",
      terminal: {
        outcome: "succeeded", exitCode: 0, signal: null,
        startedAt: 1, endedAt: 2, finalSeq: lastSeq + 1,
        stdoutBytes: 1, stderrBytes: 0, sawEof: true,
        piSettlement: { agentEnd: true, agentSettled: true },
        sha256: opts.sha ?? hash.digest("hex"),
      },
    };
    body += JSON.stringify(terminal) + "\n";
  }
  if (opts.trailing) body += opts.trailing;
  writeFileSync(join(dir, "transcript.jsonl"), body, "utf8");
}

function stdoutRecord(seq: number, text: string) {
  return { v: 1, seq, tUtc: "2026-01-01T00:00:00.000Z", tMono: seq, ch: "stdout", kind: "bytes", bytes: { b64: Buffer.from(text, "utf8").toString("base64"), groupId: "g1", part: 1, final: true, byteCount: Buffer.byteLength(text) } };
}

// ===== 写入/重放：字节保真 =====

test("writer→replay 往返：字节级保真（多字节中文 + 二进制 + 分块）", () => {
  const dir = join(tmpDir(), "run-a");
  const w = TranscriptWriter.create(dir, beginInput("run-a"));
  assert.equal(w.captureFailed, false);

  const multibyte = Buffer.from("你好，世界 — emoji 🎉", "utf8");
  // 跨 chunk 撕裂多字节序列
  w.stdoutData(multibyte.subarray(0, 3));
  w.stdoutData(multibyte.subarray(3));
  const binary = Buffer.from([0x00, 0x01, 0xff, 0xfe, 0x80, 0x0a, 0x0d, 0x7f]);
  w.stdoutData(binary);
  w.stderrData(Buffer.from("diagnostic\n", "utf8"));
  w.state("pi-session-established", "sess-1");
  w.finalize({
    outcome: "succeeded", exitCode: 0, signal: null,
    startedAt: 1, endedAt: 2, sawEof: true,
    piSettlement: { agentEnd: true, agentSettled: true },
  });

  const rep = replay(dir);
  assert.equal(rep.integrity.ok, true, `integrity reasons: ${rep.integrity.reasons.join(";")}`);
  assert.ok(rep.terminal);
  assert.equal(rep.terminal!.outcome, "succeeded");
  assert.equal(rep.terminal!.captureError, undefined);

  // 重组 stdout 字节 = 原始字节
  const stdoutChunks = rep.records.filter((r) => r.ch === "stdout" && r.kind === "bytes");
  const reassembled = Buffer.concat(stdoutChunks.map((r: any) => Buffer.from(r.bytes.b64, "base64")));
  assert.deepEqual([...reassembled.subarray(0, multibyte.length)], [...multibyte]);
  assert.deepEqual([...reassembled.subarray(multibyte.length)], [...binary]);

  // stderr 与 meta 记录
  const stderrChunks = rep.records.filter((r) => r.ch === "stderr");
  assert.equal(stderrChunks.length, 1);
  const launch = rep.records.find((r: any) => r.kind === "launch") as any;
  assert.equal(launch.launch.promptSubmitted, "提交的 prompt（含中文）");
  assert.equal(launch.launch.promptEffective, "提交的 prompt（含中文）");
  const state = rep.records.find((r: any) => r.kind === "state") as any;
  assert.equal(state.state, "pi-session-established");

  // manifest 摘要 + lease 释放
  const { manifest } = readManifest(dir);
  assert.ok(manifest?.terminal);
  assert.equal(manifest!.terminal!.outcome, "succeeded");
  const lease = JSON.parse(readFileSync(join(dir, "lease.json"), "utf8"));
  assert.equal(lease.released, true);
});

test(">64KiB payload 分块携带 groupId/part/final，重组无损", () => {
  const dir = join(tmpDir(), "run-chunk");
  const w = TranscriptWriter.create(dir, beginInput("run-chunk"));
  const big = Buffer.alloc(64 * 1024 + 100);
  for (let i = 0; i < big.length; i++) big[i] = i % 251;
  w.stdoutData(big);
  w.finalize({
    outcome: "succeeded", exitCode: 0, signal: null,
    startedAt: 1, endedAt: 2, sawEof: true,
    piSettlement: { agentEnd: false, agentSettled: false },
  });

  const rep = replay(dir);
  assert.equal(rep.integrity.ok, true);
  const chunks = rep.records.filter((r) => r.ch === "stdout" && r.kind === "bytes") as any[];
  assert.equal(chunks.length, 2);
  const groupId = new Set(chunks.map((c) => c.bytes.groupId));
  assert.equal(groupId.size, 1);
  assert.deepEqual(chunks.map((c) => c.bytes.part), [1, 2]);
  assert.equal(chunks[0].bytes.final, false);
  assert.equal(chunks[1].bytes.final, true);
  assert.equal(chunks.reduce((n, c) => n + c.bytes.byteCount, 0), big.length);
  const reassembled = Buffer.concat(chunks.map((c) => Buffer.from(c.bytes.b64, "base64")));
  assert.ok(reassembled.equals(big));
});

// ===== 重放完整性 =====

test("seq 空洞 → 完整性永久受损（terminal 记录本身仍可读）", () => {
  const dir = join(tmpDir(), "run-gap");
  craftTranscript(dir, [stdoutRecord(1, "a"), stdoutRecord(3, "c")]);
  const rep = replay(dir);
  assert.equal(rep.integrity.ok, false);
  assert.ok(rep.integrity.reasons.some((r) => r.includes("sequence-gap")));
});

test("字节被篡改 → terminal-hash-mismatch", () => {
  const dir = join(tmpDir(), "run-tamper");
  craftTranscript(dir, [stdoutRecord(1, "hello")]);
  // 篡改一行内容（不动 terminal 行）
  const raw = readFileSync(join(dir, "transcript.jsonl"), "utf8").split("\n");
  raw[0] = raw[0].replace('"part":1', '"part":9');
  writeFileSync(join(dir, "transcript.jsonl"), raw.join("\n"), "utf8");
  const rep = replay(dir);
  assert.equal(rep.integrity.ok, false);
  assert.ok(rep.integrity.reasons.includes("terminal-hash-mismatch"));
});

test("缺 terminal / 未终止尾行 → 截断证据", () => {
  const dir1 = join(tmpDir(), "run-noterm");
  craftTranscript(dir1, [stdoutRecord(1, "a")], { omitTerminal: true });
  const rep1 = replay(dir1);
  assert.equal(rep1.integrity.ok, false);
  assert.ok(rep1.integrity.reasons.includes("no-terminal-record"));

  const dir2 = join(tmpDir(), "run-partial");
  craftTranscript(dir2, [stdoutRecord(1, "a")], { trailing: '{"seq":2,"trunc' });
  const rep2 = replay(dir2);
  assert.equal(rep2.integrity.ok, false);
  assert.ok(rep2.integrity.reasons.includes("trailing-partial-line"));
  assert.equal(rep2.trailingPartial, '{"seq":2,"trunc');
});

test("坏行无损保留（malformed），不算完整性受损", () => {
  const dir = join(tmpDir(), "run-badline");
  craftTranscript(dir, [
    stdoutRecord(1, "a"),
    "this is not json { truncated",
    stdoutRecord(2, "b"),
  ]);
  const rep = replay(dir);
  assert.equal(rep.malformed.length, 1);
  assert.match(rep.malformed[0].raw, /not json/);
  assert.equal(rep.integrity.ok, true, `reasons: ${rep.integrity.reasons.join(";")}`);
});

// ===== 崩溃恢复 =====

test("recovery：旧进程确认不在 → 补 incomplete 终态；存活进程 → ambiguous", () => {
  const dir1 = join(tmpDir(), "rec-dead");
  craftTranscript(dir1, [stdoutRecord(1, "partial")], { omitTerminal: true });
  const r1 = reconcileStale(dir1, process.pid + 100000, "host restart");
  assert.equal(r1, "recovered");
  const rep1 = replay(dir1);
  assert.ok(rep1.terminal);
  assert.equal(rep1.terminal!.outcome, "incomplete");
  assert.equal(rep1.integrity.ok, true, `reasons: ${rep1.integrity.reasons.join(";")}`);

  const dir2 = join(tmpDir(), "rec-ambiguous");
  craftTranscript(dir2, [stdoutRecord(1, "partial")], { omitTerminal: true });
  // lease.pid = 一个确定存活的进程（sleep 3s 的子进程，且非 currentPid 参数）→ 所有权不明
  mkdirSync(dir2, { recursive: true });
  const keeper = spawn("bash", ["-c", "sleep 3"]);
  writeFileSync(join(dir2, "lease.json"), JSON.stringify({ runId: "x", pid: keeper.pid, leaseId: "l", createdAt: 1 }));
  const r2 = reconcileStale(dir2, process.pid + 100000, "host restart");
  assert.equal(r2, "ambiguous");
  const rep2 = replay(dir2);
  assert.equal(rep2.terminal, null);  // 未被补写
  keeper.kill();

  const dir3 = join(tmpDir(), "rec-terminal");
  craftTranscript(dir3, [stdoutRecord(1, "done")]);
  assert.equal(reconcileStale(dir3, process.pid, "host restart"), "already-terminal");
});

// ===== 保留清理 =====

test("cleanup：7 天过期 trash → 宽限后 purge；running/所有权不明 bundle 不动；配额最旧优先", () => {
  const root = tmpDir();
  const now = Date.now();
  const store = new TranscriptStore(root, { retentionMs: 1000, trashGraceMs: 1000, quotaBytes: 10 * 1024 });

  // 过期终态 bundle
  const oldDir = join(root, "run-old");
  TranscriptWriter.create(oldDir, beginInput("run-old")).finalize({
    outcome: "succeeded", exitCode: 0, signal: null, startedAt: 1, endedAt: now - 5000, sawEof: true,
    piSettlement: { agentEnd: false, agentSettled: false },
  });
  // 新鲜终态 bundle
  const newDir = join(root, "run-new");
  TranscriptWriter.create(newDir, beginInput("run-new")).finalize({
    outcome: "succeeded", exitCode: 0, signal: null, startedAt: 1, endedAt: now, sawEof: true,
    piSettlement: { agentEnd: false, agentSettled: false },
  });
  // running bundle（无 terminal）
  const runDir = join(root, "run-running");
  TranscriptWriter.create(runDir, beginInput("run-running"));
  // 所有权不明终态 bundle（lease 指向确定存活的其它进程，未释放）
  const ambDir = join(root, "run-amb");
  TranscriptWriter.create(ambDir, beginInput("run-amb")).finalize({
    outcome: "failed", exitCode: 1, signal: null, startedAt: 1, endedAt: now - 5000, sawEof: true,
    piSettlement: { agentEnd: false, agentSettled: false },
  });
  const keeper = spawn("bash", ["-c", "sleep 5"]);
  writeFileSync(join(ambDir, "lease.json"), JSON.stringify({ runId: "run-amb", pid: keeper.pid, leaseId: "l", createdAt: 1 }));

  let report = store.cleanup(now);
  assert.deepEqual(report.trashed, ["run-old"]);
  assert.ok(existsSync(runDir), "running bundle 不能被清");
  assert.ok(existsSync(ambDir), "所有权不明 bundle 不能被清");
  assert.ok(existsSync(newDir), "新鲜 bundle 不能被清");

  // trash 内过宽限期 → purge
  const trashedName = `${"run-old"}.${now}`;
  const trashPath = join(root, ".trash", trashedName);
  assert.ok(existsSync(trashPath));
  const oldTime = new Date(now - 60_000);
  utimesSync(trashPath, oldTime, oldTime);
  report = store.cleanup(now + 2000);
  assert.ok(report.purged.some((p) => p.startsWith("run-old")), `purged: ${report.purged}`);
  assert.ok(!existsSync(trashPath));
  keeper.kill();
  rmSync(root, { recursive: true, force: true });
});

test("cleanup：超配额 → 最旧终态优先 trash，活动/不明永不删", () => {
  const root = tmpDir();
  const now = Date.now();
  // 配额 1 byte：任何 bundle 都超；两个终态都足够新鲜，走配额路径而非过期路径
  const store = new TranscriptStore(root, { retentionMs: 60000, trashGraceMs: 1000, quotaBytes: 1 });

  const a = join(root, "run-a");
  TranscriptWriter.create(a, beginInput("run-a")).finalize({
    outcome: "succeeded", exitCode: 0, signal: null, startedAt: 1, endedAt: now - 2, sawEof: true,
    piSettlement: { agentEnd: false, agentSettled: false },
  });
  const b = join(root, "run-b");
  TranscriptWriter.create(b, beginInput("run-b")).finalize({
    outcome: "succeeded", exitCode: 0, signal: null, startedAt: 1, endedAt: now - 1, sawEof: true,
    piSettlement: { agentEnd: false, agentSettled: false },
  });
  const running = join(root, "run-running");
  TranscriptWriter.create(running, beginInput("run-running"));

  const report = store.cleanup(now);
  // 全部终态（lease 已释放）按最旧优先 trash
  assert.deepEqual(report.trashed, []);
  assert.deepEqual(report.quotaTrashed, ["run-a", "run-b"]);
  assert.ok(existsSync(running), "running bundle 不能被清");
  rmSync(root, { recursive: true, force: true });
});

// ===== collectOutput 原始字节回调 =====

test("collectOutput onStdoutData/onStderrData 收到原始字节", async () => {
  const child = spawn("bash", ["-c", "printf 'hi\\n'; printf 'oops' >&2"]);
  const out: Buffer[] = [];
  const err: Buffer[] = [];
  const res = await collectOutput(child, {
    onStdoutData: (b) => out.push(b),
    onStderrData: (b) => err.push(b),
  });
  assert.equal(res.exitCode, 0);
  assert.equal(Buffer.concat(out).toString("utf8"), "hi\n");
  assert.equal(Buffer.concat(err).toString("utf8"), "oops");
  assert.equal(res.sawEof, true);
});

test("spawn 失败 → sawEof=false，collectOutput 不 throw", async () => {
  const saved = process.env.PI_BIN;
  process.env.PI_BIN = "definitely-not-a-real-bin-xyz";
  try {
    const { child } = spawnDelegate({ prompt: "p", constraints: {}, cwd: process.cwd() });
    const res = await collectOutput(child);
    assert.ok(res.spawnError);
    assert.equal(res.sawEof, false);
  } finally {
    if (saved === undefined) delete process.env.PI_BIN; else process.env.PI_BIN = saved;
  }
});

// ===== delegate 集成 =====

function depsWith(store: TranscriptStore | undefined) {
  return { sessions: new SessionRegistry(), runs: new RunRegistry(), procs: new ProcessTable(), transcripts: store };
}

async function drain(d: { runs: RunRegistry }, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (d.runs.runningCount() > 0 && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 50));
  }
}

test("delegate 成功 → transcript 终态 succeeded、integrity-ok、字节保留；status 带 transcript", async () => {
  const c = tmpCwd();
  const root = tmpDir();
  const store = new TranscriptStore(root);
  let runId = "";
  await withEnv(fakePiEnv("success"), async () => {
    const d = depsWith(store);
    const r = await delegate({ prompt: "数一下到三", session: "s1", cwd: c.dir, goal: "g", mode: "sync" }, d);
    runId = r.runId;
    assert.equal(r.status, "completed");
    const st = await status({ runId: r.runId }, d.runs, store);
    assert.ok(st.transcript);
    assert.equal(st.transcript!.available, true);
    assert.equal(st.transcript!.outcome, "succeeded");
    assert.equal(st.transcript!.integrity, "integrity-ok");
  });

  const rep = store.replayRun(runId);
  assert.equal(rep.integrity.ok, true, `reasons: ${rep.integrity.reasons.join(";")}`);
  assert.ok(rep.terminal);
  assert.equal(rep.terminal!.outcome, "succeeded");
  assert.equal(rep.terminal!.piSettlement.agentEnd, true);
  // stdout 字节逐字保留（fake-pi 输出）
  const stdoutChunks = rep.records.filter((r) => r.ch === "stdout" && r.kind === "bytes") as any[];
  const stdoutText = Buffer.concat(stdoutChunks.map((r) => Buffer.from(r.bytes.b64, "base64"))).toString("utf8");
  assert.match(stdoutText, /"type":"agent_end"/);
  assert.match(stdoutText, /FAKE_OUTPUT_/);
  // launch 记录了提交的 prompt 与 allowlist 元数据，且不含环境变量
  const launch = rep.records.find((r: any) => r.kind === "launch") as any;
  assert.equal(launch.launch.promptSubmitted, "数一下到三");
  rmSync(root, { recursive: true, force: true });
  c.cleanup();
});

test("delegate 终态分类：error_exit→failed、no_session→protocol-error、超时→incomplete", async () => {
  // failed
  let c = tmpCwd();
  let root = tmpDir();
  await withEnv(fakePiEnv("error_exit"), async () => {
    const d = depsWith(new TranscriptStore(root));
    const r = await delegate({ prompt: "p", session: "s1", cwd: c.dir, goal: "g", mode: "sync" }, d);
    assert.equal(r.status, "error");
    const rep = new TranscriptStore(root).replayRun(r.runId);
    assert.equal(rep.terminal!.outcome, "failed");
    assert.match(Buffer.from((rep.records.filter((x) => x.ch === "stderr" && x.kind === "bytes") as any[]).map((x) => Buffer.from(x.bytes.b64, "base64")).reduce((acc: Buffer, b: Buffer) => Buffer.concat([acc, b]), Buffer.alloc(0))).toString("utf8"), /boom/);
  });
  rmSync(root, { recursive: true, force: true });
  c.cleanup();

  // protocol-error
  c = tmpCwd();
  root = tmpDir();
  await withEnv(fakePiEnv("no_session"), async () => {
    const d = depsWith(new TranscriptStore(root));
    const r = await delegate({ prompt: "p", session: "s1", cwd: c.dir, goal: "g", mode: "sync" }, d);
    assert.equal(r.status, "error");
    const rep = new TranscriptStore(root).replayRun(r.runId);
    assert.equal(rep.terminal!.outcome, "protocol-error");
  });
  rmSync(root, { recursive: true, force: true });
  c.cleanup();

  // incomplete（超时 kill 截断）
  c = tmpCwd();
  root = tmpDir();
  await withEnv(fakePiEnv("hang"), async () => {
    const d = depsWith(new TranscriptStore(root));
    const r = await delegate({ prompt: "p", session: "s1", cwd: c.dir, goal: "g", mode: "sync", runTimeoutMs: 500 }, d);
    assert.equal(r.status, "timeout");
    const rep = new TranscriptStore(root).replayRun(r.runId);
    assert.ok(rep.terminal);
    assert.equal(rep.terminal!.outcome, "incomplete");
    assert.equal(rep.terminal!.signal, "SIGTERM");
  });
  rmSync(root, { recursive: true, force: true });
  c.cleanup();
});

// ===== 存储故障隔离 =====

test("存储故障隔离：root 不可用 → delegate 照常成功，status 无 transcript", async () => {
  const c = tmpCwd();
  const outer = tmpDir();
  const fileRoot = join(outer, "not-a-dir");
  writeFileSync(fileRoot, "x");  // root 是文件 → mkdir 失败 → store disabled
  const store = new TranscriptStore(fileRoot);
  assert.ok(store.disabledReason);
  await withEnv(fakePiEnv("success"), async () => {
    const d = depsWith(store);
    const r = await delegate({ prompt: "p", session: "s1", cwd: c.dir, goal: "g", mode: "sync" }, d);
    assert.equal(r.status, "completed");  // Run 不受影响
    const st = await status({ runId: r.runId }, d.runs, store);
    assert.ok(st.transcript);
    assert.equal(st.transcript!.available, false);
  });
  rmSync(outer, { recursive: true, force: true });
  c.cleanup();
});

test("向后兼容：不接 transcript 存储的 delegate/status 行为不变", async () => {
  const c = tmpCwd();
  await withEnv(fakePiEnv("success"), async () => {
    const d = depsWith(undefined);
    const r = await delegate({ prompt: "p", session: "s1", cwd: c.dir, goal: "g", mode: "sync" }, d);
    assert.equal(r.status, "completed");
    const st = await status({ runId: r.runId }, d.runs);
    assert.equal(st.transcript, undefined);
  });
  c.cleanup();
});

test("transcriptRoot 支持 PI_SUBAGENT_TRANSCRIPTS 覆盖", async () => {
  await withEnv({ PI_SUBAGENT_TRANSCRIPTS: join(tmpDir(), "custom-runs") }, async () => {
    const { transcriptRoot } = await import("../src/transcript/store.js");
    assert.equal(transcriptRoot(), process.env.PI_SUBAGENT_TRANSCRIPTS);
  });
});

// ===== 评审补充：恢复尾行 / 活跃排除 / 捕获错误类 / 50k 重放 / 保留竞态 =====

test("recovery：未终止尾行被终止且计入 hash，补写终态后 integrity-ok", () => {
  const dir = join(tmpDir(), "rec-partial");
  craftTranscript(dir, [stdoutRecord(1, "ok")], { omitTerminal: true, trailing: '{"v":1,"seq":2,"trunc' });
  assert.equal(reconcileStale(dir, process.pid + 100000, "host restart"), "recovered");
  const rep = replay(dir);
  assert.equal(rep.integrity.ok, true, `reasons: ${rep.integrity.reasons.join(";")}`);
  assert.equal(rep.trailingPartial, null);      // 尾行已终止
  assert.equal(rep.terminal!.outcome, "incomplete");
  assert.match(rep.terminal!.captureError!, /partial/);
  // 被终止的尾行作为坏行无损可见（它不是合法 JSON 记录）
  assert.ok(rep.malformed.some((m) => m.raw.includes('"trunc')), "尾行应保留可见");
});

test("reconcile 排除本进程活跃 Run（不误终止活 Run 的证据流）", () => {
  const root = tmpDir();
  const store = new TranscriptStore(root);

  // 不排除 → 非活跃遗留会被补写终态（恢复路径本身仍然有效）
  const wStale = store.begin(beginInput("run-stale"));
  wStale.stdoutData(Buffer.from("leftover\n"));
  assert.equal(store.reconcile([]).find((r) => r.runId === "run-stale")!.result, "recovered");

  // 排除 → 活跃 Run 不被触碰，继续写不受影响
  const runId = "run-live";
  const w = store.begin(beginInput(runId));  // 模拟活跃 Run（写了一半）
  w.stdoutData(Buffer.from("partial line\n"));
  assert.equal(store.reconcile([runId]).find((r) => r.runId === runId)!.result, "ambiguous");
  w.stdoutData(Buffer.from("more\n"));
  w.finalize({
    outcome: "succeeded", exitCode: 0, signal: null,
    startedAt: 1, endedAt: 2, sawEof: true,
    piSettlement: { agentEnd: false, agentSettled: false },
  });
  const rep3 = replay(join(root, runId));
  assert.equal(rep3.integrity.ok, true, `reasons: ${rep3.integrity.reasons.join(";")}`);
  const stdoutChunks = rep3.records.filter((r) => r.ch === "stdout" && r.kind === "bytes");
  assert.equal(stdoutChunks.length, 2);      // 活跃期间的写入全部保留
  rmSync(root, { recursive: true, force: true });
});

test("捕获错误降级 integrity：captureError → describe= capture-error（终态仍按 wrapper 判定）", () => {
  const dir = join(tmpDir(), "run-capture-err");
  const w = TranscriptWriter.create(dir, beginInput("run-capture-err"));
  w.stdoutData(Buffer.from("some output\n"));
  w.captureError("stdio stream error before EOF; captured output may be truncated");
  w.finalize({
    outcome: "succeeded", exitCode: 0, signal: null,
    startedAt: 1, endedAt: 2, sawEof: false,
    piSettlement: { agentEnd: true, agentSettled: false },
  });
  const store = new TranscriptStore(join(dir, ".."));
  const d = store.describe("run-capture-err");
  assert.equal(d.available, true);
  assert.equal(d.outcome, "succeeded");           // wrapper 终态不被捕获错误翻转
  assert.equal(d.integrity, "capture-error");     // 但 integrity 降级
  assert.match(d.captureError!, /truncated/);
});

test("50,000 记录重放：结构完整、hash 校验通过", () => {
  const dir = join(tmpDir(), "run-50k");
  const w = TranscriptWriter.create(dir, beginInput("run-50k"));
  const line = JSON.stringify({ type: "message_update", usage: { totalTokens: 1 }, assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "x".repeat(100) } });
  const buf = Buffer.from(line + "\n", "utf8");
  for (let i = 0; i < 50_000; i++) w.stdoutData(buf);
  w.finalize({
    outcome: "succeeded", exitCode: 0, signal: null,
    startedAt: 1, endedAt: 2, sawEof: true,
    piSettlement: { agentEnd: false, agentSettled: false },
  });
  const t0 = Date.now();
  const rep = replay(dir);
  const elapsed = Date.now() - t0;
  assert.equal(rep.records.length, 50_001);  // launch + 50000 条 stdout
  assert.equal(rep.integrity.ok, true, `reasons: ${rep.integrity.reasons.slice(0, 3).join(";")}`);
  assert.ok(elapsed < 10_000, `replay 50k 记录应在 10s 内完成，实际 ${elapsed}ms`);
});

test("保留竞态：bundle 被外部占用时 rename 失败 → skipped，绝不部分删除", function () {
  if (process.platform !== "win32") {
    // POSIX 上 rename 不受打开句柄影响，此竞态仅在 Windows 成立
    this.skip();
  }
  const root = tmpDir();
  const store = new TranscriptStore(root, { retentionMs: 0, trashGraceMs: 1000 });
  const dir = join(root, "run-locked");
  TranscriptWriter.create(dir, beginInput("run-locked")).finalize({
    outcome: "succeeded", exitCode: 0, signal: null, startedAt: 1, endedAt: 1, sawEof: true,
    piSettlement: { agentEnd: false, agentSettled: false },
  });
  const fd = openSync(join(dir, "transcript.jsonl"), "r");  // 持有句柄 → rename 被锁
  try {
    const report = store.cleanup();
    assert.deepEqual(report.trashed, []);
    assert.ok(report.skipped.includes("run-locked"));
    assert.ok(existsSync(dir), "bundle 必须原样保留");
  } finally {
    closeSync(fd);
  }
  rmSync(root, { recursive: true, force: true });
});
