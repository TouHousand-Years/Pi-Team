# Prove the per-Run Windows viewer

Type: wayfinder:prototype
Status: resolved
Blocked by: 02

## Question

Can a throwaway PowerShell/.NET WinForms prototype open one independent window per Run, replay and tail representative full Transcripts in real time, render the complete event stream without summaries or silent truncation, isolate four concurrent Runs, remain responsive under high event volume and Unicode, survive capture/window failures without affecting workers, and notify exactly once on completion? Pause for human visual inspection.

## Answer

Yes. The corrected prototype satisfies the automated losslessness, isolation, responsiveness, Unicode model-text, failure-containment, full-title, formatted-only, and exactly-once notification checks. Batched RTF insertion removes the prior O(n^2) RichTextBox append behavior. The human visual recheck on 2026-09-16 confirmed the independent read-only Run Windows now meet the expected display and interaction behavior, including glyph appearance, formatted-only recognized events, full Run IDs, mid-stream window detachment, and completion notification.

## Comments

- Automated prototype validation completed on 2026-09-16. All four scripts parse; the Unicode self-test round-trips 40,052 characters; concurrent headless replay/tail validation reports `maxHeartbeatGapMs=297`, lossless hashes and ordering match, four-Run sentinels remain isolated, capture failure is incomplete without notification, duplicate terminal records notify once, and the verifier reports `PASS (0 fail, 1 warn)`. The remaining warning is the mandatory human-only mid-stream window-close and visual glyph/notification inspection.
- Human visual inspection on 2026-09-16 did not pass. Independent per-Run windows, terminal status, display-error isolation, and continuous event visibility were present, but (1) several Unicode/emoji glyphs rendered as tofu squares, (2) recognized events were followed by duplicate `raw:` JSON despite the formatted-only decision, and (3) short title prefixes made similarly named Runs hard to distinguish. The screenshot alone could not prove close-while-running continuity or exactly-once notification. Keep this ticket claimed until these defects are corrected and visually rechecked.
- Visual-correction attempt on 2026-09-16 remains unverified. The prototype now contains formatted-only recognized-event rendering, raw fallback for unknown/malformed data, full Run IDs in titles, and per-category font selection. All four scripts parse, but both the initial worker and its single bounded retry timed out. A host-run `-SelfTest` then produced no output for more than two minutes while enumerating font coverage and was terminated. Do not run the visible prototype or resolve this ticket until the font-resolution startup cost is bounded and the automated suite passes.
- Follow-up on 2026-09-16 identified the timeout calls as explicit 15/10-minute overrides and reran the correction with a 60-minute allowance. The actual performance defect was O(n^2) per-font-run RichTextBox appending, not font-map enumeration. Batched RTF insertion now preserves the 40,053-character Unicode torture string exactly and reduces `-SelfTest` to about 1.4 seconds. Main-session verification: all four scripts parse; window SelfTest passes (Unicode, font-run mapping, cached glyph coverage, formatter honesty); verifier SelfTest passes 8/8. Headless all-scenarios passes 151 checks with only the required human closure warning. A paced 50,000-event run at 400 records/s passes with 50,011 rendered records, one notification, 268 ms max heartbeat gap, and 94 ms p95 latency; the unpaced burst is lossless but intentionally fails the streaming latency threshold because all timestamps share the burst start. Ticket remains claimed pending the mandatory human visual checks for glyph appearance, formatted-only display, full titles, mid-stream close continuity, and exactly-once notification.
- Human visual acceptance passed on 2026-09-16. The user confirmed the corrected windows meet the expected behavior; the prototype ticket is resolved.
