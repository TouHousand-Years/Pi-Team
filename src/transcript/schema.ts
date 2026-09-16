// ===== Transcript schema v1（ticket 04 锁定的证据边界）=====
// 单写者、版本化 JSONL 信封：全局 seq、UTC + 单调时间、通道/种类、Base64 边界字节。
// 解码与语义格式化在证据层之外（viewer，ticket 07）。schema v1 冻结，无旧版迁移。

export const TRANSCRIPT_SCHEMA_VERSION = 1;

// 普通记录有界缓冲：最多 250ms 或 64KiB 刷一次；边界记录（启动/捕获错误/状态迁移/终态）强制落盘
export const FLUSH_INTERVAL_MS = 250;
export const FLUSH_PENDING_BYTES = 64 * 1024;
// 原始字节负载分块上限，携带 groupId/part/final 供逻辑重组
export const CHUNK_BYTES = 64 * 1024;
// 保留策略：非活动终态 bundle 7 天后清理，之后最旧优先压到 2GiB（含 trash）
export const RETENTION_MS = 7 * 24 * 3600 * 1000;
export const QUOTA_BYTES = 2 * 1024 * 1024 * 1024;
export const CLEANUP_INTERVAL_MS = 15 * 60 * 1000;
// trash 目录里的 bundle 在此宽限期后物理删除
export const TRASH_GRACE_MS = 24 * 3600 * 1000;

export type TranscriptChannel = "meta" | "stdout" | "stderr" | "stdin";

// 终态：wrapper 是权威；Pi settlement 事件只是语义交叉核对
export type TranscriptOutcome = "running" | "succeeded" | "failed" | "protocol-error" | "incomplete";

export interface ByteChunk {
  b64: string;        // 原始边界字节（Base64）
  groupId: string;    // 逻辑重组键（同一连续字节流的一段）
  part: number;       // 1 起始
  final: boolean;     // 末块标记
  byteCount: number;  // 本块原始字节数
}

// 只记 allowlist 启动元数据：不记原始命令行与环境变量
export interface LaunchMeta {
  promptSubmitted: string;   // host 提交的 prompt
  promptEffective: string;   // 实际进入 argv 的 prompt
  cwd: string;
  sessionId?: string;        // 续接时的 Pi session id
  constraints?: Record<string, unknown>;
  stdin: "none" | "follow-up";  // spawn 为 stdio ignore；后续 stdin 字节才有值
}

export interface PiSettlement {
  agentEnd: boolean;
  agentSettled: boolean;
  lastStdoutType?: string;   // 最后一条可识别的 stdout 事件 type（交叉核对用）
}

// settlement 观测累加（delegate 捕获路径与 recovery 重放路径共用同一规则）
export function observeSettlement(s: PiSettlement, type: string | undefined): void {
  if (!type) return;
  s.lastStdoutType = type;
  if (type === "agent_end") s.agentEnd = true;
  if (type === "agent_settled") s.agentSettled = true;
}

// 终态记录负载；sha256 覆盖 terminal 记录之前的全部序列化字节
export interface TerminalInfo {
  outcome: Exclude<TranscriptOutcome, "running">;
  exitCode: number | null;
  signal: string | null;
  startedAt: number;
  endedAt: number;
  finalSeq: number;          // terminal 记录自身的 seq
  stdoutBytes: number;
  stderrBytes: number;
  sawEof: boolean;           // 流正常关闭（spawn 失败/流销毁为 false）
  captureError?: string;     // 捕获/存储层首个错误
  piSettlement: PiSettlement;
  sha256: string;
}

interface RecordBase {
  v: typeof TRANSCRIPT_SCHEMA_VERSION;
  seq: number;               // 全局序号，1 起始，无空洞（空洞=完整性受损）
  tUtc: string;              // ISO UTC
  tMono: number;             // performance.now() 毫秒，单调
  ch: TranscriptChannel;
}

export type TranscriptRecord =
  | (RecordBase & { ch: "meta"; kind: "launch"; launch: LaunchMeta })
  | (RecordBase & { ch: "meta"; kind: "state"; state: string; detail?: string })
  | (RecordBase & { ch: "meta"; kind: "capture-error"; error: string })
  | (RecordBase & { ch: "meta"; kind: "terminal"; terminal: TerminalInfo })
  | (RecordBase & { ch: "stdout" | "stderr" | "stdin"; kind: "bytes"; bytes: ByteChunk });

// 信封字段由写入器填充；载荷部分（分发型 Omit，保留联合）由调用方给
export type RecordPayload = DistributiveOmit<TranscriptRecord, "v" | "seq" | "tUtc" | "tMono">;

// ===== bundle 文件 =====

export interface TranscriptManifest {
  version: typeof TRANSCRIPT_SCHEMA_VERSION;
  runId: string;
  session: string;
  createdAt: number;
  finalizedAt?: number;
  // 终态摘要（原子更新）；证据本体在 transcript.jsonl
  terminal?: {
    outcome: TerminalInfo["outcome"];
    endedAt: number;
    finalSeq: number;
    sha256: string;
    captureError?: string;
  };
}

export interface TranscriptLease {
  runId: string;
  pid: number;
  leaseId: string;
  createdAt: number;
  released?: boolean;
}

export const FILES = {
  manifest: "manifest.json",
  transcript: "transcript.jsonl",
  lease: "lease.json",
  // viewer-state.json 为非证据文件（ticket 07），不参与证据 hash
} as const;

type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never;

export function transcriptDir(root: string, runId: string): string {
  return `${root}/${runId}`;
}
