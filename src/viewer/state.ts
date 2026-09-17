// 查看器 seam 文件（非证据）：viewer-state.json 记录窗口自身状态与一次性提示音记账，
// viewer-request.json 由 host 写入、窗口消费（置前/聚焦）。两者都不参与证据 hash，
// 也不被 replay()/完整性检查读取。
import { existsSync, renameSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export const VIEWER_STATE_FILE = "viewer-state.json";
export const VIEWER_REQUEST_FILE = "viewer-request.json";

export interface ViewerState {
  runId: string;
  instanceId: string;
  pid: number;
  startedAt: number;
  updatedAt: number;
  state: "starting" | "ready" | "exited" | "failed";
  outcome?: string | null;
  token?: string;
  captureIncomplete?: boolean;
  // 一次性提示音记账（attempt 语义，不声称"已听到"）；非空即不再重放
  alertAttemptedAt?: number | null;
  sourceCleaned?: boolean;
  lastError?: string;
}

export function viewerStatePath(bundleDir: string): string {
  return join(bundleDir, VIEWER_STATE_FILE);
}

export function readViewerState(bundleDir: string): ViewerState | undefined {
  const path = viewerStatePath(bundleDir);
  if (!existsSync(path)) return undefined;
  try {
    return JSON.parse(readFileSync(path, "utf8")) as ViewerState;
  } catch {
    return undefined;
  }
}

// 原子请求聚焦：窗口每次 tick 检查该文件并删除它。
// 失败（bundle 已被清理等）不抛出——聚焦是尽力而为。
export function requestFocus(bundleDir: string, now = Date.now()): void {
  const path = join(bundleDir, VIEWER_REQUEST_FILE);
  try {
    const tmp = `${path}.tmp`;
    writeFileSync(tmp, JSON.stringify({ focusAt: now }));
    renameSync(tmp, path);
  } catch { /* 尽力而为 */ }
}

export function viewerRequestPath(bundleDir: string): string {
  return join(bundleDir, VIEWER_REQUEST_FILE);
}
