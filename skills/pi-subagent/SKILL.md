---
name: pi-subagent
version: 3.0.0
description: "把 Pi 当编程子代理。服务只提供 pi_delegate 与 pi_status 两个工具：同步委派优先，async 仅作兼容兜底，Monitor Wait 收割，断连绝不自动重派。host 负责拆分与联网，Pi 负责落盘编码。"
metadata:
  requires:
    mcps: ["pi-subagent"]
---

# pi-subagent v3 — 两工具委派协议

把 Pi 当作**可委派的编程子代理**。核心分工：host 负责**拆分 + 不可控 I/O（联网）**，Pi 负责**可控的编码/写作**（禁联网、专注落盘）。

## 工具面：只有两个

| 工具 | 用途 |
|------|------|
| `pi_delegate` | 派一次 Run。单目标任务一律 `mode:"sync"` |
| `pi_status` | 取某个 Run 的终态（占用式 long-poll / Monitor Wait） |

`pi_kill` / `pi_plan` / `pi_session_*` / `pi_task_*` **已从服务移除**，调用会返回 `unknown tool`。
不要生成这些名字，也不要照着旧文档/旧案例里的 `pi_task_create`、`pi_task_stage_run` 调用——它们不存在。

**`pi_delegate` 参数**：`prompt`（必填）、`session`（必填）、`cwd`、`goal`、`constraints`、`mode`（`"sync"` | `"async"`）、`runTimeoutMs`、`allowUnknownTools`。
**`pi_status` 参数**：`runId`（必填）、`waitTimeoutMs`。

首次派发一个 session 必须给 `cwd` + `goal`；之后同名 session 自动续接，只需给 `prompt`。

## 四条铁律

1. **不可控 I/O 收回 host（C 模式）**：联网搜索、外部 API 调用由 host（你/ZCode）做，结果写进任务目录的 `_refs.md`。**绝不让 Pi 自己联网**——它会绕圈（实测：UltimateSearch skill 会诱导 Pi 反复搜索）。
2. **大任务由 host 拆分（B 模式）**：不再有 `pi_task_create` 替你拆阶段。host 自己写 `_plan-draft.md`，把大任务拆成"每阶段产出一个独立文件"的若干次 `pi_delegate`，并在阶段之间验证。
3. **每次派发都由 host 显式传 `constraints.noSkills:true`**：服务端默认是 `false`，不传就等于不禁 skill。禁 skill 是防联网诱导的必要条件。保留 bash/read/edit/write 让 Pi 干活。专用 skill 明确要求别的约束时，取更严的那个。
4. **代码修改权单一归属 Pi（一刀切）**：任务 cwd 下的**代码文件**（.ts/.js/.html/.css/.py/.go 等任何 Pi 的产出），**只有 Pi 有权修改**。host 评审时**只能用只读工具**（read/grep/glob/pi_status），发现任何问题——哪怕一个 typo、一个缺 import——都**禁止自己 edit/write/bash 改**，必须委派 Pi 修。详见下方「代码修改权」节。

## 标准流程

```
1. host 判断：要不要外部数据？
   ├─ 要 → host 自己联网 → 写 <cwd>/_refs.md
   └─ 不要 → 跳过

2. host 拆任务 → 写 <cwd>/_plan-draft.md（章节划分 + 每阶段目标/输入/输出/依赖）
   （需要 Pi 领域审阅时，把 _plan-draft.md 作为一次 sync 委派交给 Pi 审阅，
     审阅结论落 _plan-reviewed.md；host 读完自己决定是否改计划——工具不会替你改）

3. 逐阶段执行：pi_delegate({session, prompt, cwd, goal, mode:"sync",
                              runTimeoutMs: 240000, constraints:{noSkills:true}})
   （cwd + goal 只在首次建立该 session 时必填，续接时省略）
   → Pi 落盘该阶段文件，返回终态

4. host 读返回的 status/result + 用只读工具验收产出文件
   → 不合格：委派 Pi 修（见「评审发现问题后必须这么做」），不要自己改
   → 合格：进入下一阶段

5. 全部阶段完成 → host 汇总；若某阶段反复失败，向人报告卡点
```

## 同步优先（sync 是正常路径）

- 单目标、有界的工作一律 `mode:"sync"`：Pi 完成时该次 MCP 调用直接返回终态（`completed` / `error` / `timeout`），host 无需轮询。
- **`runTimeoutMs` 传 ≤ 240000**。Codex 对单次 MCP `tools/call` 有 **300s 硬上限**（未配 `tool_timeout_sec` 时的实测值），而服务端默认 `runTimeoutMs` 是 600000——比上限还大。把 Run 自己的死线放在上限之内，host 才一定拿到终态，而不是"调用被掐断、Run 还在跑"。
- 任务确实可能要跑更久时，host 必须**显式选一条路径**：
  - 调大 `runTimeoutMs` 并接受 host 会在 300s 掐断这次调用（Run 继续跑，之后用同一 `runId` 的 `pi_status` 收割），或
  - 改用 `mode:"async"` 并走 Monitor Wait（见下）。
- sync 返回的 `status` 就是终态，按它分流，不要再对同一个 Run 轮询。

## async 兜底（仅在明确需要时）

用 `mode:"async"` 只在这两种情况：

- 专用 skill 明确要求后台执行、fan-out 或多阶段并行；
- 已实测同类任务会超过 host 上限，且 host 接受异步收割。

派发时**写明理由**，并立刻记下返回的 `runId`——它是之后唯一的收割句柄。async 首次派发会等 Pi 的 session 握手完成才返回，所以返回的 `runId` 一定对应一个已建立的 Pi Session。

## Monitor Wait（收割 async Run）

`pi_status` 是**占用式 long-poll**，不是快照轮询。收割一个 async Run：

| 顺序 | `waitTimeoutMs` | 说明 |
|------|-----------------|------|
| 第 1–3 次 | `waitTimeoutMs: 60000` | 最多三次一分钟等待 |
| 第 4 次起 | `waitTimeoutMs: 180000` | 每次三分钟，直到终态 |

- **串行，绝不重叠**：前一次 `pi_status` 返回后才发下一次。host 本身允许并行工具调用，所以"不重叠"是 Host Session 自己的纪律，不是传输层保证。
- 每次返回 `status:"running"` → 按下一档继续；返回终态（`completed` / `error` / `timeout`）→ 停止，不要再调。
- `60000` / `180000` 都低于 host 的 300s 单次上限，但**只有 25s 等待在 host 上被实测过**：一分钟/三分钟档是按"低于上限"推断安全，尚未在真实 host 上跑过。这是本档位唯一未验证的假设——若 host 掐断了 `waitTimeoutMs: 60000`，回退到 25s 档并在报告里标注。**不要**传 `≥ 300000` 的 `waitTimeoutMs`，那必然被 host 掐断。
- **不要**用 `waitTimeoutMs:0` 空转轮询，也不要自己写定长 sleep 循环——等待本身就是收集动作。
- 一个 host turn 里用完了三档还没到终态：把 `runId` 交回并结束该 turn，下一 turn 从三分钟档继续。**不要重开 Run**，也不要因为"这一轮没拿到结果"就重派。
- 收割以 `runId` 为单位，不读 session 历史累加进度。

## 断连与超时：绝不自动重派

- sync `pi_delegate` 被 host 判超时（错误里带 `timed out awaiting tools/call`）或被断开，**不等于 Run 失败**。服务端 Run 不受影响，仍在跑，终态照样记录。
- 唯一正确的下一步是：`pi_status` **同一个 `runId`**。不要新建 Run，不要把同一个 prompt 再派一遍。
- 只有当前 Run 的**终态已知**之后，Host Session 才能**显式决定**是否重派。重派要用新的 session 名，并说明为什么重派。
- "再派一次试试" 永远不是错误处理方式。

## IOAC prompt 原则（host 自己写，工具不再代生成）

每次委派的 prompt 都要自包含，按 IOAC 组织：

- **Input**：读哪些文件（绝对路径），替代 Pi 的"记忆"
- **Objective**：这次产出什么（一句话可验证）
- **Action 约束**：禁联网、只写指定输出文件、先落盘骨架再逐节补全
- **Check**：验收标准（文件存在 + 非空 + 无 TODO，或可执行的检查命令）

## 命名约定

| 对象 | 约定 | 示例 |
|------|------|------|
| session | `<topic>-<stage>` 或 `<topic>`，重派换新名 | `attention-courseware-01` |
| 文件 | `_refs.md` / `_plan-draft.md` / `_plan-reviewed.md` / `<阶段>-<slug>.html` | `02-scaled.html` |

## 反模式（禁止）

- ❌ 让 Pi 自己联网（用 UltimateSearch 等）—— 会绕圈。host 先做 I/O 写 `_refs.md`。
- ❌ 一次性委派大任务不拆 —— host 自己写 `_plan-draft.md` 拆阶段。
- ❌ 委派后不读结果 —— 每阶段看 `status`，`error`/`timeout` 要处理。
- ❌ **调用已移除的工具** —— `pi_task_*` / `pi_session_*` / `pi_plan` / `pi_kill` 都不存在；生成这些名字或照着旧文档调用，只会拿到 `unknown tool`。
- ❌ **sync 调用被超时就重派** —— 先 `pi_status` 同一个 `runId`（见「断连与超时」）。
- ❌ 用 `waitTimeoutMs:0` 空转轮询或自建 sleep 循环 —— 用 Monitor Wait。
- ❌ 工具调用失败后机械重试 —— 工具返回错误时，必须先诊断"是否调错了工具 / 参数是否合理"，而不是原样或微调重试。特别警惕：① 生成错误工具名（把 `pi_delegate` 串成任务里根本不存在的工具）；② 用占位符（example.com / "test"）喂工具。任何工具连续失败 2 次即停止、回到上层重新规划，绝不在自然语言里"一边说要停一边继续重试"。
- ❌ **host 自己改代码** —— 评审 Pi 产出后发现 bug / 缺功能 / typo，禁止用 edit/write/bash 直接改。host 在代码文件上**只能 read/grep**，任何修改（无大小）必须委派 Pi。违反此条 = 角色越界，会导致 host 与 Pi 对同一文件理解分叉、git 历史混淆、Pi 后续 delegate 覆盖 host 改动。
- ❌ host 用 bash 间接改代码 —— `sed`/`echo >`/`cat >` 等通过 shell 改代码文件，和用 edit 改**性质完全相同**，同样禁止。

## 代码修改权（一刀切，最高优先级）

**任务 cwd 下的代码文件，只有 Pi（通过 `pi_delegate`）有权修改。**

这是角色边界，不是效率取舍——即便 host 改一个 typo 只要 5 秒、委派 Pi 要 30 秒，也必须委派 Pi。原因：
- **单一修改者**：git 历史清晰（改动都来自 Pi），评审/回滚不混淆。
- **防分叉**：host 改了一处，Pi 下次 delegate 读到时不知道谁改的，可能覆盖或冲突。
- **职责不混岗**：host 做"判断"（评审/规划），Pi 做"执行"（改代码），不混。

### 文件归属判定

| 文件类型 | 谁可改 | 例子 |
|---------|--------|------|
| **代码/产出文件** | **只有 Pi** | `.ts/.js/.html/.css/.py/.go/.rs/.java` 等任何阶段的输出文件，以及 Pi 已产出的任何代码 |
| **元数据文件（`_` 开头）** | host 和 Pi 都可改 | `_plan-draft.md` / `_refs.md` / `_plan-reviewed.md` / `_skeleton.md` |
| **本项目自身代码**（pi-subagent 仓库） | 不在本规则范围 | 这是开发 pi-subagent 本身时的事，不影响任务编排 |

### host 评审时的合法工具

评审 Pi 的产出时，host **只能用只读工具**：
- ✅ `read` / `grep` / `glob`（看代码）
- ✅ `pi_status`（看 Run 终态）
- ❌ `edit` / `write`（改代码文件）
- ❌ `bash`（跑 sed/echo > 等改代码）

### 评审发现问题后必须这么做

无论问题大小（typo / bug / 缺功能 / 重构建议）：
1. 用只读工具定位问题（哪行、什么错、期望行为）
2. **委派 Pi 修**——新 session（如 `<topic>-fix1`），prompt 写清：
   ```
   评审发现 <文件:行号> 问题：<具体描述>
   期望行为：<xxx>
   请修复，只改这个文件。
   ```
3. 等 Pi 修完，**再次评审**（仍只用只读工具）。

**禁止**：评审完自己上手改、评审时顺手 edit、用 bash 改、补充 Pi 没写的功能。

## 重要行为说明（实测得出）

**并发上限（硬限制）：**
- `pi_delegate` **全局并发上限 4** 个 running run；第 5 个返回 `resource_busy`。
- 需要并行时就同时发最多 4 个 sync 调用；超过 4 个 host 自己排队，不要无脑 Promise.all >4 个。

**session 复用与隔离：**
- 同名 session 多次 delegate 会**累积 progress**（session 是连续对话）。
- **重派失败任务时用新 session 名**（如 `math-2`、`frontier-3`），避免历史 progress 混入。
- `pi_status(runId)` 返回的是**单次 Run 的结果**（Run 级隔离），不受 session 历史影响——收割一律用 `runId`。

**约束（`constraints`）：**
- `noSkills:true` 禁 Pi 的所有 skill（默认建议开）；`noContextFiles:true` 禁 AGENTS.md/CLAUDE.md。
- `tools` / `excludeTools` 只认内置工具名 `read` / `bash` / `edit` / `write`；写别的名字会被拒（`unknown_tool`），确实需要时用 `allowUnknownTools:true`。
- `model` / `thinking` 原样透传给 Pi；专用 skill 的 `pi-model.json` 要求什么就传什么。

**Run 的证据：**
- `pi_status` 返回**终态**时带 `transcript`（该 Run 完整过程记录的可用性/完整性摘要）；Run 仍在 `running` 的返回不带这个字段，存储不可用时也不带。
- `pi_status` 只报告状态与结果，不是完成通知；完成由 host 在拿到终态后自行判断与转述。

**工具名生成后自检（防串名事故）：**
- 调用工具前，确认该工具名在 `pi_delegate` / `pi_status` 之内。
- 若发现调用的工具与本任务无关（领域不匹配 / 用了占位符参数），视为 token 串名事故，**立即停止**，重新核对工具清单后再调。一次错误调用就停，不要重试。

**失败即停原则：**
- 任何工具调用返回 error（业务错误码 / timeout），第一反应是"诊断"而非"重试"：检查①工具名对不对 ②参数是否真实合理（非占位符）③是否在正确的上下文。
- 连续 2 次同类失败 → 强制回到上层规划，重新拆解，禁止第 3 次原样重试。
- 自然语言与工具调用必须一致：若已口头承认"这是误操作"，则后续禁止再发起同一错误调用。

**stall 与长内容生成：**
- Pi 生成长内容（>5KB HTML）时，"构思全文"阶段无 tool 调用，可能被判 stalled。
- prompt 里强制"先骨架 → 逐节 edit"节奏（每步都调 tool 保持进度）。
- 仍会 stall 时，host 把该阶段再拆小，而不是调大时限。

## 专用 Pi skill 家族

`pi-team` / `pi-worker` / `pi-explorer` / `pi-ultra-planner` / `pi-translator` 共用 `pi-team` 的委派契约，同样只使用 `pi_delegate` 与 `pi_status`。需要那类流水线时按对应 skill 走，本 skill 只提供底层委派纪律。

详细模式与示例见 `references/delegation-patterns.md`。
工具调用循环事故案例见 `references/tool-call-loop-antipattern.md`。
