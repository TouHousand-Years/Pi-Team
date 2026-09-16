#requires -Version 5.1
<#
  per-run-window.ps1 - independent read-only per-Run transcript windows (ticket 03 prototype).

  What it does
  ------------
  One process hosts one independent WinForms window per discovered Run journal
  (<runId>.journal.jsonl under -FixtureDir). Each window replays the records
  already on disk when the journal was first opened and tails everything
  written afterwards, via a per-run-polling timer tick (no fsnotify, no
  background reads). Recognised records are appended as one deterministic
  formatted block that carries every field of the payload exactly once;
  there is no second raw JSON copy. Unknown, malformed or unrepresentable
  records stay visible losslessly in a raw fallback form. Nothing is
  truncated, filtered or summarised away.

  Unicode display
  ---------------
  WinForms' default RichTextBox font has no CJK/emoji coverage, so every
  block is appended as one RTF fragment whose runs each carry a
  per-character-category font (base, cjk, hangul, emoji, rtl, math,
  symbol). Families are resolved at startup from installed fonts and
  validated with WPF's CharacterToGlyphMap (surrogate-aware; GDI cannot
  report non-BMP coverage); glyph maps are cached per family. The resolved
  families and each family's sample gaps are written to report.json so the
  verifier can check the claim, and -SelfTest independently re-checks every
  codepoint of the torture text against the declared family. Coverage is
  programmatically provable this way; colour emoji rendering is a visual
  property and remains a human check.

  Each tick has a wall-clock budget (-TickBudgetMs, default 200 ms; the
  starting Run rotates each tick for fairness). Reading/splitting and
  per-record formatting stop when the budget is exhausted; leftover lines
  stay queued for the next tick. This keeps a large replay backlog from
  blocking the UI thread or the heartbeat measurement for >500 ms.

  Read-only by construction: no buttons, no raw tab, no summaries, no
  follow-up prompts. Closing a window only detaches the display; capture,
  hashing and notification bookkeeping continue for that Run until the
  process exits. The report is written when the last Run window closes
  (GUI mode) or when every Run has settled (headless validation mode).

  Completion semantics
  --------------------
  A Run is complete when the first valid terminal meta record arrives with
  signal == null, every seq from 1..N was seen in order, and no captureError
  arrived before it. Anything else stays incomplete. A first valid terminal
  or a captureError triggers exactly one completion notification; duplicate
  terminal records must not notify twice.

  Modes
  -----
  GUI (default):   one Form per Run, status strip per Form, topmost
                   non-modal notification forms that auto-close.
  -Headless:       no Forms at all. Same discovery, gate handshake, replay,
                   tailing, formatting, hashing, notification counting and
                   report/rendered output. Exits when every Run has settled
                   and the generator manifest is on disk (or after a short
                   grace period). This exists so parser/formatter/hash/
                   report behaviour can be validated without any visible
                   GUI; it is not a user-facing feature.
  -SelfTest:       no files, no Forms shown; verifies that a RichTextBox
                   round-trips a > 40,000 char Unicode torture string
                   exactly (MaxLength = 0), that LF survives a TextBox
                   round-trip, that the RTF run mapping assigns every
                   category its font index, that the cached glyph maps of
                   the chosen families cover every torture codepoint, and
                   that recognised events render without a duplicate raw
                   JSON copy while unknown/malformed records stay raw.
                   Prints SELFTEST PASS/FAIL and exits.

  Examples
  --------
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File per-run-window.ps1 `
      -FixtureDir .\prototype\_out -ReportPath .\prototype\_out\report.json
    powershell -NoProfile -ExecutionPolicy Bypass -File per-run-window.ps1 -SelfTest
    powershell -NoProfile -ExecutionPolicy Bypass -File per-run-window.ps1 `
      -FixtureDir .\prototype\_out -Headless -HeadlessTimeoutMs 120000
#>
[CmdletBinding()]
param(
  [string]$FixtureDir,

  [string]$ReportPath,

  [ValidateRange(10, 2000)]
  [int]$TickMs = 50,

  # Wall-clock budget for record processing inside one tick. Add-AvailableLines
  # and the per-record loop both stop when this budget is exhausted, so a
  # large replay backlog is drained across ticks instead of blocking one tick
  # for >500 ms (the heartbeat threshold). Remaining lines stay queued.
  [ValidateRange(25, 5000)]
  [int]$TickBudgetMs = 200,

  [ValidateRange(1, 20000)]
  [int]$BatchLines = 1000,

  [ValidateRange(0, 60000)]
  [int]$NotifyMs = 5000,

  [ValidateRange(65536, 67108864)]
  [int]$MaxReadBytesPerTick = 2097152,

  [ValidateRange(1000, 600000)]
  [int]$WaitForFirstRunMs = 30000,

  [switch]$Headless,

  [ValidateRange(5000, 3600000)]
  [int]$HeadlessTimeoutMs = 300000,

  [switch]$SelfTest
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# WPF (PresentationCore) is used only as a glyph-coverage oracle: at startup
# to validate candidate families and in -SelfTest. GlyphTypeface's
# CharacterToGlyphMap decodes surrogate pairs correctly, while GDI
# GetGlyphIndicesW reports 0xFFFF for every non-BMP scalar even in fonts
# that cover it.
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Codepoint classifier (used by the formatter's per-category font runs and
# by -SelfTest, which re-checks coverage independently of the formatter).
# Pure ASCII source so Windows PowerShell 5.1 cannot mangle it. Sticky
# codepoints (ZWJ, ZWNJ,
# variation selectors, combining marks, skin-tone modifiers, keycaps) inherit
# the preceding scalar's category, so a ZWJ family stays one emoji run.
$PiGlyphRunsSource = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

public static class PiGlyphRuns
{
    private static bool IsSticky(int cp)
    {
        if (cp == 0x200C || cp == 0x200D) { return true; }
        if (cp == 0xFE0E || cp == 0xFE0F) { return true; }
        if (cp == 0x20E3) { return true; }
        if (cp >= 0x1F3FB && cp <= 0x1F3FF) { return true; }
        if (cp >= 0xE0020 && cp <= 0xE007F) { return true; }
        if (cp <= 0xFFFF)
        {
            UnicodeCategory cat = CharUnicodeInfo.GetUnicodeCategory((char)cp);
            if (cat == UnicodeCategory.NonSpacingMark || cat == UnicodeCategory.SpacingCombiningMark || cat == UnicodeCategory.EnclosingMark) { return true; }
        }
        return false;
    }

    private static bool IsCombiningOnly(int cp)
    {
        if (cp == 0x200C) { return true; }
        if (cp <= 0xFFFF)
        {
            UnicodeCategory cat = CharUnicodeInfo.GetUnicodeCategory((char)cp);
            if (cat == UnicodeCategory.NonSpacingMark || cat == UnicodeCategory.SpacingCombiningMark || cat == UnicodeCategory.EnclosingMark) { return true; }
        }
        return false;
    }

    private static bool InRange(int cp, int lo, int hi) { return cp >= lo && cp <= hi; }

    private static string CategoryOf(int cp, string prev)
    {
        if (IsSticky(cp))
        {
            if (prev != null) { return prev; }
            return IsCombiningOnly(cp) ? "base" : "emoji";
        }
        if (InRange(cp, 0x1100, 0x11FF) || InRange(cp, 0x3130, 0x318F) || InRange(cp, 0xA960, 0xA97F) || InRange(cp, 0xAC00, 0xD7AF) || InRange(cp, 0xD7B0, 0xD7FF)) { return "hangul"; }
        if (InRange(cp, 0x2E80, 0x2FFF) || InRange(cp, 0x3000, 0x30FF) || InRange(cp, 0x3100, 0x312F) || InRange(cp, 0x3190, 0x31FF) || InRange(cp, 0x3200, 0x33FF) || InRange(cp, 0x3400, 0x4DBF) || InRange(cp, 0x4E00, 0x9FFF) || InRange(cp, 0xF900, 0xFAFF) || InRange(cp, 0xFE30, 0xFE4F) || InRange(cp, 0xFF00, 0xFFEF) || InRange(cp, 0x20000, 0x2FA1F)) { return "cjk"; }
        if (InRange(cp, 0x0590, 0x05FF) || InRange(cp, 0x0600, 0x074F) || InRange(cp, 0x0750, 0x08FF) || InRange(cp, 0xFB1D, 0xFB4F) || InRange(cp, 0xFE70, 0xFEFF)) { return "rtl"; }
        if (InRange(cp, 0x1F000, 0x1FAFF) || InRange(cp, 0x2600, 0x27BF) || InRange(cp, 0x2B00, 0x2BFF)) { return "emoji"; }
        if (InRange(cp, 0x1D400, 0x1D7FF) || InRange(cp, 0x2200, 0x22FF) || InRange(cp, 0x27C0, 0x27EF) || InRange(cp, 0x2980, 0x29FF) || InRange(cp, 0x2A00, 0x2AFF)) { return "math"; }
        if (cp < 0x2000) { return "base"; }
        return "symbol";
    }

    private static int ScalarAt(string text, int i, out int advance)
    {
        char c = text[i];
        if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
        {
            advance = 2;
            return char.ConvertToUtf32(c, text[i + 1]);
        }
        advance = 1;
        return c;
    }

    public static string[] Split(string text)
    {
        if (string.IsNullOrEmpty(text)) { return new string[0]; }
        List<string> runs = new List<string>();
        int runStart = 0;
        string cur = null;
        int i = 0;
        while (i < text.Length)
        {
            int advance;
            int cp = ScalarAt(text, i, out advance);
            string cat = CategoryOf(cp, cur);
            if (cur == null) { cur = cat; runStart = i; }
            else if (cat != cur)
            {
                runs.Add(cur + "|" + runStart.ToString(CultureInfo.InvariantCulture) + "|" + (i - runStart).ToString(CultureInfo.InvariantCulture));
                cur = cat;
                runStart = i;
            }
            i += advance;
        }
        runs.Add(cur + "|" + runStart.ToString(CultureInfo.InvariantCulture) + "|" + (text.Length - runStart).ToString(CultureInfo.InvariantCulture));
        return runs.ToArray();
    }

    // One pass over all rendered texts: the unique codepoints each category's
    // chosen font must map. Used by the verifier's independent coverage
    // check; keys match Split's category names.
    public static Dictionary<string, int[]> GetUniqueCodePoints(string[] texts)
    {
        Dictionary<string, HashSet<int>> map = new Dictionary<string, HashSet<int>>();
        foreach (string text in texts)
        {
            if (string.IsNullOrEmpty(text)) { continue; }
            string prev = null;
            int i = 0;
            while (i < text.Length)
            {
                int advance;
                int cp = ScalarAt(text, i, out advance);
                string cat = CategoryOf(cp, prev);
                prev = cat;
                HashSet<int> set;
                if (!map.TryGetValue(cat, out set)) { set = new HashSet<int>(); map[cat] = set; }
                set.Add(cp);
                i += advance;
            }
        }
        Dictionary<string, int[]> result = new Dictionary<string, int[]>();
        foreach (KeyValuePair<string, HashSet<int>> kv in map)
        {
            int[] cps = new int[kv.Value.Count];
            kv.Value.CopyTo(cps);
            Array.Sort(cps);
            result[kv.Key] = cps;
        }
        return result;
    }

    // RTF escaping for one classified run: backslash and braces are escaped,
    // CR/LF become paragraph breaks, tab becomes a tab stop, other C0
    // controls are dropped (RichEdit cannot display them), and everything at
    // or above U+0080 becomes a signed unicode escape with the uc1 fallback
    // so the fragment stays pure ASCII. Char code 92 is used for backslash so
    // this embedded source contains no escape-prone literals.
    public static string RtfEscape(string text)
    {
        if (string.IsNullOrEmpty(text)) { return string.Empty; }
        StringBuilder sb = new StringBuilder(text.Length + 16);
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            int code = c;
            if (code == 92) { sb.Append((char)92).Append((char)92); }
            else if (c == '{') { sb.Append((char)92).Append('{'); }
            else if (c == '}') { sb.Append((char)92).Append('}'); }
            else if (code == 13)
            {
                if (i + 1 < text.Length && text[i + 1] == (char)10) { continue; }
                sb.Append((char)92).Append('p').Append('a').Append('r').Append(' ');
            }
            else if (code == 10) { sb.Append((char)92).Append('p').Append('a').Append('r').Append(' '); }
            else if (code == 9) { sb.Append((char)92).Append('t').Append('a').Append('b').Append(' '); }
            else if (code < 32) { }
            else if (code < 128) { sb.Append(c); }
            else
            {
                int signed = code;
                if (signed > 32767) { signed -= 65536; }
                sb.Append((char)92).Append('u').Append(signed.ToString(CultureInfo.InvariantCulture)).Append('?');
            }
        }
        return sb.ToString();
    }
}
'@
Add-Type -TypeDefinition $PiGlyphRunsSource -Language CSharp

# ---------------------------------------------------------------------------
# Display fonts: per-category family resolution + WPF coverage oracle
# ---------------------------------------------------------------------------

function Test-FontInstalled {
  param([string]$Family)
  try {
    $ff = New-Object System.Drawing.FontFamily($Family)
    [void]$ff.Dispose()
    return $true
  }
  catch {
    return $false
  }
}

function New-ScalarString {
  param([int[]]$CodePoints)
  $sb = New-Object System.Text.StringBuilder
  foreach ($cp in $CodePoints) { [void]$sb.Append([char]::ConvertFromUtf32($cp)) }
  return $sb.ToString()
}

# Cached glyph metadata. CharacterToGlyphMap is built once per family
# (2.5k..30k entries on this host) and reused by startup resolution,
# -SelfTest and the report; only the family's Normal typeface is consulted,
# which is the one the RichTextBox uses. This replaces the old per-candidate
# enumeration of every style/weight/stretch, which was the unbounded startup
# cost.
$script:fontGlyphCache = @{}
$script:fontsResolved = $false
$script:categoryOrder = @()
$script:rtfBackslash = [string][char]92

function Get-FontGlyphInfo {
  param([string]$Family)
  if ($script:fontGlyphCache.ContainsKey($Family)) { return $script:fontGlyphCache[$Family] }
  $info = [pscustomobject]@{
    family        = $Family
    resolved      = $false
    map           = $null
    glyphCount    = 0
    typefaceCount = 0
    error         = ''
  }
  try {
    $ff = New-Object System.Windows.Media.FontFamily($Family)
    foreach ($tf in $ff.GetTypefaces()) {
      $info.typefaceCount = $info.typefaceCount + 1
      if ($tf.Style -ne [System.Windows.FontStyles]::Normal) { continue }
      if ($tf.Weight -ne [System.Windows.FontWeights]::Normal) { continue }
      if ($tf.Stretch -ne [System.Windows.FontStretches]::Normal) { continue }
      $gt = $null
      if (-not $tf.TryGetGlyphTypeface([ref]$gt)) { continue }
      if ($null -eq $gt) { continue }
      $info.map = $gt.CharacterToGlyphMap
      $info.glyphCount = $info.map.Count
      $info.resolved = $true
      break
    }
    if (-not $info.resolved) { $info.error = 'no normal glyph typeface' }
  }
  catch {
    $info.error = $_.Exception.Message
  }
  $script:fontGlyphCache[$Family] = $info
  return $info
}

function Get-MissingCodePoints {
  param($Map, $CodePoints)
  $missing = New-Object 'System.Collections.Generic.List[int]'
  if ($null -eq $Map) {
    foreach ($cp in $CodePoints) { [void]$missing.Add([int]$cp) }
    return $missing
  }
  foreach ($cp in $CodePoints) {
    if (-not $Map.ContainsKey([int]$cp)) { [void]$missing.Add([int]$cp) }
  }
  return $missing
}

function Resolve-DisplayFonts {
  # Candidates per category; the first installed family whose cached glyph map
  # covers the category sample wins. If none covers it, the first installed
  # family is used and its sample gaps are recorded in the report so the
  # verifier fails with explicit codepoints instead of pretending everything
  # is fine. Resolution touches only these candidates; every glyph map is
  # cached for -SelfTest and the report, so no second scan happens later.
  if ($script:fontsResolved) { return }
  $candidates = [ordered]@{
    base   = @('Cascadia Mono', 'Consolas', 'Lucida Console', 'Courier New', 'Segoe UI')
    cjk    = @('Microsoft YaHei UI', 'Microsoft YaHei', 'Yu Gothic UI', 'Microsoft JhengHei UI', 'MS Gothic', 'Malgun Gothic', 'Segoe UI')
    hangul = @('Malgun Gothic', 'Microsoft YaHei UI', 'Yu Gothic UI', 'Segoe UI')
    emoji  = @('Segoe UI Emoji', 'Segoe UI Symbol')
    rtl    = @('Segoe UI', 'Tahoma', 'Arial')
    math   = @('Segoe UI Symbol', 'Cambria Math', 'Segoe UI')
    symbol = @('Segoe UI Symbol', 'Segoe UI', 'Tahoma', 'Arial')
  }
  $samples = [ordered]@{
    base   = @(0x0041, 0x0061, 0x0030, 0x0020, 0x00E9, 0x20AC, 0x2192)
    cjk    = @(0x4E2D, 0x6587, 0x3042, 0x30A2, 0xFF01)
    hangul = @(0xD55C, 0xAD6D)
    emoji  = @(0x1F600, 0x1F389, 0x1F468, 0x200D, 0x1F469, 0x2764, 0xFE0F)
    rtl    = @(0x0645, 0x0631, 0x05E9)
    math   = @(0x1D518, 0x2200, 0x2211)
    symbol = @(0x2192, 0x2022, 0x2014, 0x2260)
  }
  $script:categoryOrder = @($candidates.Keys)
  $script:displayFonts = [ordered]@{}
  $script:displayFontDetails = [ordered]@{}
  $script:categoryFonts = @{}
  $script:categoryFontIndex = @{}
  $catIndex = 0
  foreach ($cat in $candidates.Keys) {
    $script:categoryFontIndex[$cat] = $catIndex
    $catIndex++
    $chosen = $null
    $chosenMissing = @()
    $firstInstalled = $null
    $chosenInfo = $null
    foreach ($cand in $candidates[$cat]) {
      if (-not (Test-FontInstalled -Family $cand)) { continue }
      if ($null -eq $firstInstalled) { $firstInstalled = $cand }
      $info = Get-FontGlyphInfo -Family $cand
      if ($null -eq $info.map) { continue }
      $miss = @(Get-MissingCodePoints -Map $info.map -CodePoints $samples[$cat])
      if ($miss.Count -eq 0) { $chosen = $cand; $chosenMissing = @(); $chosenInfo = $info; break }
      if ($null -eq $chosen) { $chosen = $cand; $chosenMissing = $miss; $chosenInfo = $info }
    }
    if ($null -eq $chosen -and $null -ne $firstInstalled) {
      $chosen = $firstInstalled
      $chosenInfo = Get-FontGlyphInfo -Family $chosen
    }
    if ($null -eq $chosen) { $chosen = 'Segoe UI'; $chosenInfo = Get-FontGlyphInfo -Family $chosen }
    $missingHex = @()
    foreach ($cp in $chosenMissing) { $missingHex += ('U+' + ([int]$cp).ToString('X4')) }
    $script:displayFonts[$cat] = $chosen
    $script:displayFontDetails[$cat] = [pscustomobject]@{
      font          = $chosen
      sampleMissing = $missingHex
      resolved      = [bool]$chosenInfo.resolved
      glyphCount    = [int]$chosenInfo.glyphCount
      typefaceCount = [int]$chosenInfo.typefaceCount
      error         = [string]$chosenInfo.error
    }
    try {
      $script:categoryFonts[$cat] = New-Object System.Drawing.Font($chosen, 9)
    }
    catch {
      try { $script:categoryFonts[$cat] = New-Object System.Drawing.Font('Segoe UI', 9) }
      catch { $script:categoryFonts[$cat] = [System.Drawing.SystemFonts]::DefaultFont }
    }
  }
  $script:baseFont = $script:categoryFonts['base']
  $script:fontsResolved = $true
}

# One RTF fragment for the whole text: header + font table + one run per
# classified span. Each fragment carries its own font table because
# SelectedRtf replaces the whole selection with a complete document.
# fnil with no charset hint is deliberate: GDI font-links per glyph exactly
# like the old per-run SelectionFont path, and sticky codepoints (ZWJ, VS16)
# survive in the model. Backslash is emitted via [char]92 so this source
# stays free of escape-prone literals.
function Build-RtfFragment {
  param([string]$Text)
  $bs = $script:rtfBackslash
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('{').Append($bs).Append('rtf1').Append($bs).Append('ansi').Append($bs).Append('deff0').Append($bs).Append('uc1{').Append($bs).Append('fonttbl')
  foreach ($cat in $script:categoryOrder) {
    [void]$sb.Append('{').Append($bs).Append('f').Append([string]$script:categoryFontIndex[$cat]).Append($bs).Append('fnil ').Append([string]$script:displayFonts[$cat]).Append(';}')
  }
  [void]$sb.Append('}')
  foreach ($run in [PiGlyphRuns]::Split($Text)) {
    $sep1 = $run.IndexOf('|')
    $sep2 = $run.IndexOf('|', $sep1 + 1)
    $cat = $run.Substring(0, $sep1)
    $start = [int]$run.Substring($sep1 + 1, $sep2 - $sep1 - 1)
    $len = [int]$run.Substring($sep2 + 1)
    $idx = 0
    if ($script:categoryFontIndex.ContainsKey($cat)) { $idx = [int]$script:categoryFontIndex[$cat] }
    [void]$sb.Append($bs).Append('f').Append([string]$idx).Append(' ')
    [void]$sb.Append([PiGlyphRuns]::RtfEscape($Text.Substring($start, $len)))
  }
  [void]$sb.Append('}')
  return $sb.ToString()
}

function Add-RichTextWithFallback {
  param($Rtb, [string]$Text)
  if ($null -eq $Rtb -or [string]::IsNullOrEmpty($Text)) { return }
  if ($null -eq $script:baseFont -or $script:categoryOrder.Count -eq 0) {
    $Rtb.AppendText($Text)
    return
  }
  # One fragment per append: O(text) instead of the old per-run
  # SelectionFont + AppendText, which was O(n^2) across thousands of runs.
  $fragment = Build-RtfFragment -Text $Text
  $Rtb.SelectionStart = $Rtb.TextLength
  $Rtb.SelectionLength = 0
  $Rtb.SelectedRtf = $fragment
}

# Same ASCII-safe base64 payload as fixture-generator.ps1. Decodes to CJK +
# Korean + emoji (incl. ZWJ family) + combining marks + RTL Arabic/Hebrew +
# astral math letters + backslash + double quote.
$TortureBase64 = '5Lit5paHIOaXpeacrOiqniDtlZzqta3slrQg8J+YgPCfjonwn5Go4oCN8J+RqeKAjfCfkafigI3wn5GmIGXMgSBhzIAg2YXYsdit2KjYpyDXqdec15XXnSDwnZSY8J2Uq/CdlKbwnZSg8J2UrPCdlKHwnZSiIFwgIg=='

function Get-NowMs {
  return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Invoke-SelfTest {
  $torture = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($TortureBase64))
  $b = New-Object System.Text.StringBuilder
  while ($b.Length -le 40000) { [void]$b.Append($torture) }
  # The payload's punctuation is ASCII, so append one classifier-"symbol"
  # codepoint to exercise the symbol font assignment too.
  $expected = $b.ToString() + [char]0x2192

  Resolve-DisplayFonts

  $rtb = New-Object System.Windows.Forms.RichTextBox
  $rtb.MaxLength = 0
  $rtb.WordWrap = $false
  $rtb.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
  $rtb.Font = $script:baseFont
  $rtb.ReadOnly = $true
  Add-RichTextWithFallback -Rtb $rtb -Text $expected
  $round = $rtb.Text
  $exact = ($round -ceq $expected)
  $len = 0
  if ($null -ne $round) { $len = $round.Length }

  # Run-mapping probe: one character per category, in category order, must
  # produce exactly the category font indexes as run prefixes, in order. This
  # tests the application's font assignment deterministically without
  # asserting RichEdit's model-level font linking.
  $probeChars = @('A', [char]0x4E2D, [char]0xD55C, [char]::ConvertFromUtf32(0x1F600), [char]0x0645, [char]::ConvertFromUtf32(0x1D518), [char]0x2192)
  $probeText = [string]::Join('', $probeChars)
  $probeFrag = Build-RtfFragment -Text $probeText
  $expectedIdx = New-Object 'System.Collections.Generic.List[string]'
  foreach ($run in [PiGlyphRuns]::Split($probeText)) {
    $sep1 = $run.IndexOf('|')
    $cat = $run.Substring(0, $sep1)
    if ($script:categoryFontIndex.ContainsKey($cat)) { [void]$expectedIdx.Add([string]$script:categoryFontIndex[$cat]) }
    else { [void]$expectedIdx.Add('?') }
  }
  $foundIdx = New-Object 'System.Collections.Generic.List[string]'
  foreach ($mt in [regex]::Matches($probeFrag, [regex]::Escape($script:rtfBackslash) + 'f([0-9]+) ')) { [void]$foundIdx.Add($mt.Groups[1].Value) }
  $assignmentOk = (($expectedIdx.Count -eq $foundIdx.Count) -and ($expectedIdx.Count -gt 0))
  if ($assignmentOk) {
    for ($i = 0; $i -lt $expectedIdx.Count; $i++) {
      if ($expectedIdx[$i] -cne $foundIdx[$i]) { $assignmentOk = $false; break }
    }
  }
  $assignmentDetail = 'run-map expected=[' + [string]::Join(',', $expectedIdx.ToArray()) + '] found=[' + [string]::Join(',', $foundIdx.ToArray()) + ']'

  # Independent coverage over the whole torture text: each category's chosen
  # family must map every codepoint classified into that category. This is
  # the strongest claim that can be made programmatically; whether the glyph
  # paints in colour (emoji) is visual and stays a human check.
  $catMap = [PiGlyphRuns]::GetUniqueCodePoints([string[]]@($expected))

  # Every run in the inserted document must carry a font. The actual family
  # may be substituted by RichEdit/GDI font linking (the old per-run
  # SelectionFont path did the same); family names are recorded, not asserted.
  $renderedFonts = New-Object 'System.Collections.Generic.List[string]'
  $probedCats = @{}
  foreach ($run in [PiGlyphRuns]::Split($expected)) {
    $sep1 = $run.IndexOf('|')
    $sep2 = $run.IndexOf('|', $sep1 + 1)
    $cat = $run.Substring(0, $sep1)
    if ($probedCats.ContainsKey($cat)) { continue }
    $probedCats[$cat] = $true
    $start = [int]$run.Substring($sep1 + 1, $sep2 - $sep1 - 1)
    $runLen = [int]$run.Substring($sep2 + 1)
    $rtb.Select($start, $runLen)
    $selFont = $rtb.SelectionFont
    if ($null -eq $selFont) { [void]$renderedFonts.Add($cat + '=<null>') }
    else { [void]$renderedFonts.Add($cat + '=' + $selFont.Name) }
  }
  $fontOk = $true
  foreach ($rf in $renderedFonts) {
    if ($rf.EndsWith('=<null>')) { $fontOk = $false }
  }
  if (-not $fontOk) { $assignmentDetail += ' advisory-null-rendered-font;' }

  # Coverage over the whole torture text uses the cached glyph maps of the
  # chosen families only (no second candidate scan); each category's map must
  # contain every classified codepoint. Colour emoji rendering stays visual.
  $coverageOk = $true
  $coverageDetail = ''
  foreach ($cat in $catMap.Keys) {
    $codes = $catMap[$cat]
    if (-not $script:displayFonts.Contains($cat)) {
      $coverageOk = $false
      $coverageDetail += ($cat + ':no-font-style;')
      continue
    }
    $info = Get-FontGlyphInfo -Family ([string]$script:displayFonts[$cat])
    if ($null -eq $info.map) {
      $coverageOk = $false
      $coverageDetail += ($cat + ':no-glyph-map;')
      continue
    }
    $miss = @(Get-MissingCodePoints -Map $info.map -CodePoints $codes)
    if ($miss.Count -gt 0) {
      $coverageOk = $false
      $hex = New-Object 'System.Collections.Generic.List[string]'
      foreach ($cp in $miss) { [void]$hex.Add(('U+' + ([int]$cp).ToString('X4'))) }
      $coverageDetail += ($cat + ':missing=' + [string]::Join(',', $hex.ToArray()) + ';')
    }
  }

  # Formatter honesty probes: recognised events render one formatted block
  # with no second raw JSON copy; unknown/malformed/stderr records keep their
  # raw payload visible verbatim.
  $formatterOk = $true
  $formatterDetail = ''
  $lastTypeRef = ''
  $deltaLine = '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"hello world"}}'
  $deltaRec = [pscustomobject][ordered]@{ seq = 5; ts = 7; ch = 'stdout'; data = $deltaLine }
  $fLines = @(Format-Record -Rec $deltaRec -RawLine $deltaLine -LastType ([ref]$lastTypeRef))
  $fText = [string]::Join("`n", $fLines)
  if (($fText -notlike '*== message_update*') -or ($fText -notlike '*hello world*') -or $fText.Contains($deltaLine)) {
    $formatterOk = $false
    $formatterDetail += 'recognised-duplicate-raw;'
  }
  $unknownLine = '{"type":"future_event","payload":{"n":1}}'
  $unknownRec = [pscustomobject][ordered]@{ seq = 6; ts = 8; ch = 'stdout'; data = $unknownLine }
  $fLines = @(Format-Record -Rec $unknownRec -RawLine $unknownLine -LastType ([ref]$lastTypeRef))
  $fText = [string]::Join("`n", $fLines)
  if (-not $fText.Contains('? [event future_event] ' + $unknownLine)) {
    $formatterOk = $false
    $formatterDetail += 'unknown-raw-lost;'
  }
  $badLine = 'not json {'
  $badRec = [pscustomobject][ordered]@{ seq = 7; ts = 9; ch = 'stdout'; data = $badLine }
  $fLines = @(Format-Record -Rec $badRec -RawLine $badLine -LastType ([ref]$lastTypeRef))
  $fText = [string]::Join("`n", $fLines)
  if (-not $fText.Contains('? [unparsed stdout] ' + $badLine)) {
    $formatterOk = $false
    $formatterDetail += 'malformed-raw-lost;'
  }
  $fLines = @(Format-Record -Rec $null -RawLine $badLine -LastType ([ref]$lastTypeRef))
  $fText = [string]::Join("`n", $fLines)
  if (-not $fText.Contains('? [unparsed journal line] ' + $badLine)) {
    $formatterOk = $false
    $formatterDetail += 'unparsed-journal-lost;'
  }
  $stderrLine = '{"seq":7,"ch":"stderr","data":"boom"}'
  $fLines = @(Format-Record -Rec (ConvertFrom-Json -InputObject $stderrLine) -RawLine $stderrLine -LastType ([ref]$lastTypeRef))
  $fText = [string]::Join("`n", $fLines)
  if (-not $fText.Contains('! stderr: boom')) {
    $formatterOk = $false
    $formatterDetail += 'stderr-lost;'
  }
  $termData = ConvertTo-Json -InputObject ([pscustomobject][ordered]@{ status = 'completed'; exitCode = 0; signal = $null }) -Compress
  $termRec = [pscustomobject][ordered]@{ seq = 9; ts = 11; ch = 'meta'; kind = 'terminal'; status = 'completed'; exitCode = 0; signal = $null; data = $termData }
  $termRaw = ConvertTo-Json -InputObject $termRec -Compress -Depth 6
  $fLines = @(Format-Record -Rec $termRec -RawLine $termRaw -LastType ([ref]$lastTypeRef))
  $fText = [string]::Join("`n", $fLines)
  if ((-not $fText.Contains('== terminal status=completed exit=0 signal=null')) -or $fText.Contains($termData)) {
    $formatterOk = $false
    $formatterDetail += 'terminal-duplicate-raw;'
  }

  # Newline handling: the paging design depends on LF surviving replay.
  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Multiline = $true
  $tb.Text = "a`nb`n"
  $nlExpected = "a`nb`n"
  $nlExact = ($tb.Text -ceq $nlExpected)

  $rtb.Dispose()
  $tb.Dispose()

  $fonts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($cat in $script:displayFonts.Keys) { [void]$fonts.Add($cat + '=' + [string]$script:displayFonts[$cat]) }
  if ($exact -and ($len -gt 40000) -and $nlExact -and $assignmentOk -and $coverageOk -and $formatterOk) {
    Write-Host ('SELFTEST PASS unicode-roundtrip chars={0} newlineRoundtrip=ok font-runs=ok font-coverage=ok formatter-honesty=ok fonts={1}' -f $len, [string]::Join(' ', $fonts.ToArray()))
    Write-Host ('  font-runs: ' + $assignmentDetail)
    Write-Host ('  rendered-runs: ' + [string]::Join(' ', $renderedFonts.ToArray()))
    Write-Host ('  glyph-cache: ' + ([string]::Join(' ', @($script:fontGlyphCache.Keys | ForEach-Object { $_ + '=' + [string]$script:fontGlyphCache[$_].glyphCount }))))
    return 0
  }
  Write-Host ('SELFTEST FAIL unicode-roundtrip chars={0} exact={1} newlineRoundtrip={2} font-runs={3} font-present={4} font-coverage={5} formatter-honesty={6} detail={7}{8}' -f $len, $exact, $nlExact, $assignmentOk, $fontOk, $coverageOk, $formatterOk, $coverageDetail, $formatterDetail)
  Write-Host ('  font-runs: ' + $assignmentDetail)
  Write-Host ('  rendered-runs: ' + [string]::Join(' ', $renderedFonts.ToArray()))
  return 1
}

# -SelfTest exits after the formatter functions are defined (see the guard
# before the main loop), so the formatter honesty probes exercise the real
# production formatter instead of a copy.
if (-not $SelfTest) {
  if ([string]::IsNullOrWhiteSpace($FixtureDir)) {
    throw '-FixtureDir is required unless -SelfTest is used.'
  }

  $FixtureDir = (Resolve-Path -LiteralPath $FixtureDir).Path
  if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $FixtureDir 'report.json'
  }
  $ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
}

if (-not $Headless -and -not $SelfTest) {
  $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState().ToString()
  if ($apartment -ne 'STA') {
    throw "GUI mode requires an STA thread (current: $apartment). Re-run with: powershell.exe -STA -File per-run-window.ps1 ..."
  }
  [System.Windows.Forms.Application]::EnableVisualStyles()
  [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Script-scope copies: reliable inside functions and event handlers.
$script:FixtureDir = $FixtureDir
$script:ReportPath = $ReportPath
$script:TickMs = $TickMs
$script:TickBudgetMs = $TickBudgetMs
$script:BatchLines = $BatchLines
$script:NotifyMs = $NotifyMs
$script:MaxReadBytesPerTick = $MaxReadBytesPerTick
$script:WaitForFirstRunMs = $WaitForFirstRunMs
$script:HeadlessMode = [bool]$Headless
$script:HeadlessTimeoutMs = $HeadlessTimeoutMs

$script:runs = [ordered]@{}
$script:openForms = 0
$script:notifications = New-Object 'System.Collections.Generic.List[string]'
$script:notificationCounts = @{}
$script:activeNotifications = New-Object 'System.Collections.Generic.List[object]'
$script:viewerErrors = New-Object 'System.Collections.Generic.List[string]'
$script:startedAt = Get-NowMs
$script:lastTickAt = [long]0
$script:maxHeartbeatGapMs = 0
$script:tickCount = 0
$script:tickRotation = 0
$script:gateWritten = $false
$script:reportWritten = $false
$script:settledAt = $null
$script:timer = $null

# ---------------------------------------------------------------------------
# Run state
# ---------------------------------------------------------------------------

function New-RunState {
  param(
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$JournalPath
  )
  $fs = New-Object System.IO.FileStream($JournalPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  return @{
    runId               = $RunId
    journal             = $JournalPath
    fs                  = $fs
    startSize           = [long]$fs.Length
    readOffset          = [long]0
    pendingBytes        = (New-Object byte[] 0)
    lineQueue           = (New-Object 'System.Collections.Generic.Queue[string]')
    lineOffsets         = (New-Object 'System.Collections.Generic.Queue[long]')
    seqExpected         = 1
    lastSeq             = 0
    receivedOrderOk     = $true
    rawSb               = (New-Object System.Text.StringBuilder)
    dataList            = (New-Object 'System.Collections.Generic.List[string]')
    renderedCount       = 0
    replayedCount       = 0
    tailedCount         = 0
    latencySamples      = (New-Object 'System.Collections.Generic.List[double]')
    maxLatencyMs        = 0
    maxHeartbeatGapMs   = 0
    terminal            = $false
    status              = $null
    captureError        = $false
    incomplete          = $false
    displayError        = $null
    displayErrorThrown  = $false
    notified            = $false
    formDetached        = $false
    form                = $null
    rtb                 = $null
    label               = $null
    pinnedAutoscroll    = $true
    lastType            = '-'
    windowTitle         = ''
    partialFlushed      = $false
    firstOpenedAt       = Get-NowMs
  }
}

# ---------------------------------------------------------------------------
# Discovery / forms
# ---------------------------------------------------------------------------

function Discover-Runs {
  $files = @(Get-ChildItem -LiteralPath $script:FixtureDir -Filter '*.journal.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name)
  $added = 0
  $suffix = '.journal.jsonl'
  foreach ($f in $files) {
    if ($f.Name.Length -le $suffix.Length) { continue }
    $runId = $f.Name.Substring(0, $f.Name.Length - $suffix.Length)
    if ($script:runs.Contains($runId)) { continue }
    try {
      $state = New-RunState -RunId $runId -JournalPath $f.FullName
      $script:runs[$runId] = $state
      if (-not $script:HeadlessMode) { Create-RunForm -State $state }
      else { Update-FormTitle -State $state }
      $added++
    }
    catch {
      [void]$script:viewerErrors.Add('discover ' + $runId + ' : ' + $_.Exception.Message)
    }
  }
  if ($added -gt 0 -and -not $script:gateWritten) {
    try {
      [System.IO.File]::WriteAllText((Join-Path $script:FixtureDir 'gate.go'), ('go ' + [DateTime]::UtcNow.ToString('o')), $utf8NoBom)
      $script:gateWritten = $true
    }
    catch {
      [void]$script:viewerErrors.Add('gate.go: ' + $_.Exception.Message)
    }
  }
}

function Create-RunForm {
  param($State)
  # Full runId in the title: an 8-char prefix made isolation-*/windowfail-*
  # runs indistinguishable. windowTitle is also recorded in report.json.
  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'Run ' + $State.runId + ' - starting'
  $form.Width = 920
  $form.Height = 620
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $form.MinimumSize = New-Object System.Drawing.Size(420, 220)
  $form.Tag = $State.runId

  $rtb = New-Object System.Windows.Forms.RichTextBox
  $rtb.Dock = [System.Windows.Forms.DockStyle]::Fill
  $rtb.ReadOnly = $true
  $rtb.WordWrap = $false
  $rtb.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
  $rtb.MaxLength = 0
  $rtb.DetectUrls = $false
  $rtb.HideSelection = $false
  $rtb.BackColor = [System.Drawing.Color]::White
  $rtb.ForeColor = [System.Drawing.Color]::Black
  $rtb.Font = $script:baseFont

  $status = New-Object System.Windows.Forms.StatusStrip
  $label = New-Object System.Windows.Forms.ToolStripStatusLabel
  $label.Text = 'seq 0 | raw 0 | lat 0 ms | last - | replay 0 | tail 0'
  [void]$status.Items.Add($label)

  [void]$form.Controls.Add($rtb)
  [void]$form.Controls.Add($status)

  $form.add_FormClosed({
    param($sender, $e)
    $rid = [string]$sender.Tag
    $st = $script:runs[$rid]
    if ($null -ne $st) {
      $st.formDetached = $true
      $st.form = $null
      $st.rtb = $null
      $st.label = $null
    }
    $script:openForms = $script:openForms - 1
    if ($script:openForms -lt 0) { $script:openForms = 0 }
  })

  $State.form = $form
  $State.rtb = $rtb
  $State.label = $label
  $script:openForms = $script:openForms + 1
  $form.Show()
  Update-FormTitle -State $State
}

function Get-RunStatusText {
  param($State)
  if ($State.captureError) { return 'incomplete (capture error)' }
  if ($State.terminal) {
    if ($State.incomplete) { return 'incomplete' }
    return [string]$State.status
  }
  if ($State.formDetached) { return 'running (display detached)' }
  return 'running'
}

function Update-FormTitle {
  param($State)
  $text = 'Run ' + $State.runId + ' - ' + (Get-RunStatusText -State $State)
  if (-not [string]::IsNullOrEmpty($State.displayError)) { $text = $text + ' [display error]' }
  $State.windowTitle = $text
  if ($null -ne $State.form) { $State.form.Text = $text }
}

# ---------------------------------------------------------------------------
# Tailing a journal
# ---------------------------------------------------------------------------

function Add-AvailableLines {
  param($State, [DateTime]$DeadlineUtc)
  $fs = $State.fs
  if ($null -eq $fs) { return }
  $fileLen = 0
  try { $fileLen = $fs.Length }
  catch {
    $State.captureError = $true
    $State.incomplete = $true
    return
  }
  $available = $fileLen - $State.readOffset
  if ($available -le 0) { return }

  $toRead = [long][Math]::Min([long]$script:MaxReadBytesPerTick, $available)
  $buf = New-Object byte[] ([int]$toRead)
  [void]$fs.Seek($State.readOffset, [System.IO.SeekOrigin]::Begin)
  $readTotal = 0
  while ($readTotal -lt $toRead) {
    $n = $fs.Read($buf, $readTotal, [int]($toRead - $readTotal))
    if ($n -le 0) { break }
    $readTotal += $n
  }
  if ($readTotal -le 0) { return }
  $State.readOffset = $State.readOffset + $readTotal

  $pending = $State.pendingBytes
  $combined = New-Object byte[] ($pending.Length + $readTotal)
  if ($pending.Length -gt 0) { [System.Array]::Copy($pending, 0, $combined, 0, $pending.Length) }
  [System.Array]::Copy($buf, 0, $combined, $pending.Length, $readTotal)
  $base = $State.readOffset - $combined.Length

  # LF (0x0A) can never appear inside a UTF-8 multi-byte sequence, so a
  # native byte search for LF is a safe and much faster splitter than a
  # per-byte PowerShell loop; the periodic deadline check keeps one tick
  # bounded even for multi-megabyte backlogs (remaining bytes stay pending).
  $start = 0
  $parsed = 0
  while ($start -lt $combined.Length) {
    $i = [System.Array]::IndexOf($combined, [byte]10, $start)
    if ($i -lt 0) { break }
    $len = $i - $start
    if ($len -gt 0 -and $combined[$i - 1] -eq 13) { $len = $len - 1 }
    if ($len -gt 0) {
      $line = [System.Text.Encoding]::UTF8.GetString($combined, $start, $len)
    }
    else {
      $line = ''
    }
    $State.lineQueue.Enqueue($line)
    $State.lineOffsets.Enqueue([long]($base + $start))
    $start = $i + 1
    $parsed++
    if (($parsed % 64) -eq 0 -and [DateTime]::UtcNow -ge $DeadlineUtc) { break }
  }
  $rest = $combined.Length - $start
  if ($rest -gt 0) {
    $newPending = New-Object byte[] $rest
    [System.Array]::Copy($combined, $start, $newPending, 0, $rest)
    $State.pendingBytes = $newPending
  }
  else {
    $State.pendingBytes = New-Object byte[] 0
  }
}

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

$script:knownEventTypes = @('session', 'agent_start', 'agent_settled', 'turn_start', 'turn_end', 'agent_end', 'message_start', 'message_end', 'message_update', 'tool_execution_start', 'tool_execution_update', 'tool_execution_end')

function Format-ScalarText {
  param($Value)
  if ($null -eq $Value) { return 'null' }
  if ($Value -is [bool]) { if ($Value) { return 'true' } return 'false' }
  if ($Value -is [string]) { return [string]$Value }
  try { return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture) }
  catch { return [string]$Value }
}

function Test-StructuredValue {
  param($Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single] -or $Value -is [DateTime]) { return $false }
  return $true
}

function Format-ValueCompact {
  param($Value)
  if (-not (Test-StructuredValue -Value $Value)) { return (Format-ScalarText -Value $Value) }
  try { return (ConvertTo-Json -InputObject $Value -Compress -Depth 20) }
  catch { return '<unrepresentable>' }
}

# One deterministic renderer for any JSON value: strings verbatim, objects and
# arrays expanded in document order, no summarising, no data dropped. Only
# used as a last resort beyond depth 20, where the compact JSON form still
# round-trips the value exactly.
function Add-ValueLines {
  param(
    [System.Collections.Generic.List[string]]$Lines,
    [string]$Indent,
    [string]$Label,
    $Value,
    [int]$Depth
  )
  if ($Depth -gt 20) {
    [void]$Lines.Add($Indent + $Label + ': ' + (Format-ValueCompact -Value $Value))
    return
  }
  if (-not (Test-StructuredValue -Value $Value)) {
    [void]$Lines.Add($Indent + $Label + ': ' + (Format-ScalarText -Value $Value))
    return
  }
  if ($Value -is [System.Array]) {
    $arr = @($Value)
    if ($arr.Count -eq 0) { [void]$Lines.Add($Indent + $Label + ': []'); return }
    [void]$Lines.Add($Indent + $Label + ':')
    for ($i = 0; $i -lt $arr.Count; $i++) {
      Add-ValueLines -Lines $Lines -Indent ($Indent + '  ') -Label ('[' + $i + ']') -Value $arr[$i] -Depth ($Depth + 1)
    }
    return
  }
  $props = @($Value.PSObject.Properties)
  if ($props.Count -eq 0) { [void]$Lines.Add($Indent + $Label + ': {}'); return }
  [void]$Lines.Add($Indent + $Label + ':')
  foreach ($p in $props) {
    Add-ValueLines -Lines $Lines -Indent ($Indent + '  ') -Label ([string]$p.Name) -Value $p.Value -Depth ($Depth + 1)
  }
}

function Add-RecordExtras {
  param($Lines, $Rec, [string[]]$Skip)
  foreach ($p in @($Rec.PSObject.Properties)) {
    $name = [string]$p.Name
    if ($Skip -contains $name) { continue }
    Add-ValueLines -Lines $Lines -Indent '   ' -Label $name -Value $p.Value -Depth 2
  }
}

function Format-Record {
  param(
    $Rec,
    [string]$RawLine,
    [ref]$LastType
  )
  $lines = New-Object 'System.Collections.Generic.List[string]'

  if ($null -eq $Rec) {
    $LastType.Value = 'unparsed'
    [void]$lines.Add('? [unparsed journal line] ' + $RawLine)
    return $lines.ToArray()
  }

  $data = ''
  if ($null -ne $Rec.data) { $data = [string]$Rec.data }
  $ch = ''
  if ($null -ne $Rec.ch) { $ch = [string]$Rec.ch }

  if ($ch -eq 'meta') {
    $kind = ''
    if ($null -ne $Rec.kind) { $kind = [string]$Rec.kind }
    if ($kind -eq 'launch') {
      $LastType.Value = 'launch'
      # data is the launch command line itself; printing it verbatim is the
      # formatted representation, not a second raw copy.
      [void]$lines.Add('== launch: ' + $data)
      Add-RecordExtras -Lines $lines -Rec $Rec -Skip @('seq', 'ts', 'ch', 'kind', 'data')
      return $lines.ToArray()
    }
    elseif ($kind -eq 'terminal') {
      $LastType.Value = 'terminal'
      $statusText = 'null'
      if ($null -ne $Rec.status) { $statusText = Format-ScalarText -Value $Rec.status }
      $exitText = 'null'
      if ($null -ne $Rec.exitCode) { $exitText = Format-ScalarText -Value $Rec.exitCode }
      $signalText = 'null'
      if ($null -ne $Rec.signal) { $signalText = Format-ScalarText -Value $Rec.signal }
      [void]$lines.Add('== terminal status=' + $statusText + ' exit=' + $exitText + ' signal=' + $signalText)
      $dataObj = $null
      try { $dataObj = ConvertFrom-Json -InputObject $data }
      catch { $dataObj = $null }
      $dataHandled = $false
      if (Test-StructuredValue -Value $dataObj) {
        if ($dataObj -is [System.Array]) {
          Add-ValueLines -Lines $lines -Indent '   ' -Label 'data' -Value $dataObj -Depth 2
        }
        else {
          # status/exitCode/signal are already in the header; render any
          # other payload field instead of duplicating the raw JSON.
          foreach ($p in @($dataObj.PSObject.Properties)) {
            if ($p.Name -eq 'status' -or $p.Name -eq 'exitCode' -or $p.Name -eq 'signal') { continue }
            Add-ValueLines -Lines $lines -Indent '   ' -Label ([string]$p.Name) -Value $p.Value -Depth 2
          }
        }
        $dataHandled = $true
      }
      if (-not $dataHandled -and -not [string]::IsNullOrEmpty($data)) {
        # Unparseable payload: keep it losslessly alongside the header.
        [void]$lines.Add('   data: ' + $data)
      }
      Add-RecordExtras -Lines $lines -Rec $Rec -Skip @('seq', 'ts', 'ch', 'kind', 'status', 'exitCode', 'signal', 'data')
      return $lines.ToArray()
    }
    elseif ($kind -eq 'captureError') {
      $LastType.Value = 'captureError'
      [void]$lines.Add('!! capture error: ' + $data)
      $skipExtra = @('seq', 'ts', 'ch', 'kind', 'data')
      if (($null -ne $Rec.message) -and ([string]$Rec.message -ceq $data)) { $skipExtra += 'message' }
      Add-RecordExtras -Lines $lines -Rec $Rec -Skip $skipExtra
      return $lines.ToArray()
    }
    else {
      $LastType.Value = 'meta'
      [void]$lines.Add('== meta kind=' + $kind + ': ' + $data)
      Add-RecordExtras -Lines $lines -Rec $Rec -Skip @('seq', 'ts', 'ch', 'kind', 'data')
      return $lines.ToArray()
    }
  }

  if ($ch -eq 'stderr') {
    $LastType.Value = 'stderr'
    [void]$lines.Add('! stderr: ' + $data)
    return $lines.ToArray()
  }

  if ($ch -ne 'stdout') {
    $LastType.Value = $ch
    [void]$lines.Add('? [channel ' + $ch + '] ' + $data)
    return $lines.ToArray()
  }

  $evt = $null
  try { $evt = ConvertFrom-Json -InputObject $data }
  catch { $evt = $null }
  if ($null -eq $evt -or $null -eq $evt.type) {
    $LastType.Value = 'unparsed'
    [void]$lines.Add('? [unparsed stdout] ' + $data)
    return $lines.ToArray()
  }

  $type = [string]$evt.type
  $LastType.Value = $type

  if ($script:knownEventTypes -notcontains $type) {
    # Unknown event type: raw fallback, lossless.
    [void]$lines.Add('? [event ' + $type + '] ' + $data)
    return $lines.ToArray()
  }
  # Recognised event: one formatted block, every field exactly once, no raw
  # JSON copy. String values keep their exact content (empty strings too).
  [void]$lines.Add('== ' + $type)
  foreach ($p in @($evt.PSObject.Properties)) {
    if ([string]$p.Name -eq 'type') { continue }
    Add-ValueLines -Lines $lines -Indent '   ' -Label ([string]$p.Name) -Value $p.Value -Depth 1
  }
  return $lines.ToArray()
}

# ---------------------------------------------------------------------------
# Per-record processing
# ---------------------------------------------------------------------------

function Process-Line {
  param(
    $State,
    [string]$Line,
    [long]$Offset,
    $Batch,
    [double]$NowMs
  )

  if ([string]::IsNullOrEmpty($Line)) {
    [void]$Batch.AppendLine('? [blank journal line]')
    $State.renderedCount = $State.renderedCount + 1
    return
  }

  $rec = $null
  try { $rec = ConvertFrom-Json -InputObject $Line }
  catch { $rec = $null }

  if ($null -ne $rec -and $null -ne $rec.seq) {
    $seq = [int]$rec.seq
    if ($seq -ne $State.seqExpected) {
      $State.receivedOrderOk = $false
      if ($seq -gt $State.seqExpected) { $State.incomplete = $true }
    }
    $State.seqExpected = $seq + 1
    $State.lastSeq = $seq
  }
  else {
    $State.receivedOrderOk = $false
  }

  if ($Offset -lt $State.startSize) { $State.replayedCount = $State.replayedCount + 1 }
  else { $State.tailedCount = $State.tailedCount + 1 }

  if ($null -ne $rec -and $null -ne $rec.ch -and [string]$rec.ch -eq 'meta') {
    $kind = ''
    if ($null -ne $rec.kind) { $kind = [string]$rec.kind }
    if ($kind -eq 'captureError') {
      $State.captureError = $true
      $State.incomplete = $true
    }
    elseif ($kind -eq 'terminal' -and -not $State.terminal) {
      $signalOk = ($null -eq $rec.signal)
      $State.terminal = $true
      $State.status = [string]$rec.status
      if ($State.captureError -or (-not $State.receivedOrderOk) -or $State.incomplete -or (-not $signalOk)) {
        $State.incomplete = $true
      }
      else {
        Notify-Completion -State $State
      }
      Update-FormTitle -State $State
    }
  }

  if ($null -ne $rec -and $null -ne $rec.ts) {
    $lat = $NowMs - [double]$rec.ts
    if ($lat -lt 0) { $lat = 0 }
    [void]$State.latencySamples.Add($lat)
    if ($lat -gt $State.maxLatencyMs) { $State.maxLatencyMs = [int][Math]::Round($lat) }
  }

  if ($null -ne $rec -and $null -ne $rec.data) {
    [void]$State.dataList.Add([string]$rec.data)
  }

  $lastType = ''
  $formatted = Format-Record -Rec $rec -RawLine $Line -LastType ([ref]$lastType)
  foreach ($fl in $formatted) { [void]$Batch.AppendLine($fl) }
  if (-not [string]::IsNullOrEmpty($lastType)) { $State.lastType = $lastType }
  $State.renderedCount = $State.renderedCount + 1
}

function Append-ToDisplay {
  param($State, [string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return }
  [void]$State.rawSb.Append($Text)
  if ($null -eq $State.rtb) { return }
  $rtb = $State.rtb
  $atBottom = $State.pinnedAutoscroll
  if ($rtb.TextLength -gt 0) {
    $atBottom = ($rtb.SelectionStart -ge ($rtb.TextLength - 1))
  }
  Add-RichTextWithFallback -Rtb $rtb -Text $Text
  if ($atBottom) {
    $rtb.SelectionStart = $rtb.TextLength
    $rtb.SelectionLength = 0
    $rtb.ScrollToCaret()
    $State.pinnedAutoscroll = $true
  }
  else {
    $State.pinnedAutoscroll = $false
  }
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

function Notify-Completion {
  param($State)
  if ($State.notified) { return }
  $State.notified = $true
  [void]$script:notifications.Add($State.runId)
  if ($script:notificationCounts.ContainsKey($State.runId)) {
    $script:notificationCounts[$State.runId] = [int]$script:notificationCounts[$State.runId] + 1
  }
  else {
    $script:notificationCounts[$State.runId] = 1
  }
  if (-not $script:HeadlessMode) { Show-NotificationForm -State $State }
}

function Show-NotificationForm {
  param($State)
  try {
    $nf = New-Object System.Windows.Forms.Form
    $nf.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $nf.TopMost = $true
    $nf.ShowInTaskbar = $false
    $nf.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $nf.ClientSize = New-Object System.Drawing.Size(640, 56)
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $n = $script:activeNotifications.Count
    $nf.Location = New-Object System.Drawing.Point(($wa.Right - 476), ($wa.Top + 16 + (($n % 6) * 64)))
    $nf.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lbl.AutoEllipsis = $true
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $lbl.Text = 'Run ' + $State.runId + ' completed (' + [string]$State.status + ')'
    [void]$nf.Controls.Add($lbl)
    $nf.Show()
    $script:activeNotifications.Add([pscustomobject]@{
      Form    = $nf
      CloseAt = [DateTime]::UtcNow.AddMilliseconds($script:NotifyMs)
    })
  }
  catch {
    [void]$script:viewerErrors.Add('notification form: ' + $_.Exception.Message)
  }
}

function Close-ExpiredNotifications {
  if ($script:activeNotifications.Count -eq 0) { return }
  $keep = New-Object 'System.Collections.Generic.List[object]'
  foreach ($n in $script:activeNotifications) {
    if ([DateTime]::UtcNow -ge $n.CloseAt) {
      try { $n.Form.Close() } catch { }
      $n.Form.Dispose()
    }
    else {
      $keep.Add($n)
    }
  }
  $script:activeNotifications = $keep
}

# ---------------------------------------------------------------------------
# Tick
# ---------------------------------------------------------------------------

function Invoke-RunTick {
  param($State, [double]$NowMs, [DateTime]$DeadlineUtc)
  if ($State.lineQueue.Count -lt $script:BatchLines -and [DateTime]::UtcNow -lt $DeadlineUtc) {
    Add-AvailableLines -State $State -DeadlineUtc $DeadlineUtc
  }

  $batch = New-Object System.Text.StringBuilder
  $consumed = 0
  while ($consumed -lt $script:BatchLines -and $State.lineQueue.Count -gt 0) {
    if ([DateTime]::UtcNow -ge $DeadlineUtc) { break }
    $line = $State.lineQueue.Dequeue()
    $offset = $State.lineOffsets.Dequeue()
    Process-Line -State $State -Line $line -Offset $offset -Batch $batch -NowMs $NowMs
    $consumed++
  }

  if (($State.terminal -or $State.captureError) -and (-not $State.partialFlushed) -and $State.pendingBytes.Length -gt 0 -and $State.lineQueue.Count -eq 0) {
    $pt = [System.Text.Encoding]::UTF8.GetString($State.pendingBytes)
    [void]$batch.AppendLine('? [partial unparsed tail] ' + $pt)
    $State.renderedCount = $State.renderedCount + 1
    $State.partialFlushed = $true
    $State.pendingBytes = New-Object byte[] 0
  }

  if ($batch.Length -gt 0) {
    Append-ToDisplay -State $State -Text $batch.ToString()
  }
}

function Update-StatusLabels {
  foreach ($state in $script:runs.Values) {
    if ($null -eq $state.label) { continue }
    $state.label.Text = ('seq {0} | raw {1} | lat {2} ms | last {3} | replay {4} | tail {5}' -f `
      $state.lastSeq, $state.rawSb.Length, $state.maxLatencyMs, $state.lastType, $state.replayedCount, $state.tailedCount)
  }
}

function Test-AllRunsSettled {
  if ($script:runs.Count -eq 0) { return $false }
  foreach ($s in $script:runs.Values) {
    if (-not ($s.terminal -or $s.captureError)) { return $false }
    if ($s.lineQueue.Count -gt 0) { return $false }
    if ($s.pendingBytes.Length -gt 0 -and (-not $s.partialFlushed)) { return $false }
    try {
      if ($s.readOffset -lt $s.fs.Length) { return $false }
    }
    catch { }
  }
  return $true
}

function Invoke-Tick {
  $now = Get-NowMs
  if ($script:lastTickAt -gt 0) {
    $gap = $now - $script:lastTickAt
    if ($gap -gt $script:maxHeartbeatGapMs) { $script:maxHeartbeatGapMs = $gap }
  }
  $script:lastTickAt = $now
  $script:tickCount = $script:tickCount + 1

  Discover-Runs

  $forceErrorFile = Join-Path $script:FixtureDir 'force-display-error.txt'
  $forceIds = @()
  if (Test-Path -LiteralPath $forceErrorFile) {
    try { $forceIds = @(Get-Content -LiteralPath $forceErrorFile -ErrorAction SilentlyContinue) }
    catch { $forceIds = @() }
  }

  # One shared wall-clock budget for this tick; rotate the starting Run each
  # tick so a large backlog in one journal cannot starve the others.
  $deadlineUtc = [DateTime]::UtcNow.AddMilliseconds($script:TickBudgetMs)
  $orderedStates = @($script:runs.Values)
  if ($orderedStates.Count -gt 1) {
    $startIndex = $script:tickRotation % $orderedStates.Count
    $rotated = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $orderedStates.Count; $i++) {
      $rotated.Add($orderedStates[($startIndex + $i) % $orderedStates.Count])
    }
    $orderedStates = $rotated.ToArray()
    $script:tickRotation = ($startIndex + 1) % $orderedStates.Count
  }

  foreach ($state in $orderedStates) {
    if ($script:maxHeartbeatGapMs -gt $state.maxHeartbeatGapMs) { $state.maxHeartbeatGapMs = $script:maxHeartbeatGapMs }
    try {
      if ((-not $state.displayErrorThrown) -and ($forceIds -contains $state.runId)) {
        $state.displayErrorThrown = $true
        throw ('simulated display failure for run ' + $state.runId)
      }
      Invoke-RunTick -State $state -NowMs $now -DeadlineUtc $deadlineUtc
    }
    catch {
      $state.displayError = $_.Exception.Message
      [void]$script:viewerErrors.Add('display ' + $state.runId + ' : ' + $state.displayError)
      $errText = '?? display error: ' + $state.displayError + [Environment]::NewLine
      [void]$state.rawSb.Append($errText)
      if ($null -ne $state.rtb) {
        Add-RichTextWithFallback -Rtb $state.rtb -Text $errText
        $state.rtb.SelectionStart = $state.rtb.TextLength
        $state.rtb.SelectionLength = 0
        $state.rtb.ScrollToCaret()
      }
      Update-FormTitle -State $state
    }
  }

  if (-not $script:HeadlessMode) {
    Close-ExpiredNotifications
  }

  Update-StatusLabels

  if ($script:HeadlessMode) {
    if (Test-AllRunsSettled) {
      if ($null -eq $script:settledAt) { $script:settledAt = Get-NowMs }
      $manifestPath = Join-Path $script:FixtureDir 'manifest.json'
      if ((Test-Path -LiteralPath $manifestPath) -or (((Get-NowMs) - $script:settledAt) -gt 5000)) {
        Write-Report
      }
    }
    elseif (((Get-NowMs) - $script:startedAt) -gt $script:HeadlessTimeoutMs -and $script:runs.Count -gt 0) {
      [void]$script:viewerErrors.Add('headless timeout reached before all runs settled')
      Write-Report
    }
    if ($script:runs.Count -eq 0 -and (((Get-NowMs) - $script:startedAt) -gt $script:WaitForFirstRunMs)) {
      Write-Report
    }
  }
  else {
    if ($script:runs.Count -gt 0 -and $script:openForms -eq 0) {
      Write-Report
      [System.Windows.Forms.Application]::Exit()
    }
    elseif ($script:runs.Count -eq 0 -and (((Get-NowMs) - $script:startedAt) -gt $script:WaitForFirstRunMs)) {
      Write-Report
      [System.Windows.Forms.Application]::Exit()
    }
  }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

function Get-Sha256Hex {
  param([string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha.ComputeHash($bytes)
  }
  finally {
    $sha.Dispose()
  }
  return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-P95 {
  param($Samples)
  if ($null -eq $Samples -or $Samples.Count -eq 0) { return 0 }
  $arr = $Samples.ToArray()
  [System.Array]::Sort($arr)
  $idx = [int][Math]::Ceiling($arr.Length * 0.95) - 1
  if ($idx -lt 0) { $idx = 0 }
  if ($idx -ge $arr.Length) { $idx = $arr.Length - 1 }
  return [int][Math]::Round([double]$arr[$idx])
}

function Get-ScenarioMap {
  $map = @{}
  $manifestPath = Join-Path $script:FixtureDir 'manifest.json'
  if (Test-Path -LiteralPath $manifestPath) {
    try {
      $raw = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
      $mf = ConvertFrom-Json -InputObject $raw
      foreach ($m in @($mf.runs)) {
        if ($null -ne $m) { $map[[string]$m.runId] = [string]$m.scenario }
      }
    }
    catch {
      [void]$script:viewerErrors.Add('manifest read: ' + $_.Exception.Message)
    }
  }
  return $map
}

function Write-Report {
  if ($script:reportWritten) { return }
  $script:reportWritten = $true
  try {
    $endedAt = Get-NowMs
    $scenarioMap = Get-ScenarioMap
    $runList = New-Object 'System.Collections.Generic.List[object]'
    foreach ($state in $script:runs.Values) {
      $rawJoined = [string]::Join("`n", $state.dataList.ToArray())
      $text = $state.rawSb.ToString()
      $scenario = 'unknown'
      if ($scenarioMap.ContainsKey($state.runId)) { $scenario = [string]$scenarioMap[$state.runId] }
      $runList.Add([pscustomobject][ordered]@{
        runId             = $state.runId
        scenario          = $scenario
        replayedCount     = $state.replayedCount
        tailedCount       = $state.tailedCount
        renderedCount     = $state.renderedCount
        lastSeq           = $state.lastSeq
        receivedOrderOk   = $state.receivedOrderOk
        rawSha256         = (Get-Sha256Hex -Text $rawJoined)
        textLength        = $text.Length
        textSha256        = (Get-Sha256Hex -Text $text)
        terminal          = [bool]$state.terminal
        status            = $state.status
        incomplete        = [bool]$state.incomplete
        captureError      = [bool]$state.captureError
        displayError      = $state.displayError
        notified          = [bool]$state.notified
        maxLatencyMs      = $state.maxLatencyMs
        p95LatencyMs      = (Get-P95 -Samples $state.latencySamples)
        maxHeartbeatGapMs = $state.maxHeartbeatGapMs
        formDetached      = [bool]$state.formDetached
        windowTitle       = [string]$state.windowTitle
      })

      $renderedPath = Join-Path $script:FixtureDir ($state.runId + '.rendered.txt')
      [System.IO.File]::WriteAllText($renderedPath, $text, $utf8NoBom)
    }

    # Bounded font-resolution evidence: how many families were touched and how
    # large their cached maps are. No full enumeration happens here.
    $fontCacheSummary = [ordered]@{}
    foreach ($fam in ($script:fontGlyphCache.Keys | Sort-Object)) {
      $fi = $script:fontGlyphCache[$fam]
      $fontCacheSummary[$fam] = [pscustomobject]@{ resolved = [bool]$fi.resolved; glyphCount = [int]$fi.glyphCount; typefaceCount = [int]$fi.typefaceCount }
    }

    $report = [pscustomobject][ordered]@{
      tool              = 'per-run-window.ps1'
      fixtureDir        = $script:FixtureDir
      startedAt         = $script:startedAt
      endedAt           = $endedAt
      headless          = $script:HeadlessMode
      tickMs            = $script:TickMs
      batchLines        = $script:BatchLines
      ticks             = $script:tickCount
      maxHeartbeatGapMs = $script:maxHeartbeatGapMs
      notifications     = @($script:notifications)
      notificationCounts = $script:notificationCounts
      displayFonts      = $script:displayFonts
      displayFontDetails = $script:displayFontDetails
      fontFamiliesResolved = $script:fontGlyphCache.Count
      fontCache         = $fontCacheSummary
      runs              = $runList
    }
    $json = ConvertTo-Json -InputObject $report -Depth 10
    [System.IO.File]::WriteAllText($script:ReportPath, $json, $utf8NoBom)
  }
  catch {
    [void]$script:viewerErrors.Add('write report: ' + $_.Exception.Message)
  }
  finally {
    if ($script:viewerErrors.Count -gt 0) {
      try {
        [System.IO.File]::WriteAllText((Join-Path $script:FixtureDir 'viewer-errors.log'), ([string]::Join([Environment]::NewLine, $script:viewerErrors.ToArray())), $utf8NoBom)
      }
      catch { }
    }
  }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

# -SelfTest needs the formatter functions defined above, so it runs here.
if ($SelfTest) { exit (Invoke-SelfTest) }

Resolve-DisplayFonts

if ($script:HeadlessMode) {
  Write-Host ('[viewer] headless mode: fixture={0} report={1}' -f $script:FixtureDir, $script:ReportPath)
  while (-not $script:reportWritten) {
    Invoke-Tick
    if (-not $script:reportWritten) { Start-Sleep -Milliseconds $script:TickMs }
  }
  Write-Host ('[viewer] headless done: runs={0} notifications={1} errors={2}' -f $script:runs.Count, $script:notifications.Count, $script:viewerErrors.Count)
}
else {
  $script:timer = New-Object System.Windows.Forms.Timer
  $script:timer.Interval = $script:TickMs
  $script:timer.Add_Tick({
    try { Invoke-Tick }
    catch { [void]$script:viewerErrors.Add('tick: ' + $_.Exception.Message) }
  })
  $script:timer.Start()
  [System.Windows.Forms.Application]::Run()
  $script:timer.Stop()
  if (-not $script:reportWritten) { Write-Report }
}
