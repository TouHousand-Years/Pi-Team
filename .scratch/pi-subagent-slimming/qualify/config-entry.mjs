// Shared, strict reader/writer for the one config block this project owns:
// `[mcp_servers.pi-subagent]` (plus its `.env` sub-table) in ~/.codex/config.toml.
//
// This lives in one place on purpose. Two copies of it existed briefly and they
// already diverged once: one of them broke on the `.env` sub-table header and hid
// PI_BIN, which made a working service look like it could not spawn Pi at all.
import { readFileSync } from "node:fs";

export function tomlString(raw) {
  const t = raw.trim();
  if ((t.startsWith("'") && t.endsWith("'")) || (t.startsWith('"') && t.endsWith('"'))) return t.slice(1, -1);
  return t;
}

function isEnvHeader(line) {
  return /^\s*\[mcp_servers\.pi-subagent\.env\]\s*$/.test(line);
}

// Line range of the entry: header + 1 .. the line before the next unrelated table.
export function blockRange(text) {
  const lines = text.split("\n");
  const start = lines.findIndex((l) => /^\[mcp_servers\.pi-subagent\]\s*$/.test(l));
  if (start < 0) throw new Error("no [mcp_servers.pi-subagent] section");
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^\s*\[/.test(lines[i]) && !isEnvHeader(lines[i])) { end = i; break; }
  }
  return { lines, start, end };
}

export function parseEntry(text) {
  const { lines, start, end } = blockRange(text);
  const out = { command: undefined, args: [], env: {}, toolTimeoutSec: undefined, changed: false };
  let inEnv = false;
  let argsLineIndex = -1;
  for (let i = start + 1; i < end; i++) {
    const line = lines[i];
    if (isEnvHeader(line)) { inEnv = true; continue; }
    const kv = /^\s*([A-Za-z_][\w.]*)\s*=\s*(.*?)\s*$/.exec(line);
    if (!kv) continue;
    const [, key, value] = kv;
    if (inEnv) { out.env[key] = tomlString(value); continue; }
    if (key === "command") out.command = tomlString(value);
    else if (key === "args") {
      argsLineIndex = i;
      const inner = value.replace(/^\[/, "").replace(/\]$/, "").trim();
      out.args = inner ? inner.split(",").map((p) => tomlString(p)) : [];
    } else if (key === "tool_timeout_sec") out.toolTimeoutSec = Number(value);
  }
  out.argsLineIndex = argsLineIndex;
  return out;
}

export function serverPath(text) {
  return parseEntry(text).args[0];
}

// Replace only args[0]; any additional argv elements are preserved verbatim.
export function rewriteServerPath(text, newServerPath) {
  const { lines, start, end } = blockRange(text);
  const current = parseEntry(text);
  if (current.argsLineIndex < 0 || current.argsLineIndex >= end) {
    throw new Error("no args line inside [mcp_servers.pi-subagent]");
  }
  const rest = current.args.slice(1).map((a) => `'${a}'`).join(", ");
  lines[current.argsLineIndex] = `args = ['${newServerPath}'${rest ? `, ${rest}` : ""}]`;
  return lines.join("\n");
}

export function readEntry(path) {
  return parseEntry(readFileSync(path, "utf8"));
}
