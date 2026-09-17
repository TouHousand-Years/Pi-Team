import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, join, resolve } from "node:path";
import { REMOVED_TOOLS, SUPPORTED_TOOLS } from "./skill-surface.js";

const REPO_SKILL_DIR = resolve("skills/pi-subagent");
const LIVE_TOOLS: string[] = [...SUPPORTED_TOOLS];
const RETIRED_TOOLS: string[] = [...REMOVED_TOOLS];

// Vocabulary that only made sense against the retired task/stage tool surface.
const RETIRED_VOCABULARY = [
  { label: "stage promptHint", pattern: /promptHint/i },
  { label: "stage orchestration tools", pattern: /task stages?|stage tools?|stage_run/i },
  { label: "manual decision panel", pattern: /manual decision panel|decision panel with/i },
];

// Matches the number only when it stands alone, so 600000 and 1800000 do not count.
const exactly = (value: number) => new RegExp(`(?<!\\d)${value}(?!\\d)`);

interface Doc {
  path: string;
  text: string;
}

interface InstalledSkill {
  name: string;
  files: Doc[];
  corpus: string;
}

function readAll(dir: string): Doc[] {
  const files: Doc[] = [];
  const visited = new Set<string>();
  const walk = (current: string) => {
    let real: string;
    try {
      if (!statSync(current).isDirectory()) return;
      real = realpathSync(current);
    } catch {
      return;
    }
    if (visited.has(real)) return;
    visited.add(real);
    for (const entry of readdirSync(current)) {
      const full = join(current, entry);
      let isDir = false;
      try {
        isDir = statSync(full).isDirectory();
      } catch {
        continue;
      }
      if (isDir) {
        walk(full);
      } else if (entry.endsWith(".md")) {
        files.push({ path: full, text: readFileSync(full, "utf8") });
      }
    }
  };
  walk(dir);
  return files;
}

function corpusOf(files: Doc[]): string {
  return files.map((file) => file.text).join("\n");
}

function repoDocs(): { files: Doc[]; skill: Doc; corpus: string } {
  const files = readAll(REPO_SKILL_DIR);
  assert.ok(files.length >= 3, `expected SKILL.md plus references, found ${files.length} files`);
  const skill = files.find((file) => file.path.endsWith("SKILL.md"));
  assert.ok(skill, "skills/pi-subagent/SKILL.md must exist");
  return { files, skill, corpus: corpusOf(files) };
}

// A removed tool name is only a defect where the document asks the reader to call it.
function callShapedMentions(text: string, names: string[]): string[] {
  return names.filter((name) => new RegExp(`\\b${name}\\s*\\(`).test(text));
}

function namedPiTokens(text: string): string[] {
  return [...new Set(text.match(/\bpi_[a-z_]+\b/g) ?? [])].sort();
}

/** A wait the document tells the reader to send, read as `waitTimeoutMs: <n>`. */
function statedWaits(corpus: string): number[] {
  return [...corpus.matchAll(/waitTimeoutMs\s*[:：]\s*`?(\d+)/g)].map((match) => Number(match[1]));
}

/** Installed pi-* skills outside this repository, discovered the way the hosts install them. */
function installedSpecializedSkills(): InstalledSkill[] {
  const roots = (process.env.PI_SKILL_ROOTS ?? "")
    .split(delimiter)
    .filter(Boolean)
    .concat([join(homedir(), ".zcode", "skills"), join(homedir(), ".skills-manager", "skills")]);

  const found = new Map<string, InstalledSkill>();
  for (const root of roots) {
    let entries: string[];
    try {
      entries = readdirSync(root);
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (!entry.startsWith("pi-") || entry === "pi-subagent" || found.has(entry)) continue;
      const dir = join(root, entry);
      try {
        if (!statSync(dir).isDirectory()) continue;
      } catch {
        continue;
      }
      const files = readAll(dir);
      if (files.length > 0) found.set(entry, { name: entry, files, corpus: corpusOf(files) });
    }
  }
  return [...found.values()];
}

const installed = installedSpecializedSkills();
const installedSkipReason = installed.length === 0
  ? "no installed pi-* skills found (checked $PI_SKILL_ROOTS, ~/.zcode/skills, ~/.skills-manager/skills)"
  : false;

test("the repository Pi skill drops the retired tool surface", () => {
  const { files, skill } = repoDocs();

  for (const name of LIVE_TOOLS) {
    assert.ok(
      namedPiTokens(skill.text).includes(name),
      `SKILL.md must document the live tool ${name}`,
    );
  }

  for (const file of files) {
    assert.deepEqual(
      callShapedMentions(file.text, RETIRED_TOOLS),
      [],
      `${file.path} asks the reader to call a retired tool`,
    );
  }

  // The skill must actively warn that retired names fail, so stale memory does not retry them.
  assert.match(skill.text, /unknown tool/i);
});

test("the repository Pi skill states the sync-first fallback contract", () => {
  const { skill, corpus } = repoDocs();

  assert.match(skill.text, /mode\s*:\s*"sync"/, "sync must be the documented default");
  assert.match(skill.text, /mode\s*:\s*"async"/, "async must remain available as the fallback");
  assert.match(skill.text, exactly(240000), "sync calls must state a deadline under the host's 300s cap");

  // Monitor Wait schedule: three one-minute waits, then three-minute waits, in that order.
  // SKILL.md is the always-loaded contract, so it has to carry the schedule itself.
  const waits = statedWaits(skill.text);
  assert.ok(waits.includes(60000), "SKILL.md must state the one-minute Monitor Wait");
  assert.ok(waits.includes(180000), "SKILL.md must state the three-minute Monitor Wait");
  assert.ok(
    skill.text.indexOf("waitTimeoutMs: 60000") < skill.text.indexOf("waitTimeoutMs: 180000"),
    "the one-minute waits must be documented before the three-minute waits",
  );
  assert.match(skill.text, /最多三次|three consecutive|at most three/i, "the one-minute stage must be capped at three waits");
  assert.ok(
    waits.every((wait) => wait <= 180000),
    `no documented wait may reach the host's 300s ceiling: ${waits.join(", ")}`,
  );

  assert.match(skill.text, /不重叠|never overlap/i, "Monitor Waits must be documented as non-overlapping");
  assert.match(skill.text, /waitTimeoutMs\s*[:：]?\s*0/, "zero-time polling must be called out as forbidden");

  // A sync disconnect never auto-redispatches; the same runId is collected instead.
  assert.ok(
    /绝不自动重派|never auto-redispatch/.test(skill.text),
    "the no-auto-redispatch rule is missing",
  );
  assert.match(skill.text, /runId/, "the recovery rule must name the runId it collects");

  // The reference must carry worked examples of the same schedule, not a different one.
  assert.ok(statedWaits(corpus).includes(60000) && statedWaits(corpus).includes(180000));
  const docWaits = statedWaits(corpus);
  assert.ok(
    docWaits.every((wait) => wait <= 180000),
    `no documented wait may reach the host's 300s ceiling: ${docWaits.join(", ")}`,
  );
});

test("every installed specialized Pi skill stays compatible with the two-tool server", { skip: installedSkipReason }, () => {
  for (const { name, files, corpus } of installed) {
    const skill = files.find((file) => file.path.endsWith("SKILL.md"));
    assert.ok(skill, `${name} has no SKILL.md`);

    assert.match(
      skill.text,
      /mcps:\s*\[\s*"pi-subagent"\s*\]/,
      `${name} must declare the pi-subagent MCP requirement`,
    );

    for (const retired of RETIRED_TOOLS) {
      assert.ok(
        !new RegExp(`\\b${retired}\\b`).test(corpus),
        `${name} still references the retired tool ${retired}`,
      );
    }

    assert.deepEqual(
      namedPiTokens(corpus).filter((token) => !LIVE_TOOLS.includes(token)),
      [],
      `${name} names tools outside the two-tool server`,
    );

    for (const { label, pattern } of RETIRED_VOCABULARY) {
      assert.ok(!pattern.test(corpus), `${name} still uses retired vocabulary: ${label}`);
    }

    // The skill must reach the shared transport contract instead of assuming one.
    assert.match(corpus, /pi-team|pi_delegate/, `${name} does not reference a delegation contract`);
  }

  // The family's shared contract skill is the one that must name both tools.
  const shared = installed.find(({ name }) => name === "pi-team");
  assert.ok(shared, "pi-team must be installed alongside the specialized skills");
  for (const tool of LIVE_TOOLS) {
    assert.match(shared.corpus, new RegExp(`\\b${tool}\\b`), `pi-team must document ${tool}`);
  }
});

test("installed skills that collect asynchronously use the Monitor Wait schedule", { skip: installedSkipReason }, () => {
  const collecting = installed.filter(({ corpus }) => /\bpi_status\b/.test(corpus));
  assert.ok(collecting.length > 0, "expected at least one installed skill to describe async collection");

  for (const { name, corpus } of collecting) {
    const waits = statedWaits(corpus);
    assert.ok(waits.includes(60000), `${name} must state the one-minute Monitor Wait`);
    assert.ok(waits.includes(180000), `${name} must state the three-minute Monitor Wait`);
    assert.ok(
      waits.every((wait) => wait <= 180000),
      `${name} must not state a wait at or above the host's 300s ceiling: ${waits.join(", ")}`,
    );
    assert.match(
      corpus,
      /never (issue|overlap)|non-overlapping|不重叠/i,
      `${name} must state that Monitor Waits never overlap`,
    );
    assert.match(
      corpus,
      /never re-?dispatch|not stopped the Run|绝不自动重派/i,
      `${name} must state that a disconnected sync call is not re-dispatched`,
    );
  }
});
