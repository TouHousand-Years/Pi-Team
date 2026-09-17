# 委派模式参考（v3）

两工具协议的详细模式与示例。配合 `SKILL.md` 使用。

服务只提供 `pi_delegate` 与 `pi_status`，下面所有示例都只用这两个。

## 模式 1：单目标同步委派（默认形态）

小任务（改一个文件、加一个模块、查清一件事）：

```
pi_delegate({
  prompt: "<IOAC 自包含 prompt>",
  session: "feat-auth",
  cwd: "/proj/app",
  goal: "给 app 加认证模块",
  constraints: { noSkills: true },
  mode: "sync",
  runTimeoutMs: 240000,
})
→ { runId, status: "completed", result, ... }
```

要点：
- 首次派发必须给 `cwd` + `goal`；同名 session 的后续调用只需 `prompt`。
- `runTimeoutMs` 放在 host 300s 上限之内（≤ 240000），保证终态一定落在这次调用里返回。
- 返回的 `status` 就是终态，直接用，不要再轮询。

## 模式 2：host 自己拆阶段（B 模式）

大任务由 host 拆，工具不再替你拆。host 写 `_plan-draft.md`（`_` 开头的元数据文件 host 可写）：

```
# 阶段 1: intro        → 01-intro.html       (无依赖)
# 阶段 2: scaled-dot   → 02-scaled.html      (依赖 1)
# 阶段 3: multi-head   → 03-multihead.html   (依赖 2)
# 阶段 4: summary      → 04-summary.html     (依赖 1,2,3)
```

然后每阶段一次 sync 委派，阶段间 host 用只读工具验收：

```
# 阶段 1
pi_delegate({ session: "courseware-01", cwd, goal, mode: "sync", runTimeoutMs: 240000,
  constraints: { noSkills: true },
  prompt: `Input: /proj/courseware/_refs.md, /proj/courseware/_plan-draft.md
Objective: 产出 /proj/courseware/01-intro.html（注意力机制引入）
Action: 禁联网；只写这一个文件；先写骨架再逐节 edit
Check: 文件存在、非空、无 TODO` })
→ status:"completed" → host read 01-intro.html 验收 → 通过才发阶段 2
```

阶段 2 的 prompt 里把阶段 1 的产出写成 Input（替换 Pi 的"记忆"），不要靠 session 历史传递——重派时 session 就换了。

## 模式 3：并行 fan-out（阶段间无依赖）

host 同时发起多个 sync 调用，**总数 ≤ 4**（全局并发上限，第 5 个返回 `resource_busy`）：

```
const constraints = { noSkills: true };
await Promise.all([
  pi_delegate({ session: "courseware-02", cwd, goal, mode: "sync", runTimeoutMs: 240000, constraints, prompt: "…02…" }),
  pi_delegate({ session: "courseware-03", cwd, goal, mode: "sync", runTimeoutMs: 240000, constraints, prompt: "…03…" }),
]);
```

超过 4 个就分批，自己排队等前一批返回。并行阶段不要写同一个输出文件。

## 模式 4：派 Pi 领域审阅计划

两步拆解的第 2 步——把 `_plan-draft.md` 交给 Pi 审阅：

```
pi_delegate({
  session: "courseware-review",
  cwd, goal: "审阅课件阶段划分",
  mode: "sync",
  runTimeoutMs: 240000,
  constraints: { noSkills: true },
  prompt: `Input: /proj/courseware/_plan-draft.md, /proj/courseware/_refs.md
Objective: 产出 /proj/courseware/_plan-reviewed.md，含 verdict:
           approve | approve_with_changes | reject 及理由
Action: 禁联网；只写这一个文件；不要改 _plan-draft.md
Check: 文件存在、非空、含 verdict 字段`
})
→ host 读 verdict 自行决定是否改计划（工具不会替你改）
```

## 模式 5：长任务 async + Monitor Wait

只有明确需要后台执行、或已实测 sync 会超上限时才用 async：

```
// 1) 派发（首次 async 会等 session 握手完成才返回）
pi_delegate({ session: "long-build", cwd, goal, mode: "async", runTimeoutMs: 1800000,
  prompt: "…", constraints: { noSkills: true } })
→ { runId: "f482475e-…", status: "running" }   // 立刻记下 runId

// 2) 前三档：每次一分钟，串行
pi_status({ runId: "f482475e-…", waitTimeoutMs: 60000 })  // → running
pi_status({ runId: "f482475e-…", waitTimeoutMs: 60000 })  // → running
pi_status({ runId: "f482475e-…", waitTimeoutMs: 60000 })  // → completed / error / timeout

// 3) 若仍是 running：改三分钟一档，继续串行
pi_status({ runId: "f482475e-…", waitTimeoutMs: 180000 })
```

要点：
- **一次一个**：前一次返回后才发下一次，绝不并发发出多个等待。
- 不要传 `waitTimeoutMs ≥ 300000`（会被 host 掐断），也不要用 `0` 空转轮询。
- turn 用完三档仍在跑：把 `runId` 交回并结束该 turn，下一 turn 从三分钟档继续。不要重开 Run。
- 一分钟/三分钟档**尚未在真实 host 上实测**（历史上只有 25s 等待被跑过）。第一次使用时留意 host 是否掐断：被掐断就退回 `waitTimeoutMs: 25000`，并在报告里标注这个观察。

## 模式 6：收窄权限（危险操作隔离）

```
pi_delegate({
  session: "doc-stage", cwd, goal, mode: "sync", runTimeoutMs: 240000,
  constraints: { noSkills: true, noContextFiles: true, excludeTools: ["bash"] },
  prompt: "…纯文本生成，只允许 read/write/edit…",
})
```

`excludeTools:["bash"]` 会让 Pi 无法跑命令（只能 read/edit/write），仅用于纯文本生成阶段。
只读决策型委派（如 `pi-ultra-planner`）反过来：`excludeTools: ["read","bash","edit","write"]` + `noContextFiles: true`。

## 模式 7：评审闭环（修 Pi 的产出）

host 评审 Pi 产出只能用只读工具。发现问题后**必须委派 Pi 修**，并换新 session 名避免历史污染：

```
// host: read 发现 02-scaled.html:41 少了 scale=1/√d_k 的说明

pi_delegate({
  session: "courseware-02-fix1",
  cwd, goal: "修复 02-scaled.html",
  mode: "sync",
  runTimeoutMs: 240000,
  prompt: `评审发现 /proj/courseware/02-scaled.html:41 问题：缺少 scale=1/√d_k 的数值稳定性说明。
期望行为：在该节补一段说明，保持原有结构。
请修复，只改这个文件。`
})
→ 修完 host 再次只读评审
```

**禁止**：评审完自己 edit/write 改，或用 bash（`sed`/`echo >`）间接改。

## 模式 8：断连 / 超时恢复

sync 调用被 host 判超时（`timed out awaiting tools/call`）时，Run 没死，只是这次调用没等到结果：

```
// ❌ 错误：换个 session 再派一遍同一个 prompt
// ✅ 正确：先问同一个 runId
pi_status({ runId: "<被超时的那次 runId>", waitTimeoutMs: 60000 })
→ running  → 继续 Monitor Wait（60000 ×3，然后 180000）
→ completed → 用这个结果，不要重派
→ error / timeout → 现在终态已知，Host Session 再显式决定是否重派（用新 session 名 + 说明理由）
```

## 重派与失败处理

服务端没有自动重试、没有 attempt 升级、没有 manual 决策面板——**失败判断和重派全部由 host 做**：

| 观察到的情况 | host 该做什么 |
|--------------|---------------|
| `completed` 但产出不合格 | 委派 Pi 修（模式 7，新 session 名） |
| `error` + `code:"nonzero_exit"` | 读 Pi 输出/产出定位，改 prompt 后重派（新 session 名） |
| `error` + `code:"no_agent_end"` | Pi 没正常收尾；检查 prompt 是否过大、是否要求联网 |
| `error` + `code:"session_create_failed"` | 检查 `cwd` 是否存在、`pi` 可执行是否可用 |
| `timeout` | Run 被 `runTimeoutMs` 掐断；拆小阶段，或显式改用 async + 更长的 `runTimeoutMs` |
| `error` + `code:"stalled"` | 无进展超时；把阶段拆小，并要求 prompt 里"先骨架再逐节 edit" |
| 派发被拒：`error` + `code:"resource_busy"` | 已有 4 个 running run。**没有 Run 被创建**，这次调用没产生任何 runId；排队后重新派发 |

前六行是 Run 的终态（`pi_status` 或 sync 返回里能看到）；最后一行的 `resource_busy` 在委派被受理之前就抛出，所以它不是 Run 的状态，也不会有 `runId` 可以收割。

重派原则：换新 session 名、在 prompt 里写清上次为什么失败、连续 2 次同类失败就停下来向人报告，不要第 3 次原样重试。
