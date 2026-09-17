// Run Window 启动器（ticket 07）。职责边界：
// - 平台/开关/脚本存在性判定（非 Windows → viewer: unavailable，绝不安装别的 GUI）
// - 每次 Run 一个独立只读窗口：bundle 与首批证据落盘后启动，≤2s ready 握手
// - 同一 Run 只允许一个实例：存活实例收到 focus 请求，确认退出后才允许替换
// - 任何失败都被隔离：绝不 throw，绝不影响 Run 的执行/捕获/返回
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { pidAlive } from "../transcript/recovery.js";
import { readViewerState, requestFocus, type ViewerState } from "./state.js";
import { msg } from "../transcript/writer.js";

// 窗口 ready 握手上限：设计锁定"启动后最多等两秒"，随后无论是否就绪都继续跑 Run
export const VIEWER_READY_WAIT_MS = 2000;
const READY_POLL_MS = 25;

export type ViewerLifecycle = "unavailable" | "none" | "starting" | "ready" | "exited";

export interface ViewerDescription {
  available: boolean;
  state: ViewerLifecycle;
  reason?: string;
  pid?: number;
  token?: string;
  captureIncomplete?: boolean;
  sourceCleaned?: boolean;
  alertAttemptedAt?: number | null;
  lastError?: string;
}

export interface ViewerOpenInput {
  runId: string;
  bundleDir: string;
  waitReadyMs?: number;
}

export interface ViewerOpenResult {
  status: "ready" | "focused" | "starting" | "unavailable" | "failed";
  reason?: string;
  pid?: number;
}

// delegate 只依赖最小接口，status 还需要读取窗口状态；测试可注入替身
export interface ViewerLauncher {
  open(input: ViewerOpenInput): Promise<ViewerOpenResult>;
}

export interface ViewerHandle extends ViewerLauncher {
  describe(bundleDir: string): ViewerDescription;
}

// dist/viewer/manager.js → <repo>/viewer/run-window.ps1（src 与 dist 下相对深度一致）
function defaultScriptPath(): string {
  return resolve(dirname(fileURLToPath(import.meta.url)), "..", "..", "viewer", "run-window.ps1");
}

// 真实 PowerShell 需要 -STA（WinForms）并以参数数组启动，绝不经 shell 插值：
// bundle 路径原样作为一个 argv 元素，不存在引号/空格/元字符转义问题。
// 非 .ps1 脚本按"直接可执行"处理——这是自动化测试用替身查看器替换 PowerShell 的接缝。
export function viewerCommand(
  script: string,
  powershell: string,
  bundleDir: string,
): { command: string; args: string[] } {
  const params = ["-BundleDir", bundleDir];
  if (script.toLowerCase().endsWith(".ps1")) {
    return {
      command: powershell,
      args: ["-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass", "-File", script, ...params],
    };
  }
  return { command: powershell, args: [script, ...params] };
}

export class ViewerManager implements ViewerLauncher {
  private readonly script: string;
  private readonly powershell: string;
  private readonly enabled: boolean;

  constructor(opts: { script?: string; powershell?: string; enabled?: boolean } = {}) {
    this.script = opts.script ?? process.env.PI_SUBAGENT_VIEWER_SCRIPT ?? defaultScriptPath();
    this.powershell = opts.powershell ?? process.env.PI_SUBAGENT_POWERSHELL ?? "powershell.exe";
    this.enabled = opts.enabled ?? process.env.PI_SUBAGENT_VIEWER !== "off";
  }

  get available(): boolean {
    return this.unavailableReason() === undefined;
  }

  unavailableReason(): string | undefined {
    if (!this.enabled) return "disabled by PI_SUBAGENT_VIEWER=off";
    if (process.platform !== "win32") return `viewer is Windows-only (platform ${process.platform})`;
    if (!existsSync(this.script)) return `viewer script not found: ${this.script}`;
    return undefined;
  }

  // pi_status 的 viewer 摘要：状态取自 viewer-state.json + 进程存活复核
  describe(bundleDir: string): ViewerDescription {
    const unavailable = this.unavailableReason();
    if (unavailable) return { available: false, state: "unavailable", reason: unavailable };
    const st = readViewerState(bundleDir);
    if (!st) return { available: true, state: "none" };
    const alive = st.pid !== process.pid && pidAlive(st.pid);
    return {
      available: true,
      state: alive ? (st.state === "ready" ? "ready" : "starting") : "exited",
      pid: st.pid,
      token: st.token,
      captureIncomplete: st.captureIncomplete,
      sourceCleaned: st.sourceCleaned,
      alertAttemptedAt: st.alertAttemptedAt ?? null,
      lastError: st.lastError || undefined,
    };
  }

  // 永不 throw。已有存活实例 → 请求聚焦（不新建）；否则新建实例并做有界 ready 握手。
  async open(input: ViewerOpenInput): Promise<ViewerOpenResult> {
    const unavailable = this.unavailableReason();
    if (unavailable) return { status: "unavailable", reason: unavailable };

    const live = this.liveInstance(input.bundleDir);
    if (live) {
      // 一个 Run 一个窗口：存活实例只被置前，绝不并发第二个。
      requestFocus(input.bundleDir);
      if (live.state === "ready") return { status: "focused", pid: live.pid };
      // 还在启动中：等这个实例自己就绪；它中途死掉才算"确认已退出"，允许替换。
      const deadline = Date.now() + (input.waitReadyMs ?? VIEWER_READY_WAIT_MS);
      const outcome = await this.waitForStatus(input.bundleDir, deadline, (st) => {
        if (!st || st.instanceId !== live.instanceId) return undefined;
        const result = resultForState(st);
        if (result) return result;
        // 状态还停在 starting，但进程已经没了：这是个陈旧状态，不是活的实例
        if (!pidAlive(st.pid)) {
          return { status: "failed", reason: "viewer exited before its ready handshake", pid: st.pid };
        }
        return undefined;
      });
      if (outcome) return outcome;
      if (this.liveInstance(input.bundleDir)) return { status: "starting", pid: live.pid };
      // 实例已确认退出：落下去开替代实例
    }

    const priorInstance = readViewerState(input.bundleDir)?.instanceId;
    let child;
    try {
      const { command, args } = viewerCommand(this.script, this.powershell, input.bundleDir);
      child = spawn(command, args, {
        stdio: "ignore",
        windowsHide: true,
        // Not detached: Windows PowerShell is a console host, and a process
        // created with DETACHED_PROCESS exits silently without running the
        // script at all. The window is therefore a child of the MCP server and
        // lives exactly as long as the server does; while the server runs, a
        // completed window stays open until it is closed by hand.
        detached: false,
      });
    } catch (e) {
      return { status: "failed", reason: `viewer spawn failed: ${msg(e)}` };
    }
    child.unref?.();
    let exited = false;
    let spawnError: string | undefined;
    child.once("error", (e) => { spawnError = msg(e); exited = true; });
    child.once("exit", () => { exited = true; });

    // 只认 instanceId 变化的 ready：启动前的旧状态（上一次实例遗留）不算握手成功
    const deadline = Date.now() + (input.waitReadyMs ?? VIEWER_READY_WAIT_MS);
    const fresh = await this.waitForStatus(
      input.bundleDir,
      deadline,
      (st) => (st && st.instanceId !== priorInstance ? resultForState(st) : undefined),
      () => ({ spawnError, exited, pid: child.pid }),
    );
    if (fresh) return fresh;
    if (spawnError) return { status: "failed", reason: spawnError, pid: child.pid };
    // 超时不中断任何事：窗口可能仍在启动，Run 照常继续
    return { status: "starting", pid: child.pid };
  }

  // 存活且属于本 Run 的实例；本进程自己的 pid 不算（另一个进程才是窗口）
  private liveInstance(bundleDir: string): ViewerState | undefined {
    const st = readViewerState(bundleDir);
    if (!st || st.pid === process.pid) return undefined;
    return pidAlive(st.pid) ? st : undefined;
  }

  // 轮询到 select 给出结论为止；超时返回 undefined（调用方决定后续处理）。
  private async waitForStatus(
    bundleDir: string,
    deadline: number,
    select: (st: ViewerState | undefined) => ViewerOpenResult | undefined,
    childState?: () => { spawnError?: string; exited: boolean; pid?: number },
  ): Promise<ViewerOpenResult | undefined> {
    while (Date.now() < deadline) {
      const outcome = select(readViewerState(bundleDir));
      if (outcome) return outcome;
      if (childState) {
        const { spawnError, exited, pid } = childState();
        if (spawnError) return { status: "failed", reason: spawnError, pid };
        // 新实例在握手前就退出/崩溃：立即报告，不空等整个预算
        if (exited) return { status: "failed", reason: "viewer exited before its ready handshake", pid };
      }
      await sleep(READY_POLL_MS);
    }
    return undefined;
  }
}

function resultForState(st: ViewerState): ViewerOpenResult | undefined {
  if (st.state === "ready") return { status: "ready", pid: st.pid };
  if (st.state === "failed") {
    return { status: "failed", reason: st.lastError ?? "viewer reported failure", pid: st.pid };
  }
  return undefined;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
