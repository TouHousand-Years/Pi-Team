// 崩溃恢复：host 重启后对非终态 bundle 做对账。
// 绝不"收养"Run：只有旧进程确认不存在（或 lease 就是本进程遗留且该 Run 不在活跃集合中）时，
// 才补写 incomplete 终态记录并进入普通保留流程；所有权不确定 → 标记 ambiguous 并跳过，
// 永远不 kill 任何进程。
import { createHash } from "node:crypto";
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  FILES, TRANSCRIPT_SCHEMA_VERSION, observeSettlement,
  type PiSettlement, type TerminalInfo, type TranscriptRecord,
} from "./schema.js";
import { readLease, readManifest, replay } from "./reader.js";
import { msg } from "./writer.js";

export type ReconcileResult = "already-terminal" | "bundle-missing" | "recovered" | "ambiguous" | "reconcile-failed";

export function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e instanceof Error && (e as NodeJS.ErrnoException).code === "EPERM";
  }
}

// 返回是否补写了终态记录。exclude = 本进程仍活跃（正在写 transcript）的 runId 集合，
// 周期对账必须传入，否则会把活 Run 误判为本进程遗留而提前终止其证据流。
export function reconcileStale(
  dir: string,
  currentPid: number,
  reason: string,
  exclude: ReadonlySet<string> = new Set(),
): ReconcileResult {
  const transcriptPath = join(dir, FILES.transcript);
  if (!existsSync(transcriptPath)) return "bundle-missing";
  const rep = replay(dir);
  if (rep.terminal) return "already-terminal";

  const runId = readManifest(dir).manifest?.runId;
  if (runId && exclude.has(runId)) return "ambiguous";  // 本进程活跃 Run：绝不触碰

  const lease = readLease(dir);
  if (lease && lease.pid !== currentPid && pidAlive(lease.pid)) {
    return "ambiguous";  // 所有权不确定：不动，也不 kill
  }

  // 从已有记录交叉核对 Pi settlement 观测
  const settlement: PiSettlement = { agentEnd: false, agentSettled: false };
  for (const rec of rep.records as TranscriptRecord[]) {
    if (rec.ch !== "stdout" || rec.kind !== "bytes") continue;
    // 只需要 lastStdoutType/agent_end/agent_settled 粗观测；解码按 utf8（Pi stdout 承诺 NDJSON）
    try {
      const line = Buffer.from(rec.bytes.b64, "base64").toString("utf8");
      const obj = JSON.parse(line) as { type?: string };
      observeSettlement(settlement, obj.type);
    } catch { /* 坏行：不影响对账 */ }
  }

  // 未终止尾行：本应"等待更多字节"；旧进程已死，不会有更多字节。
  // 补一个换行把尾行变成完整行（不丢原始字节），并把终止后的字节计入证据 hash——
  // 否则追加 terminal 后，replay 会把该行计入 hash 而与记录值错位（永久 hash-mismatch）。
  // 即：sha = H(当前文件全部字节，尾部补 \n 到行边界)。
  const raw = readFileSync(transcriptPath);
  const sha256 = createHash("sha256")
    .update(raw)
    .update(raw.length > 0 && raw[raw.length - 1] !== 0x0a ? Buffer.from("\n", "utf8") : Buffer.alloc(0))
    .digest("hex");
  const hasPartial = rep.trailingPartial !== null;

  const { manifest } = readManifest(dir);
  const terminal: TerminalInfo = {
    outcome: "incomplete",
    exitCode: null,
    signal: null,
    startedAt: manifest?.createdAt ?? 0,
    endedAt: Date.now(),
    finalSeq: rep.lastSeq + 1,
    stdoutBytes: sumBytes(rep.records, "stdout"),
    stderrBytes: sumBytes(rep.records, "stderr"),
    sawEof: false,
    captureError: reason + (hasPartial ? " (trailing partial line terminated at recovery)" : ""),
    piSettlement: settlement,
    sha256,
  };
  try {
    const prefix = hasPartial ? "\n" : "";  // 先终止尾行
    appendFileSync(transcriptPath, prefix + JSON.stringify({
      v: TRANSCRIPT_SCHEMA_VERSION,
      seq: terminal.finalSeq,
      tUtc: new Date().toISOString(),
      tMono: -1,  // 恢复路径拿不到原始终止时刻的单调时钟读数
      ch: "meta",
      kind: "terminal",
      terminal,
    }) + "\n");
  } catch (e) {
    // 记录失败原因供排查；bundle 维持非终态，下轮对账重试
    process.stderr.write(`[pi-subagent] transcript reconcile failed: ${msg(e)}\n`);
    return "reconcile-failed";
  }
  return "recovered";
}

function sumBytes(records: TranscriptRecord[], ch: "stdout" | "stderr"): number {
  let n = 0;
  for (const rec of records) {
    if (rec.ch === ch && rec.kind === "bytes") n += rec.bytes.byteCount;
  }
  return n;
}
