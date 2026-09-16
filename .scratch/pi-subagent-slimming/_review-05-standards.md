# Review 05 — Standards（复核最终提交 715e615）

固定点 `a777332…`；命令 `git diff a777332…HEAD`。只读复核，未改产品/测试/docs/ticket。

## Answer

无 documented-standard violation；最终仍存在 4 条 judgement-call smell，均不阻塞。

已修复（不再列为 finding）：① README.md:132-133 已明确 “superseded historical”，`scheduler rules` 口径矛盾消除；② test/stage-prompt.test.ts、test/validate.test.ts、test/validate-multifile.test.ts 已恢复且改用 `path.join` 跨平台；③ test/fixtures/fake-pi.sh 新增 `require_session`/`continuity`，test/mcp-surface.test.ts:69,95 实际要求 continuation 带 `--session-id`。

## 残留 Findings（judgement call）

1. **领域词汇**：README.md:3,5,9,12,50 与 src/server.ts:45 仍用 “task” 指代一次委派；CONTEXT.md “Run” 明列 `_Avoid_: Task`（docs/agents/domain.md 要求用该词汇）。
2. **Duplicated Code**：test/mcp-surface.test.ts:9-14 重复实现 test/helpers.ts:6-16 的 `fakePiEnv`，且 mode 集合已分叉（前者含 require_session/continuity）。
3. **Magic literal / 环境耦合**：test/mcp-surface.test.ts:11 硬编码 `C:\Progra~1\Git\bin\bash.exe`；map.md 限定 Windows，属边界内。
4. **悬空注释**：已删 docs/design-batch1.md 仍被 src/types.ts:138、src/runner/validate.ts:6、src/tools/stage-prompt.ts:4,74,97 引用。

## 已接受、不再计

- 保守残留 types/errors/stage-prompt/validate（issue 05 Answer + 用户明确接受）。
- skills/pi-subagent/* 仍引用旧工具，归 ticket 08。
- AGENTS.md 视觉/UI 暂停未触发（无 UI 变更）。

## Reproduction status

只读：`git log/diff/grep/sed`；未运行 build/test。
