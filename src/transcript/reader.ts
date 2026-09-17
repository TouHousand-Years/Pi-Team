// Transcript 读取/重放：无损语义。坏行、未知版本、未来 kind 全部保留原样可见；
// 只有 seq 空洞、hash 不匹配、缺 terminal、未终止尾行才标记完整性受损。
// hash 覆盖 terminal 记录之前的全部「以 \n 结尾的完整行」字节；未终止尾行不计入 hash，
// 单独以 trailingPartial 报告（等待更多字节的语义；终态 bundle 上即截断证据）。
import { createHash } from "node:crypto";
import { closeSync, existsSync, fstatSync, openSync, readFileSync, readSync } from "node:fs";
import { join } from "node:path";
import {
  FILES, TRANSCRIPT_SCHEMA_VERSION,
  type TerminalInfo, type TranscriptRecord,
} from "./schema.js";

export interface MalformedRecord {
  index: number;        // 0 起始的文件行号
  raw: string;
  reason: string;
}

export interface ReplayResult {
  records: TranscriptRecord[];       // 可解析记录（按 seq；不含 terminal）
  terminal: TerminalInfo | null;
  malformed: MalformedRecord[];      // 保留原始行，无损可见，不算完整性受损
  trailingPartial: string | null;    // 未以 \n 结尾的尾行
  // terminal 之前全部完整行的 sha256（recovery 追加终态时复用）
  hashBeforeTerminal: string;
  lastSeq: number;
  integrity: { ok: boolean; reasons: string[] };
}

export function replay(dir: string): ReplayResult {
  const path = join(dir, FILES.transcript);
  const base: ReplayResult = {
    records: [],
    terminal: null,
    malformed: [],
    trailingPartial: null,
    hashBeforeTerminal: "",
    lastSeq: 0,
    integrity: { ok: true, reasons: [] },
  };
  if (!existsSync(path)) {
    base.integrity = { ok: false, reasons: ["transcript-missing"] };
    return base;
  }

  const raw = readFileSync(path);
  const text = raw.toString("utf8");
  const hash = createHash("sha256");
  let sawTerminal = false;
  let expectedSeq = 1;
  const lines = text.split("\n");
  // 文件以 \n 结束 → split 尾部的空串是切分产物，不是空行，必须丢掉；
  // 否则它会被当作空行计入 hash，且追加 terminal 后 hash 基准变化（恢复路径错位）。
  let trailingPartial: string | null = null;
  if (text.endsWith("\n")) {
    lines.pop();
  } else if (lines.length > 0) {
    trailingPartial = lines.pop() ?? null;
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (sawTerminal) continue;  // terminal 之后的行（不应出现）不参与 hash/记录
    // 先识别 terminal：hash 只覆盖 terminal 之前的字节
    let rec: TranscriptRecord | null = null;
    try {
      rec = JSON.parse(line) as TranscriptRecord;
    } catch { /* 坏行：仍计入 hash（它是 terminal 之前的序列化字节） */ }
    if (rec && rec.kind === "terminal" && rec.ch === "meta" && rec.v === TRANSCRIPT_SCHEMA_VERSION) {
      sawTerminal = true;
      base.terminal = rec.terminal;
      continue;
    }
    hash.update(Buffer.from(line + "\n", "utf8"));
    if (line === "") continue;  // 空行：计入 hash 但不是记录
    if (!rec) {
      base.malformed.push({ index: i, raw: line, reason: "json-parse-failed" });
      continue;
    }
    if (rec?.v !== TRANSCRIPT_SCHEMA_VERSION || typeof rec.seq !== "number") {
      base.malformed.push({ index: i, raw: line, reason: "schema-envelope-invalid" });
      continue;
    }
    if (rec.seq !== expectedSeq) {
      base.integrity.reasons.push(`sequence-gap: expected ${expectedSeq}, got ${rec.seq} (line ${i})`);
    }
    expectedSeq = rec.seq + 1;
    base.lastSeq = rec.seq;
    base.records.push(rec);
  }

  base.hashBeforeTerminal = hash.digest("hex");
  base.trailingPartial = trailingPartial;

  if (base.terminal) {
    if (base.terminal.sha256 && base.terminal.sha256 !== base.hashBeforeTerminal) {
      base.integrity.reasons.push("terminal-hash-mismatch");
    }
    if (base.terminal.finalSeq !== base.lastSeq + 1) {
      base.integrity.reasons.push(
        `terminal-final-seq-mismatch: terminal says ${base.terminal.finalSeq}, last record seq ${base.lastSeq}`,
      );
    }
  } else {
    base.integrity.reasons.push("no-terminal-record");
  }
  if (trailingPartial !== null) {
    base.integrity.reasons.push("trailing-partial-line");
  }
  base.integrity.ok = base.integrity.reasons.length === 0;
  return base;
}

// ===== manifest / lease =====

export interface ManifestRead {
  manifest?: import("./schema.js").TranscriptManifest;
  reason?: string;
}

export function readManifest(dir: string): ManifestRead {
  const path = join(dir, FILES.manifest);
  if (!existsSync(path)) return { reason: "manifest-missing" };
  try {
    return { manifest: JSON.parse(readFileSync(path, "utf8")) };
  } catch (e) {
    return { reason: `manifest-unreadable: ${e instanceof Error ? e.message : String(e)}` };
  }
}

export function readLease(dir: string): import("./schema.js").TranscriptLease | undefined {
  const path = join(dir, FILES.lease);
  if (!existsSync(path)) return undefined;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return undefined;
  }
}

// 只读文件尾部取终态证据（pi_status 用：不重放整个 transcript）。
// 尾部窗口的第一行可能是被切断的半行，解析失败即跳过——终态记录总是文件的最后一行。
export function readTerminalTail(dir: string, maxBytes = 256 * 1024): TerminalInfo | undefined {
  const path = join(dir, FILES.transcript);
  if (!existsSync(path)) return undefined;
  let fd: number | undefined;
  try {
    fd = openSync(path, "r");
    const size = fstatSync(fd).size;
    const start = size > maxBytes ? size - maxBytes : 0;
    const buf = Buffer.alloc(Number(size - start));
    if (buf.length > 0) readSync(fd, buf, 0, buf.length, start);
    const lines = buf.toString("utf8").split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i];
      if (!line) continue;
      try {
        const rec = JSON.parse(line) as TranscriptRecord;
        if (rec.v === TRANSCRIPT_SCHEMA_VERSION && rec.ch === "meta" && rec.kind === "terminal") {
          return rec.terminal;
        }
      } catch { /* 半行或坏行：继续向前找 */ }
    }
    return undefined;
  } catch {
    return undefined;
  } finally {
    if (fd !== undefined) { try { closeSync(fd); } catch { /* 已关闭 */ } }
  }
}
