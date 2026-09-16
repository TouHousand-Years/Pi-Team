#!/usr/bin/env node
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { SessionRegistry } from "./registry/session.js";
import { RunRegistry } from "./registry/run.js";
import { ProcessTable } from "./runner/process-table.js";
import { loadRegistry, saveRegistry } from "./registry/persist.js";
import { delegate } from "./tools/delegate.js";
import { status } from "./tools/status.js";
import { join } from "node:path";
import { homedir } from "node:os";

const REGISTRY_PATH =
  process.env.PI_SUBAGENT_REGISTRY ?? join(homedir(), ".pi-subagent", "registry.json");

const sessions = new SessionRegistry();
const runs = new RunRegistry();
const procs = new ProcessTable();

// 启动加载
const loaded = loadRegistry(REGISTRY_PATH);
sessions.loadAll(loaded.sessions);

// session 持久化钩子
let savePending = false;
function persist() {
  if (savePending) return;
  savePending = true;
  queueMicrotask(() => {
    savePending = false;
    saveRegistry(REGISTRY_PATH, sessions.allPersistable()).catch(() => undefined);
  });
}

const server = new Server(
  { name: "pi-subagent", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "pi_delegate",
      description: "委派任务给 Pi 子代理（默认 async）",
      inputSchema: {
        type: "object",
        properties: {
          prompt: { type: "string" },
          session: { type: "string" },
          cwd: { type: "string" },
          goal: { type: "string" },
          constraints: { type: "object" },
          mode: { type: "string", enum: ["sync", "async"] },
          runTimeoutMs: { type: "number" },
          allowUnknownTools: { type: "boolean" },
        },
        required: ["prompt", "session"],
      },
    },
    {
      name: "pi_status",
      description: "取 run 结果（long-poll）",
      inputSchema: {
        type: "object",
        properties: { runId: { type: "string" }, waitTimeoutMs: { type: "number" } },
        required: ["runId"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const args = (req.params.arguments ?? {}) as any;
  try {
    let result: unknown;
    switch (req.params.name) {
      case "pi_delegate":
        result = await delegate(args, { sessions, runs, procs, onSessionChange: persist });
        break;
      case "pi_status":
        result = await status(args, runs);
        break;
      default:
        return {
          content: [{ type: "text", text: JSON.stringify({ error: "unknown tool" }) }],
          isError: true,
        };
    }
    persist();
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
  } catch (e: any) {
    const payload = e?.code ? e : { error: String(e), code: "internal" };
    return { content: [{ type: "text", text: JSON.stringify(payload) }], isError: true };
  }
});

// 兜底：任何未捕获异常/未处理拒绝都不应掀翻整个 server（否则 stdio 传输断开，
// 客户端看到 "Connection closed"，所有工具一起失联）。记到 stderr（不污染 stdout 的
// JSON-RPC 通道），保持进程存活。
process.on("uncaughtException", (err) => {
  process.stderr.write(`[pi-subagent] uncaughtException: ${err?.stack ?? err}\n`);
});
process.on("unhandledRejection", (reason) => {
  process.stderr.write(`[pi-subagent] unhandledRejection: ${String(reason)}\n`);
});

// 退出清理：kill 所有 managed child
function cleanup() {
  procs.killAll();
}
process.on("SIGINT", () => {
  cleanup();
  process.exit(0);
});
process.on("SIGTERM", () => {
  cleanup();
  process.exit(0);
});
process.on("exit", cleanup);

const transport = new StdioServerTransport();
await server.connect(transport);
