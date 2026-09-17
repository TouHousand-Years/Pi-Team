import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { REMOVED_TOOLS, SUPPORTED_TOOLS } from "./skill-surface.js";

function fakePiEnv(mode: "success" | "hang" | "require_session" | "continuity"): Record<string, string> {
  return {
    PI_BIN: `C:\\Progra~1\\Git\\bin\\bash.exe ${resolve("test/fixtures/fake-pi.sh")}`,
    FAKE_PI_MODE: mode,
  };
}

function inheritedEnv(): Record<string, string> {
  return Object.fromEntries(
    Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined),
  );
}

async function withServer(
  mode: "success" | "hang" | "require_session" | "continuity",
  setup: (paths: { dir: string; cwd: string; registry: string; tasks: string }) => void,
  run: (client: Client, paths: { dir: string; cwd: string; registry: string; tasks: string }) => Promise<void>,
): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "pi-sub-mcp-"));
  const paths = {
    dir,
    cwd: dir,
    registry: join(dir, "registry.json"),
    tasks: join(dir, "tasks.json"),
  };
  setup(paths);

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [resolve("dist/server.js")],
    cwd: process.cwd(),
    env: {
      ...inheritedEnv(),
      ...fakePiEnv(mode),
      PI_SUBAGENT_REGISTRY: paths.registry,
      PI_SUBAGENT_TASKS: paths.tasks,
      FAKE_PI_MARKER: join(dir, "continuity.marker"),
      // Real windows must never open during the test suite; the Run Window
      // launch path has its own coverage in test/viewer.test.ts.
      PI_SUBAGENT_VIEWER: "off",
      PI_SUBAGENT_TRANSCRIPTS: join(dir, "runs"),
    },
    stderr: "pipe",
  });
  const client = new Client({ name: "mcp-surface-test", version: "1.0.0" });

  try {
    await client.connect(transport);
    await run(client, paths);
  } finally {
    await client.close();
    rmSync(dir, { recursive: true, force: true });
  }
}

function toolJson(result: Awaited<ReturnType<Client["callTool"]>>): any {
  const text = "content" in result
    ? result.content.find((item) => item.type === "text")?.text
    : undefined;
  assert.ok(text, "tool result should contain JSON text");
  return JSON.parse(text);
}

test("server reads registry v1 and continues an existing Pi Session", async () => {
  await withServer("require_session", ({ cwd, registry }) => {
    writeFileSync(registry, JSON.stringify({
      version: 1,
      sessions: [{
        name: "existing",
        piSessionId: "019f0000-0000-0000-0000-000000000001",
        cwd,
        goal: "keep continuity",
        status: "idle",
        progress: [],
        lastActive: 1,
        msgCount: 2,
      }],
    }));
  }, async (client) => {
    const result = await client.callTool({
      name: "pi_delegate",
      arguments: { prompt: "continue", session: "existing", mode: "sync" },
    });
    const value = toolJson(result);
    assert.equal(value.status, "completed", JSON.stringify(value));
    assert.equal(value.session.name, "existing");
  });
});

test("pi_delegate sync creates and then continues the same Pi Session", async () => {
  await withServer("continuity", () => undefined, async (client, { cwd }) => {
    const created = toolJson(await client.callTool({
      name: "pi_delegate",
      arguments: { prompt: "create", session: "continued", cwd, goal: "stay coherent", mode: "sync" },
    }));
    assert.equal(created.status, "completed", JSON.stringify(created));

    const continued = toolJson(await client.callTool({
      name: "pi_delegate",
      arguments: { prompt: "continue", session: "continued", mode: "sync" },
    }));
    assert.equal(continued.status, "completed", JSON.stringify(continued));
    assert.equal(continued.session.name, "continued");
  });
});

test("pi_status long-polls an async Run to completion", async () => {
  await withServer("success", () => undefined, async (client, { cwd }) => {
    const delegated = toolJson(await client.callTool({
      name: "pi_delegate",
      arguments: { prompt: "async", session: "async-run", cwd, goal: "finish", mode: "async" },
    }));
    const completed = toolJson(await client.callTool({
      name: "pi_status",
      arguments: { runId: delegated.runId, waitTimeoutMs: 5000 },
    }));
    assert.equal(completed.status, "completed", JSON.stringify(completed));
    assert.ok(completed.result);
  });
});

test("an async Run reaches timeout without a public kill tool", async () => {
  await withServer("hang", () => undefined, async (client, { cwd }) => {
    const delegated = toolJson(await client.callTool({
      name: "pi_delegate",
      arguments: {
        prompt: "hang",
        session: "timed-run",
        cwd,
        goal: "time out safely",
        mode: "async",
        runTimeoutMs: 500,
      },
    }));
    const completed = toolJson(await client.callTool({
      name: "pi_status",
      arguments: { runId: delegated.runId, waitTimeoutMs: 3000 },
    }));
    assert.equal(completed.status, "timeout", JSON.stringify(completed));
    assert.equal(completed.error.code, "timeout");
  });
});

test("removed MCP tool names are rejected as unknown", async () => {
  await withServer("success", () => undefined, async (client) => {
    for (const name of REMOVED_TOOLS) {
      const result = await client.callTool({ name, arguments: {} });
      assert.equal(result.isError, true, `${name} should be rejected`);
      assert.deepEqual(toolJson(result), { error: "unknown tool" }, name);
    }
  });
});

test("the server leaves legacy tasks.json untouched and unused", async () => {
  const sentinel = "not legacy task JSON\n";
  await withServer("success", ({ tasks }) => {
    writeFileSync(tasks, sentinel);
  }, async (client, { cwd, dir, tasks }) => {
    const result = toolJson(await client.callTool({
      name: "pi_delegate",
      arguments: { prompt: "run", session: "no-tasks", cwd, goal: "ignore tasks", mode: "sync" },
    }));
    assert.equal(result.status, "completed", JSON.stringify(result));
    assert.equal(readFileSync(tasks, "utf8"), sentinel);
    assert.deepEqual(
      readdirSync(dir).filter((name) => name.startsWith("tasks.json.")),
      [],
      "reading the invalid legacy file would create a corrupt backup",
    );
  });
});

test("pi_status exposes capture integrity and accepts openWindow without a viewer", async () => {
  await withServer("success", () => undefined, async (client, { cwd }) => {
    const delegated = toolJson(await client.callTool({
      name: "pi_delegate",
      arguments: { prompt: "run", session: "window-opt", cwd, goal: "check the surface", mode: "sync" },
    }));
    assert.equal(delegated.status, "completed", JSON.stringify(delegated));
    assert.ok(delegated.runId);

    const harvested = toolJson(await client.callTool({
      name: "pi_status",
      arguments: { runId: delegated.runId, openWindow: true, waitTimeoutMs: 0 },
    }));
    assert.equal(harvested.status, "completed", JSON.stringify(harvested));
    // The Transcript is the durable evidence for the window; with the window
    // disabled there is simply no viewer field, and nothing throws.
    assert.equal(harvested.transcript?.available, true);
    assert.equal(harvested.viewer?.available, false);
    assert.equal(typeof harvested.timing?.startedAt, "number");
  });
});

test("the MCP surface contains exactly pi_delegate and pi_status", async () => {
  await withServer("success", () => undefined, async (client) => {
    const names = (await client.listTools()).tools.map((tool) => tool.name).sort();
    assert.deepEqual(names, [...SUPPORTED_TOOLS].sort());
  });
});
