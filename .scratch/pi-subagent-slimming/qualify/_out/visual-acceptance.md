# Ticket 09 — human visual acceptance of the production Run Window

Generated 2026-09-17T03:59:02.186Z by `qualify/visual.mjs`.

Three real Run Windows are open on this desktop, each produced by the real
`pi_delegate` → `src/viewer/manager.ts` → `viewer/run-window.ps1` path with the real
Pi 0.85.1 CLI. They stay open until closed by hand; the MCP server backing them is
held alive for 240 minutes.

## Windows on screen

| Window | Run id | Transcript | Verdict the window should show |
| --- | --- | --- | --- |
| SUCCEEDED — multibyte glyph coverage, thinking/tool/answer/usage | `5bd5ed80-e977-44ce-9322-34cbfb78a80b` | `C:\Users\qnhxx\AppData\Local\Temp\pi-subagent-qualify\2026-09-17T03-58-35-623Z\visual\runs\5bd5ed80-e977-44ce-9322-34cbfb78a80b` | SUCCEEDED (integrity true) |
| RUNNING — live tailing, fragment suppression, mid-stream continuity | `260fe50e-905f-45ea-aa8e-78388cca2fad` | `C:\Users\qnhxx\AppData\Local\Temp\pi-subagent-qualify\2026-09-17T03-58-35-623Z\visual\runs\260fe50e-905f-45ea-aa8e-78388cca2fad` | RUNNING (integrity false) |
| INCOMPLETE — terminal status colour and warning presentation | `33140f22-c0f4-4018-bbae-212eef554903` | `C:\Users\qnhxx\AppData\Local\Temp\pi-subagent-qualify\2026-09-17T03-58-35-623Z\visual\runs\33140f22-c0f4-4018-bbae-212eef554903` | INCOMPLETE (integrity true) |

`integrityOk: false` with reason `no-terminal-record` on the **RUNNING** window is
the expected verdict for a Run that has not finished — it must not invent completion.

## What to check (the part no script can decide)

1. **Glyphs** — in the SUCCEEDED window look for the prompt line and Pi's answer:
   `GLYPHS 中文测试 — 日本語テスト — emoji 🎯🚀 — math ∑∆π≈1.414 — box ┌─┐└─┘ — accents éüñ`
   CJK, emoji, math symbols, box drawing and accents must all be readable — no
   boxes, no mojibake, no U+FFFD replacement characters.
2. **Complete titles** — each title bar shows `[TOKEN] Pi — <session> — <prompt> — <run id>`
   with the full Run id, not a truncation.
3. **Formatted-only, no duplication** — the SUCCEEDED and RUNNING windows must show each
   payload exactly once: prompt, launch metadata, lifecycle lines, thinking, tool call,
   tool result, the answer, usage. There must be no raw-JSON second copy and no
   `message_update` fragment spam while the Run is healthy.
4. **Mid-stream** — in the RUNNING window, confirm the stream keeps advancing and that
   nothing already-rendered is re-rendered as new bytes arrive.
5. **Terminal presentation** — SUCCEEDED and INCOMPLETE must be visually distinct
   (status colour and word), and the INCOMPLETE window must say why rather than claim
   success.
6. **Read-only** — scrolling, selection, copy and the wrap toggle work; nothing can send
   input, retry or cancel.

## Machine-checked facts to compare against (same bundles)

```json
[
  {
    "label": "SUCCEEDED — multibyte glyph coverage, thinking/tool/answer/usage",
    "runId": "5bd5ed80-e977-44ce-9322-34cbfb78a80b",
    "token": "SUCCEEDED",
    "integrityOk": true,
    "reasons": [],
    "records": 69,
    "expected": "d27c8b471656501db92cfe17bba9cfddfb3a36d6b007dc143687f7ae7b7d287f",
    "computed": "d27c8b471656501db92cfe17bba9cfddfb3a36d6b007dc143687f7ae7b7d287f"
  },
  {
    "label": "RUNNING — live tailing, fragment suppression, mid-stream continuity",
    "runId": "260fe50e-905f-45ea-aa8e-78388cca2fad",
    "token": "RUNNING",
    "integrityOk": false,
    "reasons": [
      "no-terminal-record"
    ],
    "records": 46,
    "expected": null,
    "computed": ""
  },
  {
    "label": "INCOMPLETE — terminal status colour and warning presentation",
    "runId": "33140f22-c0f4-4018-bbae-212eef554903",
    "token": "INCOMPLETE",
    "integrityOk": true,
    "reasons": [],
    "records": 48,
    "expected": "d5f995627f030e499b7e7b74dbd300e747e9fa7d84dbe4fa22fe46673436b08c",
    "computed": "d5f995627f030e499b7e7b74dbd300e747e9fa7d84dbe4fa22fe46673436b08c"
  }
]
```

Rendered transcript text for each bundle (what the window should be showing, byte for
byte, produced by the same formatter in `-Replay` mode):
- `C:\Users\qnhxx\Documents\AI-Projects\Code\pi-subagent\.scratch\pi-subagent-slimming\qualify\_out\visual\SUCCEEDED.txt`
- `C:\Users\qnhxx\Documents\AI-Projects\Code\pi-subagent\.scratch\pi-subagent-slimming\qualify\_out\visual\RUNNING.txt`
- `C:\Users\qnhxx\Documents\AI-Projects\Code\pi-subagent\.scratch\pi-subagent-slimming\qualify\_out\visual\INCOMPLETE.txt`

## Window processes

```json
[
  {
    "pid": 9368,
    "process": "powershell",
    "title": "[SUCCEEDED] Pi �� visual-success �� First use the bash tool once to run exactly: echo GLYPH_CHECK. Then reply with e �� 5bd5ed80-e977-44ce-9322-34cbfb78a80b"
  },
  {
    "pid": 25440,
    "process": "powershell",
    "title": "[RUNNING] Pi �� visual-running �� Use the bash tool to run these 10 commands one at a time, each in its own separa �� 260fe50e-905f-45ea-aa8e-78388cca2fad"
  },
  {
    "pid": 37008,
    "process": "powershell",
    "title": "[INCOMPLETE] Pi �� visual-incomplete �� Use the bash tool to run exactly: powershell -NoProfile -Command \"Start-Sleep -S �� 33140f22-c0f4-4018-bbae-212eef554903"
  }
]
```

## Stopping this hold

Closing the hold also closes the windows (they are children of the MCP server).

```
powershell -NoProfile -Command "Stop-Process -Id 17428 -Force"
```

State root: `C:\Users\qnhxx\AppData\Local\Temp\pi-subagent-qualify\2026-09-17T03-58-35-623Z`
Repo under test: `C:\Users\qnhxx\Documents\AI-Projects\Code\pi-subagent`
