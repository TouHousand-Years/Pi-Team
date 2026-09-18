import type { RunRegistry } from "../registry/run.js";
import type { TranscriptStore, TranscriptDescription } from "../transcript/store.js";
import type { ViewerHandle, ViewerDescription } from "../viewer/manager.js";
import { Errors } from "../errors.js";

export interface StatusInput {
  runId: string;
  waitTimeoutMs?: number;
  // 重新打开该 Run 的 Run Window（聚焦存活实例，或在其确认退出后新建）。
  // 绝不重派工作、绝不重放提示音，也不改变 Run 的状态。
  openWindow?: boolean;
}

export interface StatusOutput {
  runId: string;
  session?: string;
  status: string;
  result?: string;
  progress?: any[];
  progressTruncated?: boolean;
  usage?: any;
  error?: any;
  // 时间线（wrapper 权威）
  timing?: { startedAt?: number; endedAt?: number };
  // Transcript 可用性/完整性摘要（无存储时不带该字段——向后兼容）
  transcript?: TranscriptDescription;
  // Run Window 状态（platform/viewer 不可用时不带该字段）
  viewer?: ViewerDescription;
}

export interface StatusDeps {
  runs: RunRegistry;
  transcripts?: TranscriptStore;
  viewer?: ViewerHandle;
}

function timingOf(run: { startedAt?: number; endedAt?: number }): { startedAt?: number; endedAt?: number } {
  return { startedAt: run.startedAt, endedAt: run.endedAt };
}

export async function status(input: StatusInput, deps: StatusDeps): Promise<StatusOutput> {
  const { runs, transcripts, viewer } = deps;

  const existing = runs.get(input.runId);
  if (!existing && runs.isExpired(input.runId)) throw Errors.runExpired(input.runId);
  if (!existing) throw Errors.notFound(`run ${input.runId}`);

  // 重开窗口在长轮询之前：窗口应与 Run 并行可见。
  // transcripts 不可用（存储被禁用/无 bundle）时不提供窗口。
  const bundleDir = transcripts?.usableDir(input.runId);
  if (input.openWindow && viewer && bundleDir) {
    try {
      await viewer.open({ runId: input.runId, bundleDir });
    } catch { /* 隔离：窗口失败不影响 status 返回 */ }
  }
  // 每次读取都取最新状态：长轮询期间窗口可能刚好完成了终态迁移
  const describeViewer = (): ViewerDescription | undefined => (viewer && bundleDir ? viewer.describe(bundleDir) : undefined);
  const viewerState = describeViewer();

  // 已完成/不存在：立即返回
  if (existing.status !== "running") {
    return {
      runId: input.runId,
      session: existing.session,
      status: existing.status,
      result: existing.result,
      progress: existing.progress,
      progressTruncated: existing.progressTruncated,
      usage: existing.usage,
      error: existing.error,
      timing: timingOf(existing),
      transcript: transcripts?.describe(input.runId),
      viewer: viewerState,
    };
  }

  // long-poll：waitTimeoutMs 默认 25000（低于 host 工具调用硬超时 30s，确保 host 不掐断）
  // 传 0 → 立即返回当前 running（纯轮询）
  const waitMs = input.waitTimeoutMs ?? 25000;
  if (waitMs === 0) {
    return {
      runId: input.runId, session: existing.session, status: "running",
      timing: timingOf(existing), viewer: viewerState,
      transcript: transcripts?.describe(input.runId),
    };
  }
  const run = await runs.waitForCompletion(input.runId, waitMs);
  if (!run) {
    return {
      runId: input.runId, session: existing.session, status: "running",
      timing: timingOf(existing), viewer: describeViewer(),
      transcript: transcripts?.describe(input.runId),
    };
  }
  return {
    runId: input.runId,
    session: run.session,
    status: run.status,
    result: run.result,
    progress: run.progress,
    progressTruncated: run.progressTruncated,
    usage: run.usage,
    error: run.error,
    timing: timingOf(run),
    transcript: transcripts?.describe(input.runId),
    viewer: describeViewer(),
  };
}
