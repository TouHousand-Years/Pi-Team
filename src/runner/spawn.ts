import { spawn, type ChildProcess } from "node:child_process";
import { StringDecoder } from "node:string_decoder";
import { buildDelegateArgs, buildForkArgs } from "./argv.js";
import type { Constraints } from "../types.js";

const DEFAULT_PI_BIN = "pi";

// PI_BIN 可含参数（空格拆分），便于测试用 "bash /path/to/fake-pi.sh" 绕开可执行权限
function piBinParts(): { cmd: string; extraArgs: string[] } {
  const bin = process.env.PI_BIN ?? DEFAULT_PI_BIN;
  const parts = bin.split(/\s+/).filter(Boolean);
  return { cmd: parts[0], extraArgs: parts.slice(1) };
}

export interface SpawnedDelegate {
  child: ChildProcess;
}

export function spawnDelegate(opts: {
  prompt: string;
  sessionId?: string;
  constraints: Constraints;
  cwd: string;
}): SpawnedDelegate {
  const { cmd, extraArgs } = piBinParts();
  const args = [...extraArgs, ...buildDelegateArgs({
    prompt: opts.prompt,
    sessionId: opts.sessionId,
    constraints: opts.constraints,
  })];
  const child = spawn(cmd, args, { cwd: opts.cwd, stdio: ["ignore", "pipe", "pipe"] });
  return { child };
}

export function spawnFork(opts: { sourceSessionId: string; cwd: string }): ChildProcess {
  const { cmd, extraArgs } = piBinParts();
  const args = [...extraArgs, ...buildForkArgs(opts.sourceSessionId)];
  return spawn(cmd, args, { cwd: opts.cwd, stdio: ["ignore", "pipe", "pipe"] });
}

export interface CollectResult {
  lines: string[];
  stderrTail: string;
  exitCode: number | null;
  signal: NodeJS.Signals | null;
  spawnError?: Error;   // spawn 失败（如 PI_BIN 不存在）
  sawEof: boolean;      // stdout/stderr 均正常读至 EOF；强制关闭或流错误为 false
}

export interface CollectOpts {
  runTimeoutMs?: number;
  onLine?: (line: string) => void;
  // 原始边界字节回调（Transcript 用）：在任何解码之前收到原始 chunk
  onStdoutData?: (buf: Buffer) => void;
  onStderrData?: (buf: Buffer) => void;
}

// 逐行读 child.stdout，回调每行；返回结束 promise（含 exitCode/signal）。
// 不用 setEncoding：手动 StringDecoder 按 UTF-8 解码（跨 chunk 的多字节序列安全），
// 同时把原始 Buffer 交给 onStdoutData/onStderrData 做无损捕获。
export function collectOutput(child: ChildProcess, opts: CollectOpts = {}): Promise<CollectResult> {
  return new Promise((resolve) => {
    const lines: string[] = [];
    let stderrBuf = "";
    let pending = "";
    let timer: NodeJS.Timeout | undefined;
    let settled = false;
    let spawnError: Error | undefined;
    let streamError = false;
    let stdoutEnded = child.stdout?.readableEnded ?? false;
    let stderrEnded = child.stderr?.readableEnded ?? false;
    child.stdout?.once("end", () => { stdoutEnded = true; });
    child.stderr?.once("end", () => { stderrEnded = true; });
    const stdoutDecoder = new StringDecoder("utf8");
    const stderrDecoder = new StringDecoder("utf8");

    child.stdout?.on("data", (chunk: Buffer) => {
      opts.onStdoutData?.(chunk);
      pending += stdoutDecoder.write(chunk);
      let idx;
      while ((idx = pending.indexOf("\n")) >= 0) {
        const line = pending.slice(0, idx);
        pending = pending.slice(idx + 1);
        if (line.trim()) {
          lines.push(line);
          opts.onLine?.(line);
        }
      }
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      opts.onStderrData?.(chunk);
      stderrBuf += stderrDecoder.write(chunk);
      if (stderrBuf.length > 4096) stderrBuf = stderrBuf.slice(-2048);  // 保留末 2KB
    });
    // 流级 'error' 监听：管道在 destroy()/子进程被 kill 时可能发 'error'（EPIPE 等）。
    // 若无监听器，Node 会把它升级成 uncaughtException 直接崩掉整个 server（并发下高发）。
    // 这些错误对结果无影响，吞掉即可（但 sawEof 会标 false，供 Transcript 记捕获不完整）。
    child.stdout?.on("error", () => { streamError = true; });
    child.stderr?.on("error", () => { streamError = true; });

    let killTimer: NodeJS.Timeout | undefined;
    const done = (exitCode: number | null, signal: NodeJS.Signals | null) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);  // 清理 SIGKILL 宽限定时器，避免悬挂
      if (graceTimer) clearTimeout(graceTimer);  // 清理 exit 宽限定时器
      // 销毁 stdio 流，避免流 pending 阻止进程退出
      child.stdout?.destroy();
      child.stderr?.destroy();
      pending += stdoutDecoder.end();
      if (pending.trim()) {
        lines.push(pending);
        opts.onLine?.(pending);
      }
      stderrBuf += stderrDecoder.end();
      resolve({
        lines,
        stderrTail: stderrBuf.slice(-2048),
        exitCode,
        signal,
        spawnError,
        sawEof: stdoutEnded && stderrEnded && !spawnError && !streamError,
      });
    };

    // 完成时机：exit 后不立即 done——stdio 管道里可能还有未消费的数据
    // （写同步 fsync 拖慢事件循环时尤其明显），立刻 done+destroy 会截断 stdout。
    // 等待 close（stdio 全部关闭、数据投递完毕）或 GRACE_MS 宽限到点。
    // 宽限兜底覆盖 kill 场景：被杀进程的后代（如 sleep）可能长期持有管道，close 会迟迟不来。
    const EXIT_GRACE_MS = 500;
    let exitInfo: { code: number | null; sig: NodeJS.Signals | null } | undefined;
    let graceTimer: NodeJS.Timeout | undefined;
    child.once("exit", (code, sig) => {
      exitInfo = { code, sig };
      graceTimer = setTimeout(() => done(exitInfo?.code ?? code, exitInfo?.sig ?? sig), EXIT_GRACE_MS);
    });
    // spawn 失败（如 PI_BIN 不存在/不可执行）：发 error；close/exit 仍会触发兜底。
    child.once("error", (err) => {
      spawnError = err;
      done(exitInfo?.code ?? null, exitInfo?.sig ?? null);
    });
    child.once("close", (code, sig) => done(code, sig));

    if (opts.runTimeoutMs) {
      timer = setTimeout(() => {
        if (!child.killed) child.kill("SIGTERM");
        // grace 5s 后 SIGKILL（定时器句柄保存，done() 里会清理）
        killTimer = setTimeout(() => {
          if (!child.killed) child.kill("SIGKILL");
        }, 5000);
      }, opts.runTimeoutMs);
    }
  });
}
