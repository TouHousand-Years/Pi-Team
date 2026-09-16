// Transcript 写入器：单写者、append-only、失败隔离。
// 所有 fs 操作都吞错并降级为 capture-error 状态——存储故障绝不影响 Run 本身。
import { createHash, randomUUID } from "node:crypto";
import {
  closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, writeFileSync, writeSync,
} from "node:fs";
import { join } from "node:path";
import { performance } from "node:perf_hooks";
import {
  CHUNK_BYTES, FILES, FLUSH_INTERVAL_MS, FLUSH_PENDING_BYTES, TRANSCRIPT_SCHEMA_VERSION,
  type ByteChunk, type LaunchMeta, type PiSettlement, type TerminalInfo,
  type TranscriptLease, type TranscriptManifest, type RecordPayload, type TranscriptRecord,
} from "./schema.js";

export interface BeginInput {
  runId: string;
  session: string;
  cwd: string;
  promptSubmitted: string;
  promptEffective: string;
  constraints?: Record<string, unknown>;
  sessionId?: string;
}

export interface FinalizeInput {
  outcome: TerminalInfo["outcome"];
  exitCode: number | null;
  signal: string | null;
  startedAt: number;
  endedAt: number;
  sawEof: boolean;
  piSettlement: PiSettlement;
}

// 原子写：tmp + rename（同目录，保证同盘）
function atomicWriteJson(path: string, value: unknown): void {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(value));
  renameSync(tmp, path);
}

export class TranscriptWriter {
  private seq = 0;
  private hash = createHash("sha256");
  private pending: Buffer[] = [];
  private pendingBytes = 0;
  private timer: NodeJS.Timeout | undefined;
  private fd: number | null = null;
  private closed = false;
  private broken = false;
  private firstError: string | undefined;
  private stdoutBytes = 0;
  private stderrBytes = 0;
  private chunkGroupCounter = 0;
  private manifest: TranscriptManifest;

  private constructor(
    readonly dir: string,
    manifest: TranscriptManifest,
  ) {
    this.manifest = manifest;
  }

  // 存储不可用时的占位 writer：不触碰 fs，所有调用安全 no-op
  static brokenInstance(reason: string): TranscriptWriter {
    const w = new TranscriptWriter("", {
      version: TRANSCRIPT_SCHEMA_VERSION, runId: "", session: "", createdAt: 0,
    });
    w.break(reason);
    return w;
  }

  // 永不 throw：初始化失败 → broken writer（captureError 语义保留在内存）
  static create(dir: string, input: BeginInput): TranscriptWriter {
    const manifest: TranscriptManifest = {
      version: TRANSCRIPT_SCHEMA_VERSION,
      runId: input.runId,
      session: input.session,
      createdAt: Date.now(),
    };
    const w = new TranscriptWriter(dir, manifest);
    try {
      mkdirSync(dir, { recursive: true });
      atomicWriteJson(join(dir, FILES.manifest), manifest);
      const lease: TranscriptLease = {
        runId: input.runId,
        pid: process.pid,
        leaseId: randomUUID(),
        createdAt: Date.now(),
      };
      atomicWriteJson(join(dir, FILES.lease), lease);
      w.fd = openSync(join(dir, FILES.transcript), "a");
    } catch (e) {
      w.break(`bundle init failed: ${msg(e)}`);
      return w;
    }
    const launch: LaunchMeta = {
      promptSubmitted: input.promptSubmitted,
      promptEffective: input.promptEffective,
      cwd: input.cwd,
      sessionId: input.sessionId,
      constraints: input.constraints,
      stdin: "none",
    };
    w.emit({ ch: "meta", kind: "launch", launch }, true);
    w.startTimer();
    return w;
  }

  get captureFailed(): boolean {
    return this.broken;
  }

  stdoutData(buf: Buffer): void {
    this.byteData("stdout", buf);
  }

  stderrData(buf: Buffer): void {
    this.byteData("stderr", buf);
  }

  stdinData(buf: Buffer): void {
    this.byteData("stdin", buf);
  }

  // 状态迁移（强制落盘）
  state(state: string, detail?: string): void {
    this.emit({ ch: "meta", kind: "state", state, detail }, true);
  }

  // 捕获/存储层错误记录（强制落盘，best-effort）
  captureError(error: string): void {
    if (!this.firstError) this.firstError = error;
    this.emit({ ch: "meta", kind: "capture-error", error }, true);
  }

  // 终态记录 + manifest 摘要 + lease 释放；sha256 覆盖 terminal 之前的全部序列化字节
  finalize(input: FinalizeInput): void {
    if (this.closed) return;
    this.flush(true);
    const sha256 = this.broken ? "" : this.hash.copy().digest("hex");
    const seq = this.seq + 1;
    const terminal: TerminalInfo = {
      outcome: input.outcome,
      exitCode: input.exitCode,
      signal: input.signal,
      startedAt: input.startedAt,
      endedAt: input.endedAt,
      finalSeq: seq,
      stdoutBytes: this.stdoutBytes,
      stderrBytes: this.stderrBytes,
      sawEof: input.sawEof,
      captureError: this.firstError,
      piSettlement: input.piSettlement,
      sha256,
    };
    this.emit({ ch: "meta", kind: "terminal", terminal }, true);
    this.closed = true;
    if (this.timer) clearTimeout(this.timer);
    this.closeFd();
    if (this.broken) return;
    try {
      atomicWriteJson(join(this.dir, FILES.manifest), {
        ...this.manifest,
        finalizedAt: Date.now(),
        terminal: {
          outcome: terminal.outcome,
          endedAt: terminal.endedAt,
          finalSeq: terminal.finalSeq,
          sha256: terminal.sha256,
          captureError: terminal.captureError,
        },
      });
      // lease 释放失败不影响证据（终态记录已是权威）
      try {
        const lease = JSON.parse(readFileSync(join(this.dir, FILES.lease), "utf8")) as TranscriptLease;
        atomicWriteJson(join(this.dir, FILES.lease), { ...lease, released: true });
      } catch { /* 无 lease 或已损坏则跳过 */ }
    } catch (e) {
      if (!this.firstError) this.firstError = `manifest update failed: ${msg(e)}`;
    }
  }

  // ===== 内部 =====

  private byteData(ch: "stdout" | "stderr" | "stdin", buf: Buffer): void {
    if (buf.length === 0) return;
    if (ch === "stdout") this.stdoutBytes += buf.length;
    if (ch === "stderr") this.stderrBytes += buf.length;
    const groupId = `${ch}-${++this.chunkGroupCounter}`;
    const parts = Math.ceil(buf.length / CHUNK_BYTES);
    for (let i = 0; i < parts; i++) {
      const piece = buf.subarray(i * CHUNK_BYTES, Math.min((i + 1) * CHUNK_BYTES, buf.length));
      const chunk: ByteChunk = {
        b64: piece.toString("base64"),
        groupId,
        part: i + 1,
        final: i === parts - 1,
        byteCount: piece.length,
      };
      this.emit({ ch, kind: "bytes", bytes: chunk }, false);
    }
  }

  private emit(rec: RecordPayload, forced: boolean): void {
    if (this.closed || this.broken) return;
    const record = {
      v: TRANSCRIPT_SCHEMA_VERSION,
      seq: ++this.seq,
      tUtc: new Date().toISOString(),
      tMono: performance.now(),
      ...rec,
    } as TranscriptRecord;
    const line = Buffer.from(JSON.stringify(record) + "\n", "utf8");
    this.hash.update(line);  // terminal 之后不再有记录，提前计入无害
    this.pending.push(line);
    this.pendingBytes += line.length;
    if (forced) {
      this.flush(true);
    } else if (this.pendingBytes >= FLUSH_PENDING_BYTES) {
      this.flush(false);
    }
  }

  // forced=true 时 fsync（启动/捕获错误/状态迁移/终态）
  private flush(forced: boolean): void {
    if (this.broken || this.pending.length === 0) return;
    const data = Buffer.concat(this.pending);
    this.pending = [];
    this.pendingBytes = 0;
    try {
      if (this.fd === null) throw new Error("transcript fd not open");
      let off = 0;
      while (off < data.length) {
        off += writeSync(this.fd, data, off, data.length - off);
      }
      if (forced) fsyncSync(this.fd);
    } catch (e) {
      this.break(`write failed: ${msg(e)}`);
    }
  }

  private startTimer(): void {
    this.timer = setInterval(() => this.flush(false), FLUSH_INTERVAL_MS);
    this.timer.unref?.();
  }

  private closeFd(): void {
    if (this.fd !== null) {
      try { closeSync(this.fd); } catch { /* 已关闭 */ }
      this.fd = null;
    }
  }

  private break(reason: string): void {
    this.broken = true;
    if (!this.firstError) this.firstError = reason;
    this.pending = [];
    this.pendingBytes = 0;
    if (this.timer) clearTimeout(this.timer);
    this.closeFd();
  }
}

export function msg(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
