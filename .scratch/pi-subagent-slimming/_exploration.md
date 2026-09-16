# 探索报告 — pi-subagent 瘦身 / 只读状态弹窗 / 低频监控

- 角色: Explorer SubAgent（只读；未改动任何产品文件）
- 仓库根: `C:\Users\qnhxx\Documents\AI-Projects\Code\pi-subagent`
- 基线提交: `174cf17`（`main`，工作区仅 4 个未跟踪规划文件）
- 复现状态: **build ✔**；**test 136/140 ✔ / 4 ✖**（4 例均为 Windows 路径分隔符，非本次问题）
- 本报告仅写入 `.scratch/pi-subagent-slimming/_exploration.md`

---

## 0. 结论（先回答）

1. **pi-worker 系列 skill 真正依赖的 MCP 工具只有 2 个：`pi_delegate` + `pi_status`。**
   `pi-worker` 自身不直接调任何 pi 工具，它把委派机制全权交给 `pi-team`；`pi-team/SKILL.md` 全文仅出现 `pi_delegate`(3 次) 与 `pi_status`(1 次)，**未引用** `pi_plan` / `pi_session_*` / `pi_kill` / `pi_task_*`。
2. 其余 10 个工具（`pi_plan`、`pi_session_list/snapshot/fork`、`pi_kill`、`pi_task_create/plan/stage_run/stage_collect/list`）**只被仓库自带 `skills/pi-subagent` v2 任务编排协议使用**；在全部已安装 skill 中做全文检索，`pi_task_*` / `pi_session_*` / `pi_plan` / `pi_kill` 只出现在该 skill 及其 references。
3. **本仓库内没有 pi-worker**（对 `*.md`/`*.ts`/`*.json` 全文检索 `pi-worker` 为 0 命中）。pi-worker 是仓库外、由 `~/.skills-manager/skills/pi-worker` 软链到 `~/.codex/skills`、`~/.zcode/skills` 的独立 skill。
4. **当前真正被注册为 MCP server 的不是本仓库**：`~/.codex/config.toml` 的 `[mcp_servers.pi-subagent]` 指向 `C:\Users\qnhxx\Documents\Codex\tools\pi-subagent\dist\server.js`（另一份 checkout，HEAD `21fe334`）。本 AI-Projects 仓库（`174cf17`）未在任何找到的 MCP 配置中出现。两份树已分叉。
5. **那份 live checkout 已被本地改成默认 `sync`**（`mode ?? "sync"`、`plan.ts` 默认 sync，且 SKILL/README/test 同步改成 sync 措辞），而本仓库 HEAD 仍是默认 `async`。这是"去 async / 去长轮询 / sync 优先"方向最强的意图信号。
6. **pi 本身不内置 MCP、子代理、permission popup、plan mode、to-do、后台 bash**（官方 `usage.md:309`）。因此"只读弹窗"不可能是 pi 作为 MCP host 的行为；pi 只提供 **extension UI**（`ctx.ui.setStatus` / `setWidget` / `notify` / `custom({overlay})`）。当前 host 是 **Codex CLI**，其弹窗能力在本环境**无任何文档/证据** → 弹窗落点是未决问题。
7. **服务端目前没有任何 push 通道**：`src/` 中检索 `notif`/`logging`/`notifications/` 为 0 命中。监控完全是拉模型；状态事实源是 `~/.pi-subagent/registry.json` 与（尚未出现的）`tasks.json` 两个文件。
8. **测试回归风险集中在"删工具"**：删 task 工具会连带 6 个测试文件、删 plan/session/kill 各连带对应测试；且现有 4 个 `stage-prompt` 测试在 Windows 上本来就是红的（路径分隔符），改 stage-prompt 时极易误判。

---

## 1. 事实（Facts）

### Track 1 — 架构与工具面

**F1.1 工具体系共 12 个，全部在单文件注册。**
`src/server.ts:60-241` 的 `ListToolsRequestSchema` 处理器内联声明 12 个工具（名称/描述/inputSchema），switch 分发在 `src/server.ts:244-299`：

| # | 工具 | 描述（原文） | server.ts 行 |
|---|------|-------------|-------------|
| 1 | `pi_delegate` | 委派任务给 Pi 子代理（默认 async） | 67 |
| 2 | `pi_status` | 取 run 结果（long-poll） | 85 |
| 3 | `pi_plan` | 调度决策：该不该委派、sync/async、开几个 session | 94 |
| 4 | `pi_session_list` | 列 session | 109 |
| 5 | `pi_session_snapshot` | 取 session 详情 | 114 |
| 6 | `pi_session_fork` | 派生 session | 123 |
| 7 | `pi_kill` | 中止 run | 132 |
| 8 | `pi_task_create` | 建任务（host 已写好 `_plan-draft.md`） | 141 |
| 9 | `pi_task_plan` | 派审阅 Pi 审阅计划草案 | 183 |
| 10 | `pi_task_stage_run` | 执行某阶段（验收+最多 3 次重派+manual 升级） | 197 |
| 11 | `pi_task_stage_collect` | 收割 async stage_run 结果 | 215 |
| 12 | `pi_task_list` | 列任务 | 228 |

注意：`README.md:5` 仍写"7 structured tools"，`skills/pi-subagent/SKILL.md` 写"工具速查（11 个）"，与实际的 12 个均已不一致（文档漂移）。

**F1.2 运行时依赖极薄。**
`package.json`: 唯一 runtime 依赖 `@modelcontextprotocol/sdk@1.29.0`；devDeps 仅 `tsx@4.22.4`、`typescript`、`@types/node`；ESM；`bin` → `./dist/server.js`；`prepare` 会跑 `build`。

**F1.3 四个注册表 + 两处持久化。**
`src/server.ts:28-42` 实例化 `SessionRegistry` / `RunRegistry` / `ProcessTable` / `TaskRegistry`，启动时从 `PI_SUBAGENT_REGISTRY`（默认 `~/.pi-subagent/registry.json`）与 `PI_SUBAGENT_TASKS`（默认 `~/.pi-subagent/tasks.json`）加载；`persist()` `src/server.ts:44-56`、`persistTasks()` `:58-67` 用 `queueMicrotask` 合并写。

**F1.4 调用 Pi 的 CLI 形态固定在 `argv.ts`。**
`src/runner/argv.ts:8-21`：`["-p", prompt, "--mode", "json"]`，可选 `--session-id` / `--tools` / `--exclude-tools` / `--thinking` / `--model` / `--no-skills` / `--no-context-files`。fork 用 `--mode json --fork <id>`（`:24-26`）。任务阶段 prompt 由 `src/tools/stage-prompt.ts` 生成（IOAC 模板）。

**F1.5 无任何 MCP 通知能力。**
`grep -rniE "notif|logging|notifications/" src` 为 0 命中。即服务端只能被动响应 `CallToolRequest`，不能主动 push run 状态。

**F1.6 规模。**
`src/**/*.ts` 共 2789 行；`test/**` 共 1896 行；`docs/implementation-plan.md` 2955 行、`docs/design.md` 827 行、`docs/design-batch1.md` 406 行。

### Track 2 — Skill / 测试依赖

**F2.1 全部已安装 pi 系 skill 及文件。**
`~/.skills-manager/skills/` 下：`pi-worker`、`pi-team`、`pi-explorer`、`pi-translator`、`pi-ultra-planner`、`pi-subagent`。`pi-worker` 的 `SKILL.md` frontmatter `metadata.requires.mcps: ["pi-subagent"]`，正文写"Use the `pi-team` contract ... `pi-team` owns delegation mechanics."

**F2.2 `pi-team` 是唯一实际描述工具调用的契约层。**
`pi-team/SKILL.md`：
- 只提到 `pi_delegate`（3 次）与 `pi_status`（1 次）。
- "Use `pi_delegate` with `mode:"sync"` by default."；async 仅当 specialized skill 明确要求。
- 约束传递：读 specialized skill 旁的 `pi-model.json`（`model`+`thinking` 原样传），读 `subagent-prompt.md` 逐字拼进 prompt，`noSkills: true`，host 负责联网。
- 收集规则："`waitTimeoutMs` no greater than 25000"、"at most three consecutive collection calls in one host turn; if still `running`, return the `runId` and stop"、"Do not use zero-time polling or an unbounded loop"。
- 并发："Keep at most four Pi runs active and queue the rest."

**F2.3 四个 specialized skill 的差异点（都走 pi-team）。**
- `pi-worker`：写代码/交付物，主循环 baseline→stage→execute→verify→correct→stop。
- `pi-explorer`：只读侦察，轨道 cache/frontend/concurrency/network/recent commits/tests/reproduction。
- `pi-translator`：翻译分段，维护 `_glossary.md`。
- `pi-ultra-planner`：**额外**传 `noContextFiles: true` + `excludeTools: ["read","bash","edit","write"]`（`pi-ultra-planner/SKILL.md` "Planner isolation" 节）。
- 每个 specialized skill 有自己的 `pi-model.json`（model/thinking）与 `subagent-prompt.md`；`pi-worker` 的 model 是 `deepseek-v4.1-flash-expires-on-0910` + thinking `max`。

**F2.4 全量工具引用统计（跨所有已安装 skill）。**
```
9  pi_task_stage_run    （仅 pi-subagent/references + SKILL）
7  pi_status           （pi-subagent SKILL + references + pi-team）
6  pi_task_create      （仅 pi-subagent）
3  pi_delegate         （pi-team + pi-subagent + references）
3  pi_task_plan        （仅 pi-subagent）
2  pi_task_list        （仅 pi-subagent）
2  pi_session_snapshot （仅 pi-subagent）
1  pi_session_list / pi_session_fork / pi_plan / pi_kill （仅 pi-subagent）
```
（`grep -rEo` 统计；每条命中都只落在 `pi-subagent` 与 `pi-team` 两个 skill 目录。）

**F2.5 仓库 skill 与已安装副本一致。**
`diff -r skills/pi-subagent ~/.skills-manager/skills/pi-subagent` → IDENTICAL。即仓库里的 v2 协议 skill 就是正在被多 host 使用的版本。

**F2.6 `pi-subagent` skill 的监控措辞是要改的对象。**
`skills/pi-subagent/SKILL.md` "status 轮询" 节原文："async delegate 后，反复调 `pi_status(runId)` 收割，每次最多等 25s"、"不要给 `waitTimeoutMs>28000`"、"收割到 status 非 running 即结束"。这是"连续监听/反复轮询"的来源；相比之下 `pi-team` 已经是"每 host turn 最多 3 次"的有界等待。

### Track 3 — 监控 / 轮询语义

**F3.1 默认 long-poll 25s。**
`src/tools/status.ts:40`：`const waitMs = input.waitTimeoutMs ?? 25000;`；`:38-39` 注释"默认 25000（低于 host 工具调用硬超时 30s）"；传 `0` → 立即返回 running（纯轮询）。

**F3.2 并发上限与超时。**
`src/tools/delegate.ts:10` `MAX_CONCURRENCY = 4`；`:82` 超限抛 `resourceBusy`；`:86` `runTimeoutMs ?? 600000`；`:271` `stallTimeoutMs ?? 300000`；`:11` `SESSION_START_TIMEOUT_MS = 10000`（握手 10s）。

**F3.3 Run 注册表保留策略。**
`src/registry/run.ts:30-31`：`maxCompleted = 128`、`ttlMs = 86400000`（24h）；`:118` 过期淘汰、`:128` 超过 maxCompleted 淘汰旧完成 run。淘汰后 `pi_status` 返回 `run_expired`。

**F3.4 进度是内存态、有上限。**
`test/session-registry.test.ts` 用例名 "progress FIFO 截断到 50"、"progress 上限：Run.progress 截到 200 + truncated" → session 级 progress 上限 50，run 级 200。`snapshot` 脱敏不含 `piSessionId`（同文件用例 "snapshot 脱敏不含 piSessionId"）。

**F3.5 状态事实源是文件。**
live 环境 `~/.pi-subagent/registry.json` 存在（266595 字节，2026-09-15 17:15）；`tasks.json` 尚不存在（Codex env 已指定 `C:\Users\qnhxx\.pi-subagent\tasks.json`，但文件未创建，说明从未建过 task）。任何"只读弹窗/看板"都可直接读这两个 JSON。

### Track 4 — UI 集成缝

**F4.1 pi 官方明确不内置 MCP / 子代理 / popup。**
`docs/usage.md:309`（pi 0.85.1 安装包内）："It intentionally does not include built-in MCP, sub-agents, permission popups, plan mode, to-dos, or background bash. You can build or install those workflows as extensions or packages..."

**F4.2 pi 唯一 UI 缝是 extension，且能力齐全。**
`docs/extensions.md`：
- 加载位置 `~/.pi/agent/extensions/*.ts` 或 `.pi/extensions/*.ts`（`:109-139`）。
- 事件 `tool_execution_start/update/end`（`event.toolCallId/toolName/args/result`）、`agent_settled`、`turn_start/end`（`:651-686`, `:567-583`）。
- UI：`ctx.ui.setStatus`（footer 常驻）、`setWidget`（编辑器上/下，`placement:"belowEditor"`）、`setFooter`、`notify`（info/warning/error）、`custom(..., {overlay:true})` 浮层（实验性，`overlayOptions` 支持 `anchor`/`width`/`margin`）、`ui_prompt_start/end` 可上报"等待用户"（`:2586-2650`, `:2763-2794`, `:585-599`）。
- 参考实现：`examples/extensions/status-line.ts`（setStatus 常驻状态）、`notify.ts`（**Windows toast 通过 powershell，含 `WT_SESSION` 分支** + OSC 777/99）、`overlay-qa-tests.ts`、`plan-mode/`。

**F4.3 pi 自带一个 `subagent` extension 范例（与本 MCP server 平行）。**
`examples/extensions/subagent/index.ts` 实现 single/parallel/chain，带 `onUpdate` 流式渲染、自定义 `renderCall/renderResult`、`MAX_PARALLEL_TASKS=8`/`MAX_CONCURRENCY=4`。它不是本仓库的 MCP server，且**未安装**（`~/.pi/agent/extensions` 为空目录）。这说明"弹窗 + 进度流"在 pi 侧已有成熟范式可借鉴。

**F4.4 当前 MCP host 是 Codex CLI，不是 pi。**
`~/.codex/config.toml`：
```toml
[mcp_servers.pi-subagent]
command = '...\node.exe'
args = ['C:\Users\qnhxx\Documents\Codex\tools\pi-subagent\dist\server.js']
[mcp_servers.pi-subagent.env]
PI_BIN = '...\node.exe ...\@earendil-works\pi-coding-agent\dist\bundle\cli.js'
PI_SUBAGENT_REGISTRY = 'C:\Users\qnhxx\.pi-subagent\registry.json'
PI_SUBAGENT_TASKS = 'C:\Users\qnhxx\.pi-subagent\tasks.json'
```
- `~/.pi/agent/settings.json` 只有 theme/model，无 MCP 配置；pi 官方不支持 MCP，故 pi 不可能是 pi-subagent 的 host。
- `~/.zcode` 下未找到任何 mcp 配置文件；`~/.agents/mcp.json`、`~/.zcode/mcp.json`、`~/.codex/mcp.json` 均为空。
- 结论：**弹窗若依附 host，必须调查 Codex CLI 能力；若想 host-agnostic，应做独立只读 watcher。**

**F4.5 两份 checkout 分叉。**
- AI-Projects（本仓库）：`174cf17`，工作区干净（仅规划文件未跟踪）。
- `Documents/Codex/tools/pi-subagent`：`21fe334`，工作区 **dirty**：`README.md`、`skills/pi-subagent/SKILL.md`、`references/delegation-patterns.md`、`src/scheduler/plan.ts`、`src/server.ts`、`src/tools/delegate.ts`、`test/scheduler.test.ts` 均已改，核心改动是 **默认 async → sync**（`mode ?? "sync"`、`let mode = "sync"`、测试 "R5 默认 → sync"）。这些改动**未提交、未合入本仓库**。

### Track 5 — Git 意图 / ADR / 词汇

**F5.1 仓库治理文件（未跟踪，`174cf17` 之后新增）。**
- `AGENTS.md`：指向 `.scratch/<feature>/`、`docs/agents/*`。
- `CONTEXT.md`：仅占位符（"Add the project's domain glossary ... here"），**尚无词汇表**。
- `docs/adr/`：仅 `.gitkeep`，**零 ADR**。
- `docs/agents/issue-tracker.md`：定义 Wayfinder 约定——map 为 `.scratch/<effort>/map.md`，child ticket 为 `.scratch/<effort>/issues/NN-<slug>.md`，带 `Type:`/`Status:`/`Blocked by:` 行；frontier 取最小未阻塞未认领编号。
- `docs/agents/domain.md`：单 context 布局。
- `docs/agents/triage-labels.md`：canonical 标签。

**F5.2 目标 effort 目录尚未创建。**
`.scratch/pi-subagent-slimming/` 在本报告写入前不存在（`find .scratch` 为空）。本文件是该目录的第一个文件。

**F5.3 Git 词汇（近期 commit）。**
`174cf17` 修正 MCP 启动路径 → `21fe334` 审阅闭环/async 超时/重试 session → `6ffccc1` 代码修改权单一归属 Pi → `7fc959f` tool-call-loop 反模式 → `9256cd2` "server 注册 4 个 task 工具 + tasks.json 持久化 (11 工具)" → `dbbec81` pi-subagent skill + delegation patterns。历史主线是"不断加工具/加协议"，没有"减"的先例；`9256cd2` 自身记录当时是 11 工具，之后又加到 12。

**F5.4 设计文档词汇。**
`docs/design.md`：host/worker、sync/async、long-poll、handshake、Session/Run/Task/Stage、"层 A/层 B 取消"、"C 模式/B 模式"（C = host 做不可控 I/O，B = 拆任务）。`docs/design.md:305` 记录"默认 async 的理由：多数 MCP host 对单次 tool call 有 30-60s 超时"——而 live checkout 已把默认改成 sync，说明该前提在实操中被推翻/绕过。
`skills/pi-subagent/SKILL.md`：四条铁律、IOAC、manual 决策面板、代码修改权一刀切。

**F5.5 无与 slim/UI/monitor 相关的 ADR 或 spec。**
`.scratch/pi-subagent-slimming/` 无 spec；`docs/adr/` 空。本需求是目前唯一的规划载体（即本探索 + 后续 map/tickets）。

### Track 6 — 测试命令 / 回归基线

**F6.1 安装/构建。**
初始 `node_modules` / `dist` 均缺失。`npm ci` 成功（added 99 packages，exit 0），并自动跑 `prepare → build → tsc`，产出 `dist/`（含 `server.js`）。

**F6.2 测试基线：140 定义 / 136 ✔ / 4 ✖。**
命令（`package.json:12`）：`node --import tsx --test --test-reporter=spec test/*.test.ts`。
4 个失败**全部**在 `test/stage-prompt.test.ts`，且**全部**是 Windows 路径分隔符断言（实现 `src/tools/stage-prompt.ts:20,99` 用 `join(task.cwd, p)` 产生 `\proj\...`，测试断言字面量 `/proj/...`）：
1. `buildStagePrompt 输入文件用绝对路径`（`test/stage-prompt.test.ts:30-33`）
2. `buildStagePrompt 输出文件绝对路径 + 只写它`（`:35-39`）
3. `buildStagePrompt 自动注入 dependsOn 已通过阶段的 outputFile`（`:60`，断言在 `:70`）
4. `buildReviewPrompt 含审阅指令 + verdict 要求`（`:100`，断言在 `:108`）
这些是**当前基线的既存问题**，与瘦身无关，但改 stage-prompt 时必须区分。

**F6.3 测试文件 ↔ 模块依赖（删工具时的回归面）。**
| 测试文件 | 行数 | 覆盖的将被删候选 |
|---------|------|----------------|
| `task-tools.test.ts` | 285 | `pi_task_*` |
| `task-integration.test.ts` | 110 | `pi_task_*` 端到端 |
| `task-persist.test.ts` | 143 | TaskRegistry 持久化 |
| `stage-prompt.test.ts` | 113 | stage prompt（含 4 个红测） |
| `scheduler.test.ts` | 139 | `pi_plan` 决策 |
| `session-registry.test.ts` | 82 | session 注册表 |
| `fork.test.ts` | 23 | `pi_session_fork` |
| `kill.test.ts` | 21 | `pi_kill` |
| `stall.test.ts` | 56 | 停滞检测（`pi_kill`/stall） |
| `delegate.test.ts` | 133 | `pi_delegate` |
| `status.test.ts` | 48 | `pi_status` |
| `integration.test.ts` | 106 | async/sync/多等待者 |
| `run-registry.test.ts` | 81 | RunRegistry |
| `persist.test.ts` | 100 | registry 原子写 |
| `validate*.test.ts` | 214 | 验收规则 |
| 其余（argv/parse/redaction/spawn/types） | 163 | runner/工具链 |

**F6.4 其他命令。**
`npm run build`（tsc）通过；`npm run test:fast`（dot reporter）存在；`npm start` = `tsx src/server.ts`；README 测试节（`README.md:120-133`）记录 fake-pi（`test/fixtures/fake-pi.sh`）测试方式。

---

## 2. 支持的推断（Supported inferences，非直接事实）

**I1（强）**：若目标是"保留 pi-worker 及同类 skill 所需能力"，则**最小可用工具集 = `pi_delegate` + `pi_status`**；`pi_kill` 大概率应作为"人类中止"逃生口保留（但注意：没有任何已安装 skill 引用它——`pi-team` 的失败处理只说 report/stop，不调 kill）。其余 9 个工具属于"可删候选"。依据 F2.2/F2.4/F2.1。

**I2（强）**：`pi_task_*` 5 个工具 + `pi_plan` + `pi_session_*` 3 个工具是 v2 任务编排协议的专属机械；若 v2 skill 被瘦身/退役，这些工具与对应测试（F6.3）可整体移除。依据 F2.4/F2.6/F1.1。

**I3（强）**：用户要的"低频监控（每几分钟）+ 人工 continue"与 `pi-team` 现有契约**方向一致、粒度更松**。真正需要改的是仓库自带 `skills/pi-subagent/SKILL.md` 的"反复调 pi_status"措辞（F2.6），把它改成"每 N 分钟一次、由人触发 continue"。依据 F2.6/F3.1/F3.2。

**I4（中）**：只读弹窗最稳的落点是**独立只读 watcher 进程**（读 `registry.json` / `tasks.json`，用终端通知或小窗显示），因为它不依赖 host（Codex/zcode/pi 都行），也不依赖 MCP 通知。pi extension 路线只在"host 换成 pi"时成立（F4.1）。依据 F3.5/F4.2/F4.4/F1.5。

**I5（中）**：live checkout 的"默认 sync"改动说明团队已在地下修掉 async/长轮询的操作负担；本仓库 HEAD 落后于真实意图。瘦身应以此为前提（F4.5）。依据 F4.5/F5.4。

**I6（中）**：两份 checkout 分叉 + live 版带未提交改动，意味着任何"删工具"改动必须明确落点（哪份树、是否同步到 live、dist 是否重建），否则 host 行为与仓库不一致。依据 F4.4/F4.5/F6.1。

**I7（弱）**：4 个 Windows 红测可以顺带修（改断言为平台无关的 `path.join` 或实现统一正斜杠），但属独立小修，不应混进瘦身 PR。依据 F6.2。

---

## 3. 未知与证据缺口（Unknowns / gaps）

- **U1 弹窗的目标 host 未定。** 本机 live host 是 Codex CLI；Codex 是否支持状态行/浮窗/通知，未找到任何文档或配置。ZCode 的 MCP 配置也未找到。pi 明确不支持 MCP。
- **U2 pi 是否会被用作 host（届时可用 extension UI）未有决定。** `~/.pi/agent/extensions` 为空，说明当前没有装任何 pi 扩展。
- **U3 MCP SDK 的通知能力是否可被 Codex 渲染未知。** `@modelcontextprotocol/sdk@1.29.0` 可能支持 `server.notification()`，但 src 未使用，且 client 渲染未知（F1.5）。
- **U4 "人工 continue-command" 的强制位置未定。** 应由 skill 文本约束，还是由服务端阻塞/门控？现有代码无"等待人工"状态。
- **U5 兼容性未定。** 删工具后，旧 `registry.json`（266KB、含大量 session）与潜在 `tasks.json` 的向后兼容要求未知。
- **U6 `docs/implementation-plan.md`（2955 行）未逐节读**，可能含"计划中但未实现"的能力，或对瘦身范围的既有约束。
- **U7 两份 checkout 的关系未定。** 不知 `Documents/Codex/tools/pi-subagent` 是手工拷贝、安装产物还是旧 clone；其 dirty 改动是否会回流本仓库未知。
- **U8 环境版本漂移。** 本机 pi 为 `0.85.1`；`docs/design.md` 写 `0.77.0`；`pi-worker/pi-model.json` 的 model `deepseek-v4.1-flash-expires-on-0910` 名字带过期日期。是否仍有效未验证。
- **U9 "通知完成"的通道未定。** pi 侧有 `notify.ts` 的 Windows toast 范式（F4.2），但 host 是 Codex，是否有等价通道未知。

---

## 4. 决策问题（给 Wayfinder map，按重要性）

1. **保留面**：瘦身后保留 `pi_delegate`+`pi_status`（pi-team 契约），还是保留完整 v2 任务编排（`pi_task_*`）？这决定 9 个工具与 6 个测试文件的去留。（I1/I2）
2. **弹窗落点**：独立只读 watcher、pi extension、还是 host（Codex）原生能力？（U1/U2/U4）
3. **监控契约**：只改 skill 文本（每几分钟一次、人触发 continue），还是服务端也去掉 long-poll/async 机制？（I3/F3.1）
4. **完成通知通道**：终端 OSC/toast、系统通知、还是仅弹窗内显示？（U9/F4.2）
5. **逃生口**：`pi_kill` / `pi_session_*` / `pi_plan` 是保留为底层能力，还是随 v2 一起删？
6. **落点与同步**：改动落在本仓库（`174cf17`）还是 live checkout（`21fe334`+dirty）？是否先合并 live 的 sync 改动？（I5/I6/U7）
7. **兼容**：是否要求旧 `registry.json`/`tasks.json` 仍可读？
8. **红测**：4 个 Windows 路径失败是顺手修还是留作独立 ticket？（I7）

---

## 5. 证据地图（Evidence map）

**本仓库产品代码**
- `src/server.ts` — 12 工具注册与分发（`:60-241` / `:244-299`）；持久化钩子（`:44-67`）；无通知
- `src/types.ts` — Constraints / `PI_BUILTIN_TOOLS`（`:12`）/ noSkills / noContextFiles / stallTimeoutMs
- `src/tools/delegate.ts` — MAX_CONCURRENCY=4（`:10`）、握手 10s（`:11`）、默认 mode（`:84`）、stall 300s（`:271`）
- `src/tools/status.ts` — long-poll 默认 25000（`:40`）、`0` 立即返回（`:38-39`）
- `src/tools/task.ts` / `stage-prompt.ts` / `plan-tool.ts` / `session.ts` / `kill.ts` — 其余工具实现
- `src/scheduler/plan.ts` + `keywords.ts` — `pi_plan` 5 阶段决策
- `src/registry/{run,session,task,persist,task-persist,redact}.ts` — 状态与持久化（run.ts `:30-31` 保留策略）
- `src/runner/{argv,spawn,parse,validate,process-table}.ts` — CLI 形态与验收
- `package.json` / `tsconfig.json` — 构建与依赖

**本仓库文档 / skill**
- `README.md` — 工具表（`:53-66`）、安装（`:93-116`）、测试（`:120-133`）；`:5` 7-tools 已过时
- `skills/pi-subagent/SKILL.md` — v2 协议、四条铁律、"反复调 pi_status"（待改）、11-tools 速查
- `skills/pi-subagent/references/{delegation-patterns,tool-call-loop-antipattern}.md`
- `docs/design.md`（`:305` async 理由、`:326` 轮询命名）、`docs/design-batch1.md`、`docs/implementation-plan.md`（未全读）、`docs/batch1-test-handoff.md`、`REVIEW.md`
- 治理：`AGENTS.md`、`CONTEXT.md`（占位）、`docs/agents/{issue-tracker,domain,triage-labels}.md`、`docs/adr/`（空）

**仓库外（只读取证）**
- `~/.skills-manager/skills/pi-worker/{SKILL.md,subagent-prompt.md,pi-model.json,agents/openai.yaml}`（并被 `~/.codex/skills`、`~/.zcode/skills` 软链）
- `~/.skills-manager/skills/pi-team/SKILL.md` — 关键契约（唯一引用 pi_delegate/pi_status）
- `~/.skills-manager/skills/{pi-explorer,pi-translator,pi-ultra-planner}/{SKILL.md,subagent-prompt.md,pi-model.json}`
- `~/.skills-manager/skills/pi-subagent/*` — 与仓库副本字节一致
- `~/.codex/config.toml` — `[mcp_servers.pi-subagent]` 指向另一 checkout + PI_BIN/REGISTRY/TASKS
- `C:\Users\qnhxx\Documents\Codex\tools\pi-subagent` — live checkout（HEAD 21fe334，dirty，默认 sync）
- `~/.pi-subagent/registry.json`（266595 B；`tasks.json` 不存在）
- pi 安装包 `...\@earendil-works\pi-coding-agent\docs\{usage,extensions,tui,settings}.md` 及 `examples/extensions/{status-line,notify,subagent,overlay-qa-tests}.ts`
- `~/.pi/agent/{settings.json,skills/(空),extensions/(空)}`

**测试/命令证据**
- `npm ci` → exit 0，自动 build 出 `dist/`
- `npm test` → 140 定义，136 ✔，4 ✖（均在 `test/stage-prompt.test.ts`，Windows 路径）
- `test/fixtures/fake-pi.sh` + `test/helpers.ts`（`FAKE_PI_MODE` 六种模式）

---

## 6. 复现状态

| 项 | 状态 | 说明 |
|----|------|------|
| build | **reproduced** | `npm ci` 触发 `tsc`，exit 0，`dist/server.js` 生成 |
| test | **reproduced (4 failures)** | 4 例 Windows 路径断言失败，位置与原因见 F6.2；与本次瘦身无关 |
| 工具面 | **reproduced** | `src/server.ts` 直接枚举 12 工具 |
| pi-worker 依赖 | **reproduced** | 全盘 grep + `pi-team` 契约确认只剩 delegate/status |
| 两份 checkout 分叉 | **reproduced** | `git rev-parse HEAD` + `git diff`，live 默认 sync |
| 弹窗可行性 | **blocked** | 缺 Codex/zcode UI 能力证据；pi extension API 已有证据 |

> 未改动任何产品文件；本报告为唯一写入（`.scratch/pi-subagent-slimming/_exploration.md`）。产品仓库 `git status` 相对基线仅新增 `.scratch/pi-subagent-slimming/` 与该文件（`node_modules/`、`dist/` 被 `.gitignore` 忽略）。
