import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { validateFile } from "../src/runner/validate.js";
import type { ValidateRule } from "../src/types.js";

const DIR = join(tmpdir(), "pi-sub-validate-" + process.pid);
mkdirSync(DIR, { recursive: true });

test("file_exists: 文件不存在 → fail", async () => {
  const r = await validateFile(join(DIR, "nope.html"), [{ kind: "file_exists" }]);
  assert.equal(r.passed, false);
  assert.equal(r.failedRule?.kind, "file_exists");
});

test("file_exists: 文件存在 → 该规则 pass", async () => {
  const f = join(DIR, "a.html");
  writeFileSync(f, "hello");
  const r = await validateFile(f, [{ kind: "file_exists" }]);
  assert.equal(r.passed, true);
});

test("file_nonempty: 空文件 → fail", async () => {
  const f = join(DIR, "empty.html");
  writeFileSync(f, "");
  const r = await validateFile(f, [{ kind: "file_nonempty" }]);
  assert.equal(r.passed, false);
  assert.equal(r.failedRule?.kind, "file_nonempty");
});

test("contains: 含指定文本 → pass", async () => {
  const f = join(DIR, "c.html");
  writeFileSync(f, "<h1>Title</h1>");
  const r = await validateFile(f, [{ kind: "contains", pattern: "<h1>" }]);
  assert.equal(r.passed, true);
});

test("contains: 缺指定文本 → fail", async () => {
  const f = join(DIR, "c2.html");
  writeFileSync(f, "<p>no heading</p>");
  const r = await validateFile(f, [{ kind: "contains", pattern: "<h1>" }]);
  assert.equal(r.passed, false);
});

test("not_contains: 含 TODO → fail", async () => {
  const f = join(DIR, "todo.html");
  writeFileSync(f, "<h1>X</h1>\n<!-- TODO: fill -->");
  const r = await validateFile(f, [{ kind: "not_contains", pattern: "TODO" }]);
  assert.equal(r.passed, false);
});

test("regex: 匹配 → pass", async () => {
  const f = join(DIR, "re.html");
  writeFileSync(f, "<html>...</html>");
  const r = await validateFile(f, [{ kind: "regex", pattern: "<html>[\\s\\S]*</html>" }]);
  assert.equal(r.passed, true);
});

test("默认规则: 文件存在+非空+无TODO 全过", async () => {
  const f = join(DIR, "good.html");
  writeFileSync(f, "<html><h1>Done</h1></html>");
  const r = await validateFile(f);  // 不传规则 → 用默认
  assert.equal(r.passed, true);
});

test("默认规则: 含 TODO → fail", async () => {
  const f = join(DIR, "bad.html");
  writeFileSync(f, "TODO later");
  const r = await validateFile(f);
  assert.equal(r.passed, false);
  assert.equal(r.failedRule?.kind, "not_contains");
});

test("多条规则: 第一条 fail 即止，返回失败的那条", async () => {
  const f = join(DIR, "multi.html");
  writeFileSync(f, "x");
  const rules: ValidateRule[] = [
    { kind: "file_exists" },
    { kind: "contains", pattern: "<h1>" },  // 这条会 fail
    { kind: "not_contains", pattern: "TODO" },
  ];
  const r = await validateFile(f, rules);
  assert.equal(r.passed, false);
  assert.equal(r.failedRule?.kind, "contains");
});

test("run_check: node 语法正确 → pass", async () => {
  const f = join(DIR, "ok.js");
  writeFileSync(f, "const x = 1;\nconsole.log(x);\n");
  const r = await validateFile(f, [{ kind: "run_check", pattern: "node" }]);
  assert.equal(r.passed, true);
});

test("run_check: node 语法错误 → fail", async () => {
  const f = join(DIR, "bad.js");
  writeFileSync(f, "const x = ;\n");
  const r = await validateFile(f, [{ kind: "run_check", pattern: "node" }]);
  assert.equal(r.passed, false);
  assert.equal(r.failedRule?.kind, "run_check");
});

// 清理
test.after(() => {
  rmSync(DIR, { recursive: true, force: true });
});
