// Transcript 存储：根目录管理、bundle 索引、7 天/2GiB 保留清理、崩溃对账。
// 清理只动「终态 + lease 无主或已释放 + rename 成功」的 bundle；任何不确定都跳过。
import { existsSync, lstatSync, mkdirSync, readdirSync, renameSync, rmSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  FILES, QUOTA_BYTES, RETENTION_MS, TRASH_GRACE_MS,
  type PiSettlement, type TranscriptOutcome,
} from "./schema.js";
import { readLease, readManifest, readTerminalTail, replay } from "./reader.js";
import { TranscriptWriter, type BeginInput } from "./writer.js";
import { pidAlive, reconcileStale, type ReconcileResult } from "./recovery.js";

const TRASH_DIR = ".trash";

// 独立可配置的 Transcript 根；与 registry 文件覆盖（PI_SUBAGENT_REGISTRY）无关
export function transcriptRoot(): string {
  const env = process.env.PI_SUBAGENT_TRANSCRIPTS;
  if (env && env.trim()) return env;
  return join(homedir(), ".pi-subagent", "runs");
}

export interface TranscriptDescription {
  available: boolean;
  reason?: string;
  outcome?: TranscriptOutcome;
  captureError?: string;
  // integrity-ok: 终态正常且无捕获错误；capture-error: 有捕获/存储错误；
  // incomplete: 终态为 incomplete；unknown: 未经重放校验
  integrity: "integrity-ok" | "capture-error" | "incomplete" | "unknown";
  // 终态证据（只读尾部，不重放全文件）——仅终态 bundle 才有
  startedAt?: number;
  endedAt?: number;
  piSettlement?: PiSettlement;
}

export interface CleanupReport {
  trashed: string[];
  purged: string[];
  skipped: string[];
  quotaTrashed: string[];
  disabled?: string;
}

export interface RetentionOpts {
  quotaBytes?: number;
  retentionMs?: number;
  trashGraceMs?: number;
}

export class TranscriptStore {
  readonly root: string;
  private disabled: string | undefined;
  private readonly quotaBytes: number;
  private readonly retentionMs: number;
  private readonly trashGraceMs: number;

  constructor(root = transcriptRoot(), opts: RetentionOpts = {}) {
    this.root = root;
    this.quotaBytes = opts.quotaBytes ?? QUOTA_BYTES;
    this.retentionMs = opts.retentionMs ?? RETENTION_MS;
    this.trashGraceMs = opts.trashGraceMs ?? TRASH_GRACE_MS;
    try {
      mkdirSync(root, { recursive: true });
      // Transcript 根必须是真实目录（非 reparse point），让 Windows ACL 继承生效
      const st = lstatSync(root);
      if (st.isSymbolicLink()) {
        this.disabled = `transcript root is a reparse point: ${root}`;
      }
    } catch (e) {
      this.disabled = `transcript root unusable: ${e instanceof Error ? e.message : String(e)}`;
    }
  }

  get disabledReason(): string | undefined {
    return this.disabled;
  }

  dir(runId: string): string {
    return join(this.root, runId);
  }

  // 可以读写的 bundle 目录；存储被禁用（根不可用/是 reparse point）时没有可用证据。
  // Run Window 与 pi_status 用它决定是否提供 / 描述该 Run 的证据面。
  usableDir(runId: string): string | undefined {
    return this.disabled ? undefined : this.dir(runId);
  }

  // 永不 throw；存储不可用时返回 broken writer（不触碰 fs），调用方照常跑 Run
  begin(input: BeginInput): TranscriptWriter {
    if (this.disabled) return TranscriptWriter.brokenInstance(this.disabled);
    return TranscriptWriter.create(this.dir(input.runId), input);
  }

  // pi_status 的 Transcript 可用性/完整性摘要（不重放整个文件）
  describe(runId: string): TranscriptDescription {
    if (this.disabled) return { available: false, reason: this.disabled, integrity: "unknown" };
    const dir = this.dir(runId);
    if (!existsSync(join(dir, FILES.manifest))) {
      return { available: false, reason: "no-bundle", integrity: "unknown" };
    }
    const { manifest, reason } = readManifest(dir);
    if (!manifest) return { available: true, reason, integrity: "unknown" };
    if (!manifest.terminal) return { available: true, outcome: "running", integrity: "unknown" };
    // 终态证据从文件尾部读取（不重放整个 transcript）
    const terminal = readTerminalTail(dir);
    const evidence = terminal
      ? { startedAt: terminal.startedAt, endedAt: terminal.endedAt, piSettlement: terminal.piSettlement }
      : {};
    if (manifest.terminal.outcome === "incomplete") {
      return {
        available: true, outcome: "incomplete",
        captureError: manifest.terminal.captureError, integrity: "incomplete", ...evidence,
      };
    }
    return {
      available: true,
      outcome: manifest.terminal.outcome,
      captureError: manifest.terminal.captureError,
      integrity: manifest.terminal.captureError ? "capture-error" : "integrity-ok",
      ...evidence,
    };
  }

  // 全量重放校验（viewer/replay 用；status 不走这条路）
  replayRun(runId: string) {
    return replay(this.dir(runId));
  }

  // 崩溃对账：非终态 bundle，旧进程确认不存在 → 补 incomplete 终态；不确定 → 跳过。
  // exclude 必须传本进程仍活跃的 runId（活 Run 的 bundle 由 writer 独占写，绝不触碰）。
  reconcile(exclude: Iterable<string> = []): { runId: string; result: ReconcileResult }[] {
    if (this.disabled) return [];
    const out: { runId: string; result: ReconcileResult }[] = [];
    const active = new Set(exclude);
    for (const runId of this.bundleIds()) {
      const r = reconcileStale(this.dir(runId), process.pid, "host restart: run was nonterminal at recovery", active);
      out.push({ runId, result: r });
    }
    return out;
  }

  // 保留清理：7 天过期 + 2GiB 配额；trash 计入配额；活动/所有权不明 bundle 永不自动删
  cleanup(now = Date.now()): CleanupReport {
    const report: CleanupReport = { trashed: [], purged: [], skipped: [], quotaTrashed: [] };
    if (this.disabled) {
      report.disabled = this.disabled;
      return report;
    }
    const trashDir = join(this.root, TRASH_DIR);

    // 1) 过期 trash 物理删除
    if (existsSync(trashDir)) {
      for (const name of listDirs(trashDir)) {
        const p = join(trashDir, name);
        try {
          if (now - statSync(p).mtimeMs > this.trashGraceMs) {
            rmSync(p, { recursive: true, force: true });
            report.purged.push(name);
          }
        } catch { report.skipped.push(name); }
      }
    }

    // 2) 终态 + 无主/已释放 bundle：超期 → trash
    for (const runId of this.bundleIds()) {
      const dir = this.dir(runId);
      try {
        if (!this.isRetirable(runId, now)) continue;
        this.trash(runId, now, report, "trashed");
      } catch { report.skipped.push(runId); }
    }

    // 3) 配额：总量（含 trash）> 2GiB → 最旧优先 trash；仍超 → 最旧 trash 物理删除
    let total = totalBytes(this.root);
    if (total > this.quotaBytes) {
      const candidates = this.cleanableByAge();
      for (const runId of candidates) {
        if (total <= this.quotaBytes) break;
        const before = dirSize(this.dir(runId));
        if (this.trash(runId, now, report, "quotaTrashed")) {
          total -= before;
        }
      }
      // 全部剩余 bundle 都不可删（活动/不明）→ 只能删 trash 腾位
      while (total > this.quotaBytes) {
        const oldest = oldestTrashEntry(trashDir);
        if (!oldest) break;
        const p = join(trashDir, oldest);
        const size = dirSize(p);
        try {
          rmSync(p, { recursive: true, force: true });
          report.purged.push(oldest);
          total -= size;
        } catch {
          report.skipped.push(oldest);
          break;
        }
      }
    }
    return report;
  }

  // ===== 内部 =====

  private bundleIds(): string[] {
    if (!existsSync(this.root)) return [];
    return listDirs(this.root).filter((name) => name !== TRASH_DIR);
  }

  // 可清理 = manifest 声明终态 +（lease 缺失/已释放/旧进程确认不在/就是本进程）+ 超过保留期。
  // 目录锁由「原子 trash 改名」本身充当：目录被占用/锁定时 rename 失败 → 记 skipped 跳过。
  private isRetirable(runId: string, now: number): boolean {
    return this.isCleanable(runId) && now - this.terminalEndedAt(runId) > this.retentionMs;
  }

  // 所有权检查（不含保留期）：终态 + lease 无主/已释放。过期清理与配额清理共用，
  // 所有权不明（lease 指向存活且非本进程的持有者）的 bundle 一律排除。
  private isCleanable(runId: string): boolean {
    const { manifest } = readManifest(this.dir(runId));
    if (!manifest?.terminal) return false;
    const lease = readLease(this.dir(runId));
    if (lease && !lease.released && lease.pid !== process.pid && pidAlive(lease.pid)) {
      return false;  // 所有权不明：跳过，不自动删
    }
    return true;
  }

  private terminalEndedAt(runId: string): number {
    return readManifest(this.dir(runId)).manifest?.terminal?.endedAt ?? 0;
  }

  // 配额候选：可清理（终态+无主）的 bundle 按终态时间最旧优先
  private cleanableByAge(): string[] {
    const dirs: { runId: string; endedAt: number }[] = [];
    for (const runId of this.bundleIds()) {
      if (this.isCleanable(runId)) dirs.push({ runId, endedAt: this.terminalEndedAt(runId) });
    }
    dirs.sort((a, b) => a.endedAt - b.endedAt);
    return dirs.map((d) => d.runId);
  }

  // reason 决定报告归类：过期清理 → trashed；配额清理 → quotaTrashed
  private trash(runId: string, now: number, report: CleanupReport, reason: "trashed" | "quotaTrashed"): boolean {
    const dir = this.dir(runId);
    const trashDir = join(this.root, TRASH_DIR);
    mkdirSync(trashDir, { recursive: true });
    try {
      renameSync(dir, join(trashDir, `${runId}.${now}`));  // 原子 trash 改名
      report[reason].push(runId);
      return true;
    } catch {
      report.skipped.push(runId);  // rename 失败（目录被占用/锁定）→ 跳过
      return false;
    }
  }
}

function listDirs(dir: string): string[] {
  try {
    return readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => e.name);
  } catch {
    return [];
  }
}

function dirSize(p: string): number {
  let total = 0;
  let entries;
  try {
    entries = readdirSync(p, { withFileTypes: true });
  } catch {
    return 0;
  }
  for (const e of entries) {
    const full = join(p, e.name);
    if (e.isDirectory()) total += dirSize(full);
    else {
      try { total += statSync(full).size; } catch { /* 消失的文件按 0 计 */ }
    }
  }
  return total;
}

function totalBytes(root: string): number {
  let total = 0;
  for (const name of listDirs(root)) {
    total += dirSize(join(root, name));
  }
  return total;
}

function oldestTrashEntry(trashDir: string): string | undefined {
  const names = listDirs(trashDir);
  if (names.length === 0) return undefined;
  return names.sort().at(0);  // 名字含 trashed 时间戳，字典序=时间序
}
