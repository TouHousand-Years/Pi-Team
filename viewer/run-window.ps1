#requires -Version 5.1
<#
  run-window.ps1 - the production Run Window (ticket 07).

  One process hosts exactly one independent, read-only window for exactly one
  Run bundle. Node launches it (see src/viewer/manager.ts) in STA mode with an
  argument array; nothing is interpolated through a shell.

  What it does
  ------------
  Reads <BundleDir>/transcript.jsonl (Transcript schema v1), replays every
  record already on disk, then tails everything written afterwards by polling
  the file. Formatted records are appended once, carrying every payload field
  exactly once: streaming fragments are withheld while the Run is healthy and
  reconciled into their complete event, so there is no second raw JSON copy.
  Unknown, malformed, foreign-version, or uncovered content stays visible
  through explicit lossless fallbacks. Nothing is truncated or summarised away.

  Evidence vs display
  -------------------
  The transcript is the evidence; this process never writes to it. Raw bytes
  are reassembled per byte group (groupId/part/final) before decoding, so a
  multibyte character split across chunks is displayed intact. Every complete
  file line read before the terminal record is fed to a SHA-256 exactly as it
  appears on disk; if it does not match the terminal record's sha256, the Run
  is marked INCOMPLETE. Sequence gaps, a trailing unterminated line, a missing
  terminal record, capture errors, and foreign schema versions do the same.

  Completion
  ----------
  The terminal record is the authority for outcome (succeeded / failed /
  protocol-error / incomplete). A clean succeeded Run shows SUCCEEDED and plays
  one normal system sound; every other terminal class - and every integrity
  downgrade - shows INCOMPLETE (with the underlying outcome in the status bar)
  and plays one warning sound. The attempt is recorded once in
  viewer-state.json (alertAttemptedAt) so reopening never replays it. Closing
  the window forfeits the indication and the sound; it never affects capture or
  the Run. Completed windows stay open until closed by hand.

  Read-only by construction: no input, no retry, no terminate. Available
  interactions are scrolling, selection, copy, select-all, find, and a
  line-wrap toggle. A reopen request (viewer-request.json) raises the window.

  Modes
  -----
  GUI (default): -BundleDir <dir>
  -Replay:       no Forms. Drains the bundle to its terminal record, writes the
                 rendered text to -OutPath, prints a JSON summary on stdout and
                 exits. Used by the automated formatter matrix; not a
                 user-facing feature.
  -SelfTest:     no files, no Forms. Verifies the Unicode/RTF/font path and the
                 formatter's honesty probes. Prints SELFTEST PASS/FAIL.
#>
[CmdletBinding()]
param(
  [string]$BundleDir,

  [switch]$Replay,

  [string]$OutPath,

  [ValidateRange(10, 2000)]
  [int]$TickMs = 100,

  [ValidateRange(200, 600000)]
  [int]$ReplayTimeoutMs = 15000,

  [ValidateRange(1, 20000)]
  [int]$BatchLines = 2000,

  [ValidateRange(65536, 67108864)]
  [int]$MaxReadBytesPerTick = 4194304,

  [switch]$NoSound,

  [switch]$SelfTest
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# WPF is used only as a glyph-coverage oracle for font selection: GlyphTypeface's
# CharacterToGlyphMap decodes surrogate pairs correctly, while GDI
# GetGlyphIndicesW reports 0xFFFF for every non-BMP scalar even in fonts that
# cover it.
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Codepoint classifier (per-category font runs) and an RTF escaper. Pure ASCII
# source so Windows PowerShell 5.1 cannot mangle it. Sticky codepoints (ZWJ,
# ZWNJ, variation selectors, combining marks, skin-tone modifiers, keycaps)
# inherit the preceding scalar's category so a ZWJ family stays one emoji run.
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
    // chosen font must map. Used by -SelfTest for an independent coverage check.
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
    // CR/LF become paragraph breaks, tab becomes a tab stop, other C0 controls
    // are dropped (RichEdit cannot display them), and everything at or above
    // U+0080 becomes a signed unicode escape with the uc1 fallback so the
    // fragment stays pure ASCII. Char code 92 is used for backslash so this
    // embedded source contains no escape-prone literals.
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

$script:fontGlyphCache = @{}
$script:fontsResolved = $false
$script:categoryOrder = @()
$script:rtfBackslash = [string][char]92

# CharacterToGlyphMap is built once per family and reused; only the family's
# Normal typeface is consulted, which is the one the RichTextBox uses.
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
  # The first installed family whose cached glyph map covers the category
  # sample wins; if none covers it, the first installed family is used (gaps
  # are visible, never silently claimed as covered).
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
  $script:categoryFonts = @{}
  $script:categoryFontIndex = @{}
  $catIndex = 0
  foreach ($cat in $candidates.Keys) {
    $script:categoryFontIndex[$cat] = $catIndex
    $catIndex++
    $chosen = $null
    $firstInstalled = $null
    foreach ($cand in $candidates[$cat]) {
      if (-not (Test-FontInstalled -Family $cand)) { continue }
      if ($null -eq $firstInstalled) { $firstInstalled = $cand }
      $info = Get-FontGlyphInfo -Family $cand
      if ($null -eq $info.map) { continue }
      $miss = @(Get-MissingCodePoints -Map $info.map -CodePoints $samples[$cat])
      if ($miss.Count -eq 0) { $chosen = $cand; break }
      if ($null -eq $chosen) { $chosen = $cand }
    }
    if ($null -eq $chosen -and $null -ne $firstInstalled) { $chosen = $firstInstalled }
    if ($null -eq $chosen) { $chosen = 'Segoe UI' }
    $script:displayFonts[$cat] = $chosen
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
# SelectedRtf replaces the whole selection with a complete document. fnil with
# no charset hint is deliberate: GDI font-links per glyph exactly like a
# per-run SelectionFont path, and sticky codepoints survive in the model.
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
  # One fragment per append: O(text) instead of per-run SelectionFont work.
  $fragment = Build-RtfFragment -Text $Text
  $Rtb.SelectionStart = $Rtb.TextLength
  $Rtb.SelectionLength = 0
  $Rtb.SelectedRtf = $fragment
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

$script:utf8 = New-Object System.Text.UTF8Encoding($false)
$script:utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-NowMs { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function Format-CompactJson {
  param($Value)
  try { return (ConvertTo-Json -InputObject $Value -Compress -Depth 30) }
  catch { return '<unrepresentable>' }
}

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

function Get-PropValue {
  param($Rec, [string]$Name)
  if ($null -eq $Rec) { return $null }
  $p = $Rec.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

function Test-HasProp {
  param($Rec, [string]$Name)
  if ($null -eq $Rec) { return $false }
  return ($null -ne $Rec.PSObject.Properties[$Name])
}

# One deterministic renderer for any JSON value: strings verbatim, objects and
# arrays expanded in document order, no summarising, no data dropped. Only used
# past depth 20, where the compact JSON form still round-trips exactly.
function Add-ValueLines {
  param(
    [System.Collections.Generic.List[string]]$Lines,
    [string]$Indent,
    [string]$Label,
    $Value,
    [int]$Depth
  )
  if ($Depth -gt 20) {
    [void]$Lines.Add($Indent + $Label + ': ' + (Format-CompactJson -Value $Value))
    return
  }
  if (-not (Test-StructuredValue -Value $Value)) {
    $text = Format-ScalarText -Value $Value
    if ($text.Contains("`n")) {
      [void]$Lines.Add($Indent + $Label + ':')
      foreach ($seg in $text.Split("`n")) { [void]$Lines.Add($Indent + '  ' + $seg) }
    }
    else {
      [void]$Lines.Add($Indent + $Label + ': ' + $text)
    }
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
    Add-ValueLines -Lines $Lines -Indent '   ' -Label $name -Value $p.Value -Depth 1
  }
}

# ---------------------------------------------------------------------------
# Transcript v1 record model
# ---------------------------------------------------------------------------

# Recognised wire event types whose payload is rendered in full (never dropped,
# never summarised). The first group carries the dedup rules of the accepted
# design; the second is source-confirmed but shape-unverified, so it is
# rendered generically - lossless, but with no dedup assumptions.
$script:LifecycleTypes = @(
  'session', 'agent_start', 'agent_settled', 'agent_end', 'turn_start', 'turn_end',
  'message_start', 'message_end', 'message_update',
  'tool_execution_start', 'tool_execution_update', 'tool_execution_end'
)
$script:GenericEventTypes = @(
  'queue_update', 'compaction_start', 'compaction_end', 'auto_retry_start', 'auto_retry_end',
  'summarization_retry_scheduled', 'summarization_retry_attempt_start', 'summarization_retry_finished',
  'thinking_level_changed', 'session_info_changed', 'entry_appended', 'bash_execution_update'
)

function New-RunState {
  param([string]$RunBundleDir)
  $state = [pscustomobject]@{
    bundleDir         = $RunBundleDir
    transcriptPath    = (Join-Path $RunBundleDir 'transcript.jsonl')
    fs                = $null
    startSize         = [long]0
    readOffset        = [long]0
    runId             = ''
    session           = ''
    piSessionId       = ''
    cwd               = ''
    startedAtUtc      = ''
    launch            = $null
    promptSummary     = ''
    # byte channels: buf = undecoded bytes not yet terminated by LF
    channels          = @{}
    groups            = @{}
    seqExpected       = 1
    lastSeq           = 0
    priorLastSeq      = 0
    recordCount       = 0
    replayedCount     = 0
    tailedCount       = 0
    terminalSeen      = $false
    terminal          = $null
    lineAfterTerminal = $false
    incompleteBlocks  = (New-Object 'System.Collections.Generic.List[object]')
    openBlocks        = @{}
    toolUpdates       = @{}
    toolEnded         = @{}
    integrity         = (New-Object 'System.Collections.Generic.List[string]')
    captureError      = $null
    token             = 'RUNNING'
    tokenDetail       = ''
    soundDecision     = 'none'
    soundPlayed       = $false
    soundAttempted    = $false
    soundSuppressed   = $false
    soundWouldAttempt = $false
    lastType          = '-'
    assistantMessagesRendered = 0
    batch             = (New-Object 'System.Collections.Generic.List[string]')
    text              = (New-Object System.Text.StringBuilder)
    hash              = $null
    hashOk            = $true
    hashComputed      = ''
    hashError         = $null
    sourceReleased    = $false
    sourceCleaned     = $false
    releasedNote      = $false
    displayError      = $null
    formDetached      = $false
    form              = $null
    rtb               = $null
    headerLabel       = $null
    statusIcon        = $null
    statusLabel       = $null
    statusDetail      = $null
    wrapLabel         = $null
    completed         = $false
    tickBudgetMs      = 250
  }
  foreach ($ch in @('stdout', 'stderr', 'stdin')) {
    $state.channels[$ch] = @{ buf = (New-Object byte[] 0) }
  }
  if (Test-Path -LiteralPath $state.transcriptPath) {
    $state.fs = New-Object System.IO.FileStream($state.transcriptPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $state.startSize = [long]$state.fs.Length
  }
  $state.hash = New-HashState
  return $state
}

# Incremental SHA-256; the scratch output buffer keeps this portable across
# .NET Framework and .NET (where TransformBlock tolerates a null output buffer).
function New-HashState {
  try {
    return @{ sha = [System.Security.Cryptography.SHA256]::Create(); scratch = $null; failed = $false; bytes = 0; lines = 0 }
  }
  catch {
    return @{ sha = $null; scratch = $null; failed = $true; bytes = 0; lines = 0 }
  }
}

function Add-HashBytes {
  param($State, [byte[]]$Bytes, [int]$Offset, [int]$Count)
  if ($null -eq $State.hash -or $State.hash.failed) { return }
  try {
    if ($State.hash.scratch -eq $null -or $State.hash.scratch.Length -lt $Count) {
      $State.hash.scratch = New-Object byte[] $Count
    }
    [void]$State.hash.sha.TransformBlock($Bytes, $Offset, $Count, $State.hash.scratch, 0)
    $State.hash.bytes = $State.hash.bytes + $Count
    $State.hash.lines = $State.hash.lines + 1
  }
  catch {
    $State.hash.failed = $true
    $State.hashError = $_.Exception.Message
  }
}

function Get-HashHex {
  param($State)
  if ($null -eq $State.hash -or $State.hash.failed -or $null -eq $State.hash.sha) { return '' }
  try {
    [void]$State.hash.sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
    $digest = $State.hash.sha.Hash
    return ([System.BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
  }
  catch {
    $State.hash.failed = $true
    return ''
  }
}

function Add-Integrity {
  param($State, [string]$Reason)
  if ([string]::IsNullOrEmpty($Reason)) { return }
  if (-not $State.integrity.Contains($Reason)) { [void]$State.integrity.Add($Reason) }
}

# ---------------------------------------------------------------------------
# Rendering helpers used by the formatter
# ---------------------------------------------------------------------------

function Add-Line {
  param($State, [string]$Text)
  [void]$State.batch.Add($Text)
}

function Format-ConstraintsText {
  param($Constraints)
  if (-not (Test-StructuredValue -Value $Constraints)) { return 'none' }
  $parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($p in @($Constraints.PSObject.Properties)) {
    $v = $p.Value
    if ($v -is [System.Array]) {
      [void]$parts.Add([string]$p.Name + '=[' + [string]::Join(',', @($v | ForEach-Object { Format-ScalarText -Value $_ })) + ']')
    }
    else {
      [void]$parts.Add([string]$p.Name + '=' + (Format-ScalarText -Value $v))
    }
  }
  if ($parts.Count -eq 0) { return 'none' }
  return [string]::Join(' ', $parts.ToArray())
}

# --- assistant streaming blocks -------------------------------------------

# Fragments are withheld while the Run is healthy: a *_delta appends to its
# block, and the block is rendered once when its completion event arrives.
function Start-Block {
  param($State, [string]$Kind, [int]$ContentIndex, [string]$ToolName)
  $key = $Kind + ':' + [string]$ContentIndex
  $block = [pscustomobject]@{
    kind         = $Kind
    contentIndex = $ContentIndex
    toolName     = $ToolName
    buffer       = (New-Object System.Text.StringBuilder)
    rendered     = $false
  }
  $State.openBlocks[$key] = $block
  return $block
}

function Add-BlockFragment {
  param($State, [string]$Kind, [int]$ContentIndex, [string]$Delta)
  if ([string]::IsNullOrEmpty($Delta)) { return }
  $key = $Kind + ':' + [string]$ContentIndex
  if (-not $State.openBlocks.ContainsKey($key)) {
    # A delta without a start event: keep it, it is still lossless.
    [void](Start-Block -State $State -Kind $Kind -ContentIndex $ContentIndex -ToolName '')
  }
  [void]$State.openBlocks[$key].buffer.Append($Delta)
}

# Returns the text to display for a block: the completion event's own content
# when it has one (authoritative), otherwise the withheld fragments - which are
# then shown explicitly as unreconciled rather than silently dropped.
function Close-Block {
  param($State, [string]$Kind, [int]$ContentIndex, $Content, [string]$Source)
  $key = $Kind + ':' + [string]$ContentIndex
  $fragments = ''
  if ($State.openBlocks.ContainsKey($key)) {
    $fragments = $State.openBlocks[$key].buffer.ToString()
    $State.openBlocks.Remove($key)
  }
  if ($null -ne $Content) {
    return @{ text = (Format-ScalarText -Value $Content); reconciled = $true; source = $Source }
  }
  return @{ text = $fragments; reconciled = ($fragments.Length -eq 0); source = 'streaming fragments' }
}

# Any block that never received its completion event is shown once, explicitly
# labelled as unfinished output.
function Flush-UnfinishedBlocks {
  param($State, [string]$When)
  $keys = @($State.openBlocks.Keys)
  foreach ($key in $keys) {
    $block = $State.openBlocks[$key]
    $text = $block.buffer.ToString()
    $State.openBlocks.Remove($key)
    Add-Line -State $State -Text ('-- unfinished ' + $block.kind + ' output [' + [string]$block.contentIndex + '] (' + $When + '; no completion event was captured)')
    if ($text.Length -gt 0) {
      foreach ($seg in $text.Split("`n")) { Add-Line -State $State -Text ('   ' + $seg) }
    }
  }
}

function Get-TextBlocks {
  param($Content)
  $out = New-Object 'System.Collections.Generic.List[string]'
  if (-not (Test-StructuredValue -Value $Content)) {
    if ($null -ne $Content) { [void]$out.Add((Format-ScalarText -Value $Content)) }
    return , $out
  }
  if ($Content -is [System.Array]) {
    foreach ($item in @($Content)) {
      if (Test-HasProp -Rec $item -Name 'text') { [void]$out.Add((Format-ScalarText -Value (Get-PropValue -Rec $item -Name 'text'))) }
    }
  }
  elseif (Test-HasProp -Rec $Content -Name 'text') {
    [void]$out.Add((Format-ScalarText -Value (Get-PropValue -Rec $Content -Name 'text')))
  }
  return , $out
}

function Join-TextBlocks {
  param($Content)
  # Get-TextBlocks returns a List; PowerShell unrolls a collection returned from
  # a function, so @() re-materialises it before joining.
  $blocks = @(Get-TextBlocks -Content $Content)
  return [string]::Join("`n", $blocks)
}

function Add-TextLines {
  param($State, [string]$Indent, [string]$Label, [string]$Text)
  if ([string]::IsNullOrEmpty($Text)) {
    Add-Line -State $State -Text ($Indent + $Label + ': (empty)')
    return
  }
  foreach ($seg in $Text.Split("`n")) { Add-Line -State $State -Text ($Indent + $Label + ': ' + $seg) }
}

# ---------------------------------------------------------------------------
# Formatter: meta records
# ---------------------------------------------------------------------------

function Format-LaunchRecord {
  param($State, $Rec)
  $State.launch = $Rec.launch
  Add-Line -State $State -Text '== launch (process-boundary input recorded by the wrapper)'
  Add-ValueLines -Lines $State.batch -Indent '   ' -Label 'promptSubmitted' -Value (Get-PropValue -Rec $Rec.launch -Name 'promptSubmitted') -Depth 1
  Add-ValueLines -Lines $State.batch -Indent '   ' -Label 'promptEffective' -Value (Get-PropValue -Rec $Rec.launch -Name 'promptEffective') -Depth 1
  Add-ValueLines -Lines $State.batch -Indent '   ' -Label 'cwd' -Value (Get-PropValue -Rec $Rec.launch -Name 'cwd') -Depth 1
  Add-ValueLines -Lines $State.batch -Indent '   ' -Label 'sessionId' -Value (Get-PropValue -Rec $Rec.launch -Name 'sessionId') -Depth 1
  Add-ValueLines -Lines $State.batch -Indent '   ' -Label 'constraints' -Value (Get-PropValue -Rec $Rec.launch -Name 'constraints') -Depth 1
  Add-ValueLines -Lines $State.batch -Indent '   ' -Label 'stdin' -Value (Get-PropValue -Rec $Rec.launch -Name 'stdin') -Depth 1
  Add-RecordExtras -Lines $State.batch -Rec $Rec.launch -Skip @('promptSubmitted', 'promptEffective', 'cwd', 'sessionId', 'constraints', 'stdin')

  # The Pi session id from the launch record is not the logical session name
  # (which comes from the manifest); keep it separate.
  $State.piSessionId = Format-ScalarText -Value (Get-PropValue -Rec $Rec.launch -Name 'sessionId')
  $State.cwd = [string](Get-PropValue -Rec $Rec.launch -Name 'cwd')
  $submitted = Format-ScalarText -Value (Get-PropValue -Rec $Rec.launch -Name 'promptSubmitted')
  $firstLine = ($submitted -split "`n")[0]
  if ($firstLine.Length -gt 80) { $firstLine = $firstLine.Substring(0, 80) }
  $State.promptSummary = $firstLine
  # Title and header carry the Run identity and launch metadata, both of which
  # only become known when this record arrives.
  Update-Header -State $State
  Update-WindowTitle -State $State
}

function Format-TerminalRecord {
  param($State, $Rec)
  $t = $Rec.terminal
  $State.terminalSeen = $true
  $State.terminal = $t

  $foreign = ((Get-PropValue -Rec $Rec -Name 'v') -ne 1)
  $outcome = Format-ScalarText -Value (Get-PropValue -Rec $t -Name 'outcome')
  $exitCode = Format-ScalarText -Value (Get-PropValue -Rec $t -Name 'exitCode')
  $signal = Format-ScalarText -Value (Get-PropValue -Rec $t -Name 'signal')

  if ($foreign) {
    Add-Line -State $State -Text ('? [terminal record of unknown schema version ' + (Format-ScalarText -Value (Get-PropValue -Rec $Rec -Name 'v')) + '] ' + (Format-CompactJson -Value $t))
    Add-Integrity -State $State -Reason 'foreign-terminal-version'
    return
  }

  Add-Line -State $State -Text ('== terminal outcome=' + $outcome + ' exit=' + $exitCode + ' signal=' + $signal)
  foreach ($name in @('startedAt', 'endedAt', 'finalSeq', 'stdoutBytes', 'stderrBytes', 'sawEof', 'sha256', 'piSettlement', 'captureError')) {
    if (Test-HasProp -Rec $t -Name $name) {
      Add-ValueLines -Lines $State.batch -Indent '   ' -Label $name -Value (Get-PropValue -Rec $t -Name $name) -Depth 1
    }
  }
  Add-RecordExtras -Lines $State.batch -Rec $t -Skip @(
    'outcome', 'exitCode', 'signal', 'startedAt', 'endedAt', 'finalSeq',
    'stdoutBytes', 'stderrBytes', 'sawEof', 'sha256', 'piSettlement', 'captureError'
  )

  $captureError = Get-PropValue -Rec $t -Name 'captureError'
  if ($null -ne $captureError -and -not [string]::IsNullOrEmpty([string]$captureError)) {
    Add-Integrity -State $State -Reason ('capture-error: ' + [string]$captureError)
  }
  if ((Get-PropValue -Rec $t -Name 'finalSeq') -ne ($State.priorLastSeq + 1)) {
    Add-Integrity -State $State -Reason ('final-seq-mismatch: terminal says ' + (Format-ScalarText -Value (Get-PropValue -Rec $t -Name 'finalSeq')) + ', last pre-terminal record seq ' + [string]$State.priorLastSeq)
  }
  $expectedHash = [string](Get-PropValue -Rec $t -Name 'sha256')
  $actualHash = Get-HashHex -State $State
  $State.hashComputed = $actualHash
  if ([string]::IsNullOrEmpty($actualHash)) {
    if (-not [string]::IsNullOrEmpty($State.hashError)) {
      Add-Line -State $State -Text ('-- terminal hash not verified: the viewer could not hash the transcript (' + $State.hashError + ')')
    }
  }
  elseif (-not [string]::IsNullOrEmpty($expectedHash) -and $expectedHash -ne $actualHash) {
    Add-Integrity -State $State -Reason 'terminal-hash-mismatch'
  }
}

function Format-MetaRecord {
  param($State, $Rec)
  $kind = [string](Get-PropValue -Rec $Rec -Name 'kind')
  switch ($kind) {
    'launch' { Format-LaunchRecord -State $State -Rec $Rec }
    'state' {
      $name = Format-ScalarText -Value (Get-PropValue -Rec $Rec -Name 'state')
      $detail = Get-PropValue -Rec $Rec -Name 'detail'
      $text = '== state: ' + $name
      if ($null -ne $detail -and -not [string]::IsNullOrEmpty([string]$detail)) { $text = $text + ' (' + [string]$detail + ')' }
      Add-Line -State $State -Text $text
    }
    'capture-error' {
      $err = Format-ScalarText -Value (Get-PropValue -Rec $Rec -Name 'error')
      Add-Line -State $State -Text ('!! capture error: ' + $err)
      if ([string]::IsNullOrEmpty([string]$State.captureError)) { $State.captureError = $err }
      Add-Integrity -State $State -Reason ('capture-error: ' + $err)
      Add-RecordExtras -Lines $State.batch -Rec $Rec -Skip @('v', 'seq', 'tUtc', 'tMono', 'ch', 'kind', 'error')
    }
    'terminal' { Format-TerminalRecord -State $State -Rec $Rec }
    default {
      Add-Line -State $State -Text ('? [meta kind ' + $kind + '] ' + (Format-CompactJson -Value $Rec))
    }
  }
}

# ---------------------------------------------------------------------------
# Formatter: stdout events
# ---------------------------------------------------------------------------

function Format-SessionEvent {
  param($State, $Evt)
  Add-Line -State $State -Text ('== session version=' + (Format-ScalarText -Value (Get-PropValue -Rec $Evt -Name 'version')) + ' id=' + (Format-ScalarText -Value (Get-PropValue -Rec $Evt -Name 'id')))
  Add-RecordExtras -Lines $State.batch -Rec $Evt -Skip @('type', 'version', 'id')
}

function Format-MessageStart {
  param($State, $Evt)
  $msg = Get-PropValue -Rec $Evt -Name 'message'
  $role = Format-ScalarText -Value (Get-PropValue -Rec $msg -Name 'role')
  switch ($role) {
    'user' {
      # The submitted prompt is echoed here; it is content, so it is rendered.
      Add-Line -State $State -Text '== message_start role=user'
      Add-ValueLines -Lines $State.batch -Indent '   ' -Label 'content' -Value (Get-PropValue -Rec $msg -Name 'content') -Depth 1
      Add-RecordExtras -Lines $State.batch -Rec $msg -Skip @('role', 'content')
    }
    'assistant' {
      # A marker, never a content baseline: the shared mutable partial may
      # already hold the first delta, so content is rendered from its own
      # streaming completion events instead (never duplicated here).
      Add-Line -State $State -Text ('== message_start role=assistant model=' + (Format-ScalarText -Value (Get-PropValue -Rec $msg -Name 'model')))
      Add-RecordExtras -Lines $State.batch -Rec $msg -Skip @('role', 'model', 'content')
      Add-Line -State $State -Text '-- assistant content is rendered from its completion events below, not repeated here'
    }
    'toolResult' {
      Add-Line -State $State -Text ('-- message_start role=toolResult tool=' + (Format-ScalarText -Value (Get-PropValue -Rec $msg -Name 'toolName')) + ' id=' + (Format-ScalarText -Value (Get-PropValue -Rec $msg -Name 'toolCallId')) + ' (content covered by tool_execution_end)')
    }
    default {
      Add-Line -State $State -Text ('== message_start role=' + $role)
      Add-RecordExtras -Lines $State.batch -Rec $msg -Skip @('role')
    }
  }
}

function Format-MessageEnd {
  param($State, $Evt)
  $msg = Get-PropValue -Rec $Evt -Name 'message'
  $role = Format-ScalarText -Value (Get-PropValue -Rec $msg -Name 'role')
  if ($role -eq 'assistant') {
    # Authoritative final message metadata and usage; content was already
    # rendered from its streaming completion events.
    $State.assistantMessagesRendered = $State.assistantMessagesRendered + 1
    Add-Line -State $State -Text ('== message_end role=assistant stopReason=' + (Format-ScalarText -Value (Get-PropValue -Rec $msg -Name 'stopReason')))
    foreach ($name in @('errorMessage', 'rawStopReason', 'usage', 'timestamp')) {
      if (Test-HasProp -Rec $msg -Name $name) {
        Add-ValueLines -Lines $State.batch -Indent '   ' -Label $name -Value (Get-PropValue -Rec $msg -Name $name) -Depth 1
      }
    }
    Add-RecordExtras -Lines $State.batch -Rec $msg -Skip @('role', 'stopReason', 'errorMessage', 'rawStopReason', 'usage', 'timestamp', 'content')
    Add-Line -State $State -Text ('-- assistant content of this message: ' + [string](Get-TextBlocks -Content (Get-PropValue -Rec $msg -Name 'content')).Count + ' block(s), rendered above')
    # Content blocks that never received a completion event within this message
    # are shown once, explicitly unfinished.
    Flush-UnfinishedBlocks -State $State -When 'before this message ended'
  }
  elseif ($role -eq 'user') {
    Add-Line -State $State -Text '-- message_end role=user (content shown at message_start)'
  }
  elseif ($role -eq 'toolResult') {
    Add-Line -State $State -Text '-- message_end role=toolResult (content covered by tool_execution_end)'
  }
  else {
    Add-Line -State $State -Text ('== message_end role=' + $role)
    Add-RecordExtras -Lines $State.batch -Rec $msg -Skip @('role')
  }
}

function Format-AssistantSubEvent {
  param($State, $Evt, [string]$RawLine)
  $ame = Get-PropValue -Rec $Evt -Name 'assistantMessageEvent'
  if ($null -eq $ame) {
    # usage-only update: cumulative and repeated on every delta, so it is
    # withheld; the authoritative value is shown at message_end.
    Add-Line -State $State -Text '-- message_update usage (cumulative; final usage is shown at message_end)'
    return
  }
  $type = Format-ScalarText -Value (Get-PropValue -Rec $ame -Name 'type')
  $ciRaw = Get-PropValue -Rec $ame -Name 'contentIndex'
  $ci = -1
  if ($null -ne $ciRaw) { $ci = [int]$ciRaw }
  switch ($type) {
    'thinking_start' { [void](Start-Block -State $State -Kind 'thinking' -ContentIndex $ci -ToolName '') }
    'thinking_delta' { Add-BlockFragment -State $State -Kind 'thinking' -ContentIndex $ci -Delta (Format-ScalarText -Value (Get-PropValue -Rec $ame -Name 'delta')) }
    'thinking_end' {
      $blk = Close-Block -State $State -Kind 'thinking' -ContentIndex $ci -Content (Get-PropValue -Rec $ame -Name 'content') -Source 'thinking_end'
      Add-Line -State $State -Text '== thinking (streamed by Pi at the process boundary; not hidden reasoning)'
      if (-not $blk.reconciled) {
        Add-Line -State $State -Text ('-- thinking_end carried no content; showing the withheld fragments unreconciled')
      }
      Add-TextLines -State $State -Indent '   ' -Label 'text' -Text $blk.text
    }
    'text_start' { [void](Start-Block -State $State -Kind 'text' -ContentIndex $ci -ToolName '') }
    'text_delta' { Add-BlockFragment -State $State -Kind 'text' -ContentIndex $ci -Delta (Format-ScalarText -Value (Get-PropValue -Rec $ame -Name 'delta')) }
    'text_end' {
      $blk = Close-Block -State $State -Kind 'text' -ContentIndex $ci -Content (Get-PropValue -Rec $ame -Name 'content') -Source 'text_end'
      Add-Line -State $State -Text '== assistant text'
      if (-not $blk.reconciled) {
        Add-Line -State $State -Text '-- text_end carried no content; showing the withheld fragments unreconciled'
      }
      Add-TextLines -State $State -Indent '   ' -Label 'text' -Text $blk.text
    }
    'toolcall_start' {
      [void](Start-Block -State $State -Kind 'toolcall' -ContentIndex $ci -ToolName (Format-ScalarText -Value (Get-PropValue -Rec $ame -Name 'toolName')))
    }
    'toolcall_delta' { Add-BlockFragment -State $State -Kind 'toolcall' -ContentIndex $ci -Delta (Format-ScalarText -Value (Get-PropValue -Rec $ame -Name 'delta')) }
    'toolcall_end' {
      $key = 'toolcall:' + [string]$ci
      $name = ''
      $fragments = ''
      if ($State.openBlocks.ContainsKey($key)) {
        $name = [string]$State.openBlocks[$key].toolName
        $fragments = $State.openBlocks[$key].buffer.ToString()
        $State.openBlocks.Remove($key)
      }
      $call = Get-PropValue -Rec $ame -Name 'toolCall'
      if ($null -ne $call) {
        $id = Format-ScalarText -Value (Get-PropValue -Rec $call -Name 'id')
        $callName = Format-ScalarText -Value (Get-PropValue -Rec $call -Name 'name')
        Add-Line -State $State -Text ('== tool call ' + $callName + ' id=' + $id)
        Add-ValueLines -Lines $State.batch -Indent '   ' -Label 'arguments' -Value (Get-PropValue -Rec $call -Name 'arguments') -Depth 1
        Add-RecordExtras -Lines $State.batch -Rec $call -Skip @('id', 'name', 'arguments')
      }
      else {
        Add-Line -State $State -Text ('== tool call ' + $name + ' (toolcall_end carried no toolCall object)')
        if ($fragments.Length -gt 0) {
          Add-Line -State $State -Text '-- unreconciled toolcall fragments:'
          foreach ($seg in $fragments.Split("`n")) { Add-Line -State $State -Text ('   ' + $seg) }
        }
      }
    }
    default {
      # Unknown assistant sub-event: visible, lossless, never silently dropped.
      Add-Line -State $State -Text ('? [assistant event ' + $type + '] ' + $RawLine)
    }
  }
}

function Format-ToolStart {
  param($State, $Evt)
  # args are the same tool-call payload already rendered at toolcall_end.
  Add-Line -State $State -Text ('== tool_execution_start ' + (Format-ScalarText -Value (Get-PropValue -Rec $Evt -Name 'toolName')) + ' id=' + (Format-ScalarText -Value (Get-PropValue -Rec $Evt -Name 'toolCallId')) + ' (args shown at toolcall_end)')
}

function Format-ToolUpdate {
  param($State, $Evt)
  # Withheld while healthy; shown after tool_execution_end only for the parts
  # the final result does not cover. Coverage is decided on the whole
  # partialResult payload, not just its text: an update whose content carries no
  # text blocks (images, details-only) is still evidence and must not be
  # silently dropped as "covered".
  $id = Format-ScalarText -Value (Get-PropValue -Rec $Evt -Name 'toolCallId')
  $partial = Get-PropValue -Rec $Evt -Name 'partialResult'
  if (-not $State.toolUpdates.ContainsKey($id)) {
    $State.toolUpdates[$id] = [pscustomobject]@{
      parts = (New-Object 'System.Collections.Generic.List[object]')
      shown = $false
    }
  }
  [void]$State.toolUpdates[$id].parts.Add([pscustomobject]@{
    signature = (Format-CompactJson -Value $partial)
    text      = (Join-TextBlocks -Content (Get-PropValue -Rec $partial -Name 'content'))
    payload   = $partial
  })
}

function Format-ToolEnd {
  param($State, $Evt)
  $id = Format-ScalarText -Value (Get-PropValue -Rec $Evt -Name 'toolCallId')
  $name = Format-ScalarText -Value (Get-PropValue -Rec $Evt -Name 'toolName')
  $isError = Format-ScalarText -Value (Get-PropValue -Rec $Evt -Name 'isError')
  Add-Line -State $State -Text ('== tool_execution_end ' + $name + ' id=' + $id + ' isError=' + $isError)
  Add-ValueLines -Lines $State.batch -Indent '   ' -Label 'result' -Value (Get-PropValue -Rec $Evt -Name 'result') -Depth 1
  Add-RecordExtras -Lines $State.batch -Rec $Evt -Skip @('type', 'toolCallId', 'toolName', 'result', 'isError', 'args', 'partialResult')

  $finalSignature = Format-CompactJson -Value (Get-PropValue -Rec (Get-PropValue -Rec $Evt -Name 'result') -Name 'content')
  $finalText = Join-TextBlocks -Content (Get-PropValue -Rec (Get-PropValue -Rec $Evt -Name 'result') -Name 'content')
  $State.toolEnded[$id] = $true
  Show-UncoveredToolUpdates -State $State -ToolCallId $id -FinalSignature $finalSignature -FinalText $finalText -Label 'tool_execution_end'
}

function Show-UncoveredToolUpdates {
  param($State, [string]$ToolCallId, [string]$FinalSignature, [string]$FinalText, [string]$Label)
  if (-not $State.toolUpdates.ContainsKey($ToolCallId)) { return }
  $entry = $State.toolUpdates[$ToolCallId]
  if ($entry.shown) { return }
  $entry.shown = $true
  $covered = 0
  $uncovered = New-Object 'System.Collections.Generic.List[object]'
  foreach ($part in $entry.parts) {
    $text = [string]$part.text
    $sig = [string]$part.signature
    # Covered when the final result already carries this content: either its text
    # (a growing cumulative partial) or its whole payload (identical JSON). An
    # update with nothing to show at all is covered by definition; one whose
    # payload is non-text (images, details) is only covered if the JSON matches.
    $textCovered = (-not [string]::IsNullOrEmpty($text)) -and $FinalText.Contains($text)
    $sigCovered = (-not [string]::IsNullOrEmpty($sig)) -and $FinalSignature.Contains($sig)
    $nothingToShow = [string]::IsNullOrEmpty($sig) -and [string]::IsNullOrEmpty($text)
    if ($textCovered -or $sigCovered -or $nothingToShow) { $covered++ }
    else { [void]$uncovered.Add($part) }
  }
  if ($covered -gt 0) {
    Add-Line -State $State -Text ('-- ' + [string]$covered + ' tool_execution_update record(s) withheld (covered by the final ' + $Label + ' result)')
  }
  for ($i = 0; $i -lt $uncovered.Count; $i++) {
    $part = $uncovered[$i]
    Add-Line -State $State -Text ('-- unmerged intermediate output [id ' + $ToolCallId + ' ' + [string]($i + 1) + '/' + [string]$uncovered.Count + '] (not present in the final result)')
    if (-not [string]::IsNullOrEmpty([string]$part.text)) {
      Add-TextLines -State $State -Indent '   ' -Label 'content' -Text ([string]$part.text)
    }
    else {
      # No text blocks to show: render the whole payload instead of dropping it.
      Add-ValueLines -Lines $State.batch -Indent '   ' -Label 'partialResult' -Value $part.payload -Depth 1
    }
  }
}

function Format-TurnEnd {
  param($State, $Evt)
  $msg = Get-PropValue -Rec $Evt -Name 'message'
  Add-Line -State $State -Text ('== turn_end stopReason=' + (Format-ScalarText -Value (Get-PropValue -Rec $msg -Name 'stopReason')))
  $tr = Get-PropValue -Rec $Evt -Name 'toolResults'
  $trCount = 0
  if ($null -ne $tr) { $trCount = @($tr).Count }
  Add-Line -State $State -Text ('-- turn_end message and ' + [string]$trCount + ' toolResult(s) covered by the rendered assistant and tool events')
  if (Test-HasProp -Rec $msg -Name 'usage') {
    Add-ValueLines -Lines $State.batch -Indent '   ' -Label 'usage' -Value (Get-PropValue -Rec $msg -Name 'usage') -Depth 1
  }
}

function Format-AgentEnd {
  param($State, $Evt)
  $msgs = Get-PropValue -Rec $Evt -Name 'messages'
  $count = 0
  if ($null -ne $msgs) { $count = @($msgs).Count }
  Add-Line -State $State -Text ('== agent_end willRetry=' + (Format-ScalarText -Value (Get-PropValue -Rec $Evt -Name 'willRetry')) + ' messages=' + [string]$count)
  Add-RecordExtras -Lines $State.batch -Rec $Evt -Skip @('type', 'messages', 'willRetry')

  # Render only the assistant messages this stream did not already account for:
  # agent_end.messages replays already-rendered turns, so a healthy Run repeats
  # them here and nothing is shown again. If fewer assistant messages were
  # rendered than agent_end reports, the missing ones exist ONLY here and are
  # shown as an explicit recovery - never silently lost.
  $assistantTotal = 0
  foreach ($m in @($msgs)) {
    if ((Format-ScalarText -Value (Get-PropValue -Rec $m -Name 'role')) -eq 'assistant') { $assistantTotal++ }
  }
  $missing = $assistantTotal - $State.assistantMessagesRendered
  if ($missing -le 0) {
    Add-Line -State $State -Text ('-- agent_end.messages replays the ' + [string]$count + ' already-rendered message(s); not repeated here')
    return
  }
  Add-Line -State $State -Text ('-- ' + [string]$missing + ' assistant message(s) appear only in agent_end.messages; showing them as a recovery')
  $idx = 0
  $remaining = $missing
  foreach ($m in @($msgs)) {
    $role = Format-ScalarText -Value (Get-PropValue -Rec $m -Name 'role')
    if ($role -ne 'assistant') { $idx++; continue }
    if ($remaining -le 0) { $idx++; continue }
    $text = Join-TextBlocks -Content (Get-PropValue -Rec $m -Name 'content')
    if (-not [string]::IsNullOrEmpty($text)) {
      Add-Line -State $State -Text ('-- recovered assistant message from agent_end.messages[' + [string]$idx + ']')
      Add-TextLines -State $State -Indent '   ' -Label 'text' -Text $text
      $remaining--
    }
    $idx++
  }
}

function Format-GenericEvent {
  param($State, $Evt, [string]$RawLine)
  Add-Line -State $State -Text ('== ' + (Format-ScalarText -Value (Get-PropValue -Rec $Evt -Name 'type')))
  Add-RecordExtras -Lines $State.batch -Rec $Evt -Skip @('type')
}

function Format-StdoutLine {
  param($State, $Line, [string]$RawLine)
  if ([string]::IsNullOrEmpty($Line)) {
    Add-Line -State $State -Text '-- blank stdout line'
    return
  }
  $evt = $null
  try { $evt = ConvertFrom-Json -InputObject $Line }
  catch { $evt = $null }
  $type = $null
  if ($null -ne $evt) { $type = Get-PropValue -Rec $evt -Name 'type' }
  if ($null -eq $evt -or $null -eq $type) {
    $State.lastType = 'unparsed'
    Add-Line -State $State -Text ('? [unparsed stdout] ' + $Line)
    return
  }
  $type = [string]$type
  $State.lastType = $type

  if ($script:GenericEventTypes -contains $type) {
    Format-GenericEvent -State $State -Evt $evt -RawLine $RawLine
    return
  }
  if ($script:LifecycleTypes -notcontains $type) {
    # Unknown type: raw fallback so future Pi events degrade visibly instead of
    # disappearing. Not an integrity failure - nothing is missing.
    Add-Line -State $State -Text ('? [event ' + $type + '] ' + $Line)
    return
  }

  switch ($type) {
    'session' { Format-SessionEvent -State $State -Evt $evt }
    'agent_start' { Add-Line -State $State -Text '== agent_start' }
    'agent_settled' { Add-Line -State $State -Text '== agent_settled' }
    'agent_end' { Format-AgentEnd -State $State -Evt $evt }
    'turn_start' { Add-Line -State $State -Text '== turn_start' }
    'turn_end' { Format-TurnEnd -State $State -Evt $evt }
    'message_start' { Format-MessageStart -State $State -Evt $evt }
    'message_end' { Format-MessageEnd -State $State -Evt $evt }
    'message_update' { Format-AssistantSubEvent -State $State -Evt $evt -RawLine $RawLine }
    'tool_execution_start' { Format-ToolStart -State $State -Evt $evt }
    'tool_execution_update' { Format-ToolUpdate -State $State -Evt $evt }
    'tool_execution_end' { Format-ToolEnd -State $State -Evt $evt }
    default { Format-GenericEvent -State $State -Evt $evt -RawLine $RawLine }
  }
}

function Format-StderrLine {
  param($State, $Line, [string]$Channel)
  $State.lastType = $Channel
  if ($Channel -eq 'stdin') {
    Add-Line -State $State -Text ('> stdin: ' + $Line)
  }
  else {
    Add-Line -State $State -Text ('! stderr: ' + $Line)
  }
}

# ---------------------------------------------------------------------------
# Byte-group reassembly and line splitting
# ---------------------------------------------------------------------------

# Raw payloads are chunked at <= 64 KiB with groupId/part/final metadata; a
# group is reassembled completely before anything is decoded or displayed.
function Add-ByteGroupPart {
  param($State, $Rec)
  $bytes = Get-PropValue -Rec $Rec -Name 'bytes'
  if ($null -eq $bytes) {
    Add-Line -State $State -Text ('? [byte record without payload] ' + (Format-CompactJson -Value $Rec))
    return
  }
  $groupId = Format-ScalarText -Value (Get-PropValue -Rec $bytes -Name 'groupId')
  $part = [int](Get-PropValue -Rec $bytes -Name 'part')
  $isFinal = [bool](Get-PropValue -Rec $bytes -Name 'final')
  $payload = $null
  try { $payload = [System.Convert]::FromBase64String([string](Get-PropValue -Rec $bytes -Name 'b64')) }
  catch {
    Add-Integrity -State $State -Reason ('undecodable payload in group ' + $groupId)
    Add-Line -State $State -Text ('? [undecodable byte payload group ' + $groupId + '] ' + (Format-CompactJson -Value $bytes))
    return
  }
  if (-not $State.groups.ContainsKey($groupId)) {
    $State.groups[$groupId] = @{ expected = $part; parts = (New-Object 'System.Collections.Generic.List[byte[]]'); seen = 0 }
  }
  $group = $State.groups[$groupId]
  $group.seen = $group.seen + 1
  if ($part -ne $group.expected) {
    Add-Integrity -State $State -Reason ('byte group ' + $groupId + ' out-of-order: expected part ' + [string]$group.expected + ', got ' + [string]$part)
  }
  $group.expected = $part + 1
  [void]$group.parts.Add($payload)
  if (-not $isFinal) { return }

  $total = 0
  foreach ($p in $group.parts) { $total = $total + $p.Length }
  $assembled = New-Object byte[] $total
  $off = 0
  foreach ($p in $group.parts) {
    [System.Array]::Copy($p, 0, $assembled, $off, $p.Length)
    $off = $off + $p.Length
  }
  $State.groups.Remove($groupId)
  $ch = [string](Get-PropValue -Rec $Rec -Name 'ch')
  Add-ChannelBytes -State $State -Ch $ch -Bytes $assembled
}

function Add-ChannelBytes {
  param($State, [string]$Ch, [byte[]]$Bytes)
  if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return }
  if (-not $State.channels.ContainsKey($Ch)) {
    $State.channels[$Ch] = @{ buf = (New-Object byte[] 0) }
  }
  $buf = $State.channels[$Ch].buf
  if ($buf.Length -eq 0) {
    $State.channels[$Ch].buf = $Bytes
  }
  else {
    $merged = New-Object byte[] ($buf.Length + $Bytes.Length)
    [System.Array]::Copy($buf, 0, $merged, 0, $buf.Length)
    [System.Array]::Copy($Bytes, 0, $merged, $buf.Length, $Bytes.Length)
    $State.channels[$Ch].buf = $merged
  }
  Expand-ChannelLines -State $State -Ch $Ch
}

# LF (0x0A) can never appear inside a UTF-8 multi-byte sequence, so a native
# byte search for LF is a safe splitter. Bytes that are not valid UTF-8 (a
# capture artifact) are displayed as a lossless hex escape instead of U+FFFD.
function Expand-ChannelLines {
  param($State, [string]$Ch)
  $combined = $State.channels[$Ch].buf
  if ($combined.Length -eq 0) { return }
  $start = 0
  $consumed = 0
  while ($true) {
    $i = [System.Array]::IndexOf($combined, [byte]10, $start)
    if ($i -lt 0) { break }
    $lineLen = $i - $start
    $lineBytes = New-Object byte[] $lineLen
    if ($lineLen -gt 0) { [System.Array]::Copy($combined, $start, $lineBytes, 0, $lineLen) }
    $text = Convert-LineBytes -Bytes $lineBytes
    if ($Ch -eq 'stdout') { Format-StdoutLine -State $State -Line $text -RawLine $text }
    else { Format-StderrLine -State $State -Line $text -Channel $Ch }
    $start = $i + 1
    $consumed = $start
  }
  if ($consumed -gt 0) {
    $rest = $combined.Length - $consumed
    if ($rest -le 0) {
      $State.channels[$Ch].buf = (New-Object byte[] 0)
    }
    else {
      $tail = New-Object byte[] $rest
      [System.Array]::Copy($combined, $consumed, $tail, 0, $rest)
      $State.channels[$Ch].buf = $tail
    }
  }
}

function Convert-LineBytes {
  param([byte[]]$Bytes)
  if ($Bytes.Length -eq 0) { return '' }
  try {
    $text = $script:utf8Strict.GetString($Bytes)
  }
  catch {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<non-utf8 bytes>')
    foreach ($b in $Bytes) { [void]$sb.Append(' \x' + $b.ToString('X2')) }
    return $sb.ToString()
  }
  if ($text.EndsWith("`r")) { $text = $text.Substring(0, $text.Length - 1) }
  return $text
}

# ---------------------------------------------------------------------------
# Record dispatch
# ---------------------------------------------------------------------------

function Process-Record {
  param($State, $Rec, [string]$Line)
  $State.recordCount = $State.recordCount + 1
  if ($null -eq $Rec) {
    $State.lastType = 'unparsed'
    Add-Line -State $State -Text ('? [unparsed journal line] ' + $Line)
    return
  }
  $version = Get-PropValue -Rec $Rec -Name 'v'
  $seq = Get-PropValue -Rec $Rec -Name 'seq'
  if ($null -eq $version -or $null -eq $seq) {
    Add-Integrity -State $State -Reason 'record-envelope-invalid'
    Add-Line -State $State -Text ('? [journal record without schema envelope] ' + $Line)
    return
  }
  if ([int]$version -ne 1) {
    Add-Integrity -State $State -Reason ('foreign-record-version: v' + (Format-ScalarText -Value $version))
    Add-Line -State $State -Text ('? [record of unknown schema version ' + (Format-ScalarText -Value $version) + '] ' + $Line)
    return
  }
  if ($State.terminalSeen) {
    $State.lineAfterTerminal = $true
    Add-Integrity -State $State -Reason 'records-after-terminal'
    return
  }
  $seqInt = [int]$seq
  if ($seqInt -ne $State.seqExpected) {
    if ($seqInt -gt $State.seqExpected) {
      Add-Integrity -State $State -Reason ('sequence-gap: expected ' + [string]$State.seqExpected + ', got ' + [string]$seqInt)
    }
    else {
      Add-Integrity -State $State -Reason ('sequence-out-of-order: expected ' + [string]$State.seqExpected + ', got ' + [string]$seqInt)
    }
  }
  $State.priorLastSeq = $State.lastSeq
  $State.seqExpected = $seqInt + 1
  $State.lastSeq = $seqInt

  $ch = [string](Get-PropValue -Rec $Rec -Name 'ch')
  $kind = [string](Get-PropValue -Rec $Rec -Name 'kind')
  if ($ch -eq 'meta') {
    Format-MetaRecord -State $State -Rec $Rec
    return
  }
  if (($ch -eq 'stdout' -or $ch -eq 'stderr' -or $ch -eq 'stdin') -and $kind -eq 'bytes') {
    Add-ByteGroupPart -State $State -Rec $Rec
    return
  }
  Add-Line -State $State -Text ('? [channel ' + $ch + ' kind ' + $kind + '] ' + $Line)
}

# Every complete file line read before the terminal record is hashed exactly as
# it appears on disk, so the terminal hash can be verified byte-for-byte.
function Read-Available {
  param($State, [DateTime]$DeadlineUtc)
  $fs = $State.fs
  if ($null -eq $fs) { return 0 }
  $fileLen = 0
  try { $fileLen = $fs.Length }
  catch {
    Add-Integrity -State $State -Reason 'transcript unreadable'
    return 0
  }
  $available = $fileLen - $State.readOffset
  if ($available -le 0) { return 0 }
  $toRead = [long][Math]::Min([long]$script:MaxReadBytesPerTick, $available)
  $bytes = New-Object byte[] ([int]$toRead)
  [void]$fs.Seek($State.readOffset, [System.IO.SeekOrigin]::Begin)
  $readTotal = 0
  while ($readTotal -lt $toRead) {
    $n = $fs.Read($bytes, $readTotal, [int]($toRead - $readTotal))
    if ($n -le 0) { break }
    $readTotal = $readTotal + $n
  }
  if ($readTotal -le 0) { return 0 }
  $State.readOffset = $State.readOffset + $readTotal

  $start = 0
  $processed = 0
  while ($true) {
    if (($processed % 64) -eq 0 -and [DateTime]::UtcNow -ge $DeadlineUtc) { break }
    $i = [System.Array]::IndexOf($bytes, [byte]10, $start)
    if ($i -lt 0 -or $i -ge $readTotal) { break }
    $rawLen = ($i + 1) - $start
    $lineLen = $i - $start
    $lineBytes = New-Object byte[] $lineLen
    if ($lineLen -gt 0) { [System.Array]::Copy($bytes, $start, $lineBytes, 0, $lineLen) }
    $text = Convert-LineBytes -Bytes $lineBytes
    $rec = $null
    try { $rec = ConvertFrom-Json -InputObject $text }
    catch { $rec = $null }
    # Hash exactly what replay() hashes: every file line before the terminal
    # record, unparseable lines included.
    if (-not $State.terminalSeen) {
      $isTerminal = ($null -ne $rec -and (Get-PropValue -Rec $rec -Name 'kind') -eq 'terminal' -and (Get-PropValue -Rec $rec -Name 'ch') -eq 'meta' -and (Get-PropValue -Rec $rec -Name 'v') -eq 1)
      if (-not $isTerminal) {
        Add-HashBytes -State $State -Bytes $bytes -Offset $start -Count $rawLen
      }
    }
    if ($State.readOffset - $readTotal + $start -lt $State.startSize) { $State.replayedCount = $State.replayedCount + 1 }
    else { $State.tailedCount = $State.tailedCount + 1 }
    Process-Record -State $State -Rec $rec -Line $text
    $start = $i + 1
    $processed++
  }
  if ($start -gt 0) {
    # Bytes past the last complete line stay in the file for the next tick: a
    # trailing unterminated line waits for more bytes.
    $State.readOffset = $State.readOffset - ($readTotal - $start)
  }
  return $processed
}

function Get-PendingPartialBytes {
  param($State)
  $rest = New-Object 'System.Collections.Generic.List[object]'
  foreach ($ch in @('stdout', 'stderr', 'stdin')) {
    $buf = $State.channels[$ch].buf
    if ($null -ne $buf -and $buf.Length -gt 0) {
      [void]$rest.Add([pscustomobject]@{ channel = $ch; groupId = ''; bytes = $buf; parts = 0 })
    }
  }
  foreach ($gid in @($State.groups.Keys)) {
    $group = $State.groups[$gid]
    [void]$rest.Add([pscustomobject]@{ channel = ''; groupId = $gid; bytes = (New-Object byte[] 0); parts = $group.seen })
  }
  return , $rest
}

# ---------------------------------------------------------------------------
# Terminal classification
# ---------------------------------------------------------------------------

function Complete-Run {
  param($State)
  Flush-UnfinishedBlocks -State $State -When 'at the terminal record'
  Flush-PartialTails -State $State
  foreach ($id in @($State.toolUpdates.Keys)) {
    if (-not $State.toolEnded.ContainsKey($id)) {
      Add-Line -State $State -Text ('-- no tool_execution_end was captured for id ' + $id + '; intermediate output follows')
      Show-UncoveredToolUpdates -State $State -ToolCallId $id -FinalSignature '' -FinalText '' -Label 'tool_execution_end'
    }
  }
  Update-Token -State $State
  $State.soundDecision = Get-SoundDecision -State $State
  # One attempt per Run: a prior durable alertAttemptedAt suppresses this one.
  # Recorded before the attempt so the decision is observable in -Replay.
  $State.soundWouldAttempt = ($State.soundDecision -ne 'none') -and (-not $State.soundPlayed)
  Update-Header -State $State
  Update-StatusBar -State $State
  Update-WindowTitle -State $State
}

# A trailing unterminated line is kept and labelled: on a terminal bundle it is
# truncated evidence. Two shapes exist: an unterminated line inside the byte
# stream (channel buffer) and an unterminated file line (a record cut short).
function Flush-PartialTails {
  param($State)
  foreach ($p in @(Get-PendingPartialBytes -State $State)) {
    if ($p.bytes.Length -gt 0) {
      Add-Integrity -State $State -Reason ('trailing-partial-line in ' + $p.channel)
      Add-Line -State $State -Text ('? [partial unterminated ' + $p.channel + ' line] ' + (Convert-LineBytes -Bytes $p.bytes))
      $State.channels[$p.channel].buf = (New-Object byte[] 0)
    }
    elseif (-not [string]::IsNullOrEmpty([string]$p.groupId)) {
      Add-Integrity -State $State -Reason ('incomplete byte group ' + [string]$p.groupId)
      Add-Line -State $State -Text ('? [incomplete byte group ' + [string]$p.groupId + ': ' + [string]$p.parts + ' part(s), no final part]')
    }
  }
  $State.groups = @{}
  $journalTail = Get-UnterminatedJournalBytes -State $State
  if ($null -ne $journalTail -and $journalTail.Length -gt 0) {
    Add-Integrity -State $State -Reason 'trailing-partial-line in journal'
    Add-Line -State $State -Text ('? [partial unterminated journal line] ' + (Convert-LineBytes -Bytes $journalTail))
    # Consumed: it is on disk as evidence and has now been displayed once.
    $State.readOffset = $State.readOffset + $journalTail.Length
  }
}

# Bytes past the last complete line: a record the writer never finished.
function Get-UnterminatedJournalBytes {
  param($State)
  if ($null -eq $State.fs) { return $null }
  try {
    $len = $State.fs.Length
    if ($len -le $State.readOffset) { return $null }
    $count = [int]($len - $State.readOffset)
    $buf = New-Object byte[] $count
    [void]$State.fs.Seek($State.readOffset, [System.IO.SeekOrigin]::Begin)
    $read = 0
    while ($read -lt $count) {
      $n = $State.fs.Read($buf, $read, $count - $read)
      if ($n -le 0) { break }
      $read = $read + $n
    }
    if ($read -le 0) { return $null }
    if ($read -eq $count) { return $buf }
    $trimmed = New-Object byte[] $read
    [System.Array]::Copy($buf, 0, $trimmed, 0, $read)
    return $trimmed
  }
  catch { return $null }
}

function Update-Token {
  param($State)
  if (-not $State.terminalSeen) {
    if ($State.integrity.Count -gt 0) {
      $State.token = 'INCOMPLETE'
      $State.tokenDetail = 'capture is incomplete while the Run is still running'
    }
    else {
      $State.token = 'RUNNING'
      $State.tokenDetail = ''
    }
    return
  }
  $t = $State.terminal
  $outcome = Format-ScalarText -Value (Get-PropValue -Rec $t -Name 'outcome')
  if ($outcome -eq 'null' -or [string]::IsNullOrEmpty($outcome)) { $outcome = 'unknown' }
  $token = switch ($outcome) {
    'succeeded' { 'SUCCEEDED' }
    'failed' { 'FAILED' }
    'protocol-error' { 'PROTOCOL ERROR' }
    'incomplete' { 'INCOMPLETE' }
    default { 'UNKNOWN (' + $outcome + ')' }
  }
  if ($State.integrity.Count -gt 0) {
    # Capture failure never stops a Run, but the window must mark the
    # transcript incomplete.
    $State.token = 'INCOMPLETE'
    $State.tokenDetail = 'terminal outcome ' + $token + ' but the transcript is not trustworthy: ' + [string]::Join('; ', $State.integrity.ToArray())
  }
  else {
    $State.token = $token
    $State.tokenDetail = 'outcome=' + $outcome + ' exit=' + (Format-ScalarText -Value (Get-PropValue -Rec $t -Name 'exitCode')) + ' signal=' + (Format-ScalarText -Value (Get-PropValue -Rec $t -Name 'signal'))
  }
}

function Get-SoundDecision {
  param($State)
  if (-not $State.terminalSeen) { return 'none' }
  if ($State.integrity.Count -gt 0) { return 'warning' }
  $outcome = Format-ScalarText -Value (Get-PropValue -Rec $State.terminal -Name 'outcome')
  if ($outcome -eq 'succeeded') { return 'success' }
  return 'warning'
}

# ---------------------------------------------------------------------------
# viewer-state.json / viewer-request.json (non-evidentiary)
# ---------------------------------------------------------------------------

function Write-ViewerState {
  param($State, [string]$Lifecycle, [string]$Error)
  if ($script:ReplayMode) { return }
  $path = Join-Path $State.bundleDir 'viewer-state.json'
  $existing = Read-ViewerState -State $State
  $alert = $null
  if ($null -ne $existing -and $null -ne (Get-PropValue -Rec $existing -Name 'alertAttemptedAt')) {
    $alert = Get-PropValue -Rec $existing -Name 'alertAttemptedAt'
  }
  if ($State.soundAttempted -and $alert -eq $null) { $alert = $script:viewerStartedAt }
  $record = [ordered]@{
    runId             = $State.runId
    instanceId        = $script:instanceId
    pid               = $PID
    startedAt         = $script:viewerStartedAt
    updatedAt         = Get-NowMs
    state             = $Lifecycle
    outcome           = $(if ($State.terminalSeen) { [string](Get-PropValue -Rec $State.terminal -Name 'outcome') } else { $null })
    token             = $State.token
    captureIncomplete = ($State.integrity.Count -gt 0)
    alertAttemptedAt  = $alert
    sourceCleaned     = [bool]$State.sourceCleaned
    lastError         = $Error
  }
  $tmp = $path + '.tmp'
  try {
    [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject ([pscustomobject]$record) -Compress -Depth 6), $script:utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $path -Force
  }
  catch {
    try { [System.IO.File]::Delete($tmp) } catch { }
  }
}

function Read-ViewerState {
  param($State)
  $path = Join-Path $State.bundleDir 'viewer-state.json'
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path, $script:utf8))) }
  catch { return $null }
}

function Test-FocusRequested {
  param($State)
  $path = Join-Path $State.bundleDir 'viewer-request.json'
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  try { [System.IO.File]::Delete($path) } catch { }
  return $true
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

function Render-Batch {
  param($State)
  if ($State.batch.Count -eq 0) { return }
  $text = [string]::Join("`n", $State.batch.ToArray()) + "`n"
  $State.batch.Clear()
  [void]$State.text.Append($text)
  $rtb = $State.rtb
  if ($null -eq $rtb) { return }
  try {
    $atBottom = $true
    if ($rtb.TextLength -gt 0) { $atBottom = ($rtb.SelectionStart -ge ($rtb.TextLength - 1)) }
    Add-RichTextWithFallback -Rtb $rtb -Text $text
    if ($atBottom) {
      $rtb.SelectionStart = $rtb.TextLength
      $rtb.SelectionLength = 0
      $rtb.ScrollToCaret()
    }
  }
  catch {
    $State.displayError = $_.Exception.Message
    [void]$script:viewerErrors.Add('display: ' + $State.displayError)
    try {
      Add-RichTextWithFallback -Rtb $rtb -Text ('?? display error: ' + $State.displayError + "`n")
    }
    catch { }
  }
}

function Update-WindowTitle {
  param($State)
  $parts = New-Object 'System.Collections.Generic.List[string]'
  [void]$parts.Add('Pi')
  if (-not [string]::IsNullOrEmpty($State.session)) { [void]$parts.Add($State.session) }
  if (-not [string]::IsNullOrEmpty($State.promptSummary)) { [void]$parts.Add($State.promptSummary) }
  if (-not [string]::IsNullOrEmpty($State.runId)) { [void]$parts.Add($State.runId) }
  # Em dash and ellipsis are built from code points so this source stays pure
  # ASCII: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, which would
  # mangle any non-ASCII byte and can swallow the closing quote of a literal.
  $emDash = [string][char]0x2014
  $title = '[' + $State.token + '] ' + [string]::Join(' ' + $emDash + ' ', $parts.ToArray())
  if ($null -ne $State.form) { $State.form.Text = $title }
}

function Get-HeaderLines {
  param($State)
  $launch = $State.launch
  $constraints = 'none'
  $sessionId = '(none)'
  $stdin = '(unknown)'
  $submitted = ''
  if ($null -ne $launch) {
    $constraints = Format-ConstraintsText -Constraints (Get-PropValue -Rec $launch -Name 'constraints')
    $sessionId = Format-ScalarText -Value (Get-PropValue -Rec $launch -Name 'sessionId')
    $stdin = Format-ScalarText -Value (Get-PropValue -Rec $launch -Name 'stdin')
    $submitted = Format-ScalarText -Value (Get-PropValue -Rec $launch -Name 'promptSubmitted')
    $submitted = ($submitted -split "`n")[0]
    if ($submitted.Length -gt 120) { $submitted = $submitted.Substring(0, 120) + [string][char]0x2026 }
  }
  $lines = New-Object 'System.Collections.Generic.List[string]'
  [void]$lines.Add('Run      ' + $State.runId)
  [void]$lines.Add('Session  ' + $State.session + '    cwd ' + $State.cwd + '    started ' + $State.startedAtUtc)
  [void]$lines.Add('Launch   sessionId=' + $sessionId + '  stdin=' + $stdin + '  constraints=' + $constraints)
  [void]$lines.Add('Prompt   ' + $submitted)
  return $lines.ToArray()
}

function Update-Header {
  param($State)
  if ($null -eq $State.headerLabel) { return }
  $State.headerLabel.Text = [string]::Join([Environment]::NewLine, (Get-HeaderLines -State $State))
}

function New-StatusIcon {
  param([System.Drawing.Color]$Color)
  $bmp = New-Object System.Drawing.Bitmap(16, 16)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $brush = New-Object System.Drawing.SolidBrush($Color)
  $g.FillEllipse($brush, 3, 3, 10, 10)
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, 0, 0, 0))
  $g.DrawEllipse($pen, 3, 3, 10, 10)
  $pen.Dispose()
  $brush.Dispose()
  $g.Dispose()
  return $bmp
}

function Update-StatusBar {
  param($State)
  $color = [System.Drawing.Color]::FromArgb(0, 90, 158)
  switch ($State.token) {
    'RUNNING' { $color = [System.Drawing.Color]::FromArgb(0, 90, 158) }
    'SUCCEEDED' { $color = [System.Drawing.Color]::FromArgb(0, 120, 60) }
    'FAILED' { $color = [System.Drawing.Color]::FromArgb(176, 0, 32) }
    'PROTOCOL ERROR' { $color = [System.Drawing.Color]::FromArgb(176, 0, 32) }
    'INCOMPLETE' { $color = [System.Drawing.Color]::FromArgb(176, 96, 0) }
    default { $color = [System.Drawing.Color]::FromArgb(96, 96, 96) }
  }
  if ($null -ne $State.statusLabel) {
    $State.statusLabel.Text = $State.token
    $State.statusLabel.ForeColor = $color
    if ($null -eq $script:boldFont) {
      $script:boldFont = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    }
    $State.statusLabel.Font = $script:boldFont
  }
  if ($null -ne $State.statusIcon) {
    $old = $State.statusIcon.Image
    $State.statusIcon.Image = New-StatusIcon -Color $color
    if ($null -ne $old) { $old.Dispose() }
  }
  if ($null -ne $State.statusDetail) {
    $source = 'live'
    if ($State.sourceCleaned) { $source = 'cleaned' }
    elseif ($State.sourceReleased) { $source = 'released' }
    $detail = 'seq ' + [string]$State.lastSeq + ' | ' + [string]$State.recordCount + ' record(s) | source ' + $source
    if (-not [string]::IsNullOrEmpty($State.tokenDetail)) { $detail = $detail + ' | ' + $State.tokenDetail }
    if ($null -ne $State.displayError) { $detail = $detail + ' | display error: ' + $State.displayError }
    $State.statusDetail.Text = $detail
  }
}

# ---------------------------------------------------------------------------
# Sound + completion notification (window-local, one attempt per Run)
# ---------------------------------------------------------------------------

function Invoke-CompletionSound {
  param($State)
  if (-not $State.terminalSeen -or $State.soundPlayed) { return }
  $State.soundPlayed = $true
  if ($script:NoSoundMode -or $script:ReplayMode) { return }
  # One attempt only, tracked outside the evidentiary transcript. No durable or
  # exactly-once delivery is claimed.
  try {
    if ($State.soundDecision -eq 'success') { [System.Media.SystemSounds]::Asterisk.Play() }
    else { [System.Media.SystemSounds]::Hand.Play() }
  }
  catch {
    [void]$script:viewerErrors.Add('sound: ' + $_.Exception.Message)
  }
  $State.soundAttempted = $true
  Write-ViewerState -State $State -Lifecycle 'ready'
}

# ---------------------------------------------------------------------------
# Tick
# ---------------------------------------------------------------------------

function Invoke-Tick {
  param($State, [DateTime]$DeadlineUtc)
  if ($null -eq $State.fs -and -not $State.sourceReleased) {
    # The bundle may not exist yet (the wrapper creates it first, but a very
    # early viewer start can still lose the race). Keep waiting.
    if (Test-Path -LiteralPath $State.transcriptPath) {
      try {
        $State.fs = New-Object System.IO.FileStream($State.transcriptPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $State.startSize = [long]$State.fs.Length
      }
      catch { }
    }
    return
  }
  if (-not $State.sourceReleased) {
    [void](Read-Available -State $State -DeadlineUtc $DeadlineUtc)
  }
  else {
    # Released: the bundle is no longer pinned, so retention may remove it while
    # the window keeps its in-memory content.
    if (-not $State.sourceCleaned -and -not (Test-Path -LiteralPath $State.transcriptPath)) {
      $State.sourceCleaned = $true
      Add-Line -State $State -Text '-- source bundle was cleaned by retention; everything above is held in memory'
      Update-StatusBar -State $State
    }
  }

  if ($State.terminalSeen) {
    if (-not $State.completed) {
      $State.completed = $true
      Complete-Run -State $State
      Write-ViewerState -State $State -Lifecycle 'ready'
      Invoke-CompletionSound -State $State
    }
    elseif ((Get-PendingPartialBytes -State $State).Count -gt 0) {
      Flush-PartialTails -State $State
      Update-Token -State $State
      Update-StatusBar -State $State
    }
    # A completed viewer does not pin its bundle: after the replay it releases
    # the file handle.
    if (-not $State.sourceReleased -and (Get-PendingPartialBytes -State $State).Count -eq 0) {
      try { $State.fs.Dispose() } catch { }
      $State.fs = $null
      $State.sourceReleased = $true
      Update-StatusBar -State $State
    }
  }
  elseif ($State.integrity.Count -gt 0 -and -not $State.completed) {
    Update-Token -State $State
    Update-StatusBar -State $State
    Update-WindowTitle -State $State
  }

  Render-Batch -State $State
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

$script:viewerErrors = New-Object 'System.Collections.Generic.List[string]'

function Show-FindDialog {
  param($State)
  $rtb = $State.rtb
  if ($null -eq $rtb) { return }
  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = 'Find (read-only)'
  $dlg.ClientSize = New-Object System.Drawing.Size(360, 96)
  $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $dlg.MaximizeBox = $false
  $dlg.MinimizeBox = $false
  $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $box = New-Object System.Windows.Forms.TextBox
  $box.Location = New-Object System.Drawing.Point(12, 12)
  $box.Width = 336
  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = 'Find next'
  $btn.Location = New-Object System.Drawing.Point(252, 46)
  $btn.Width = 96
  $info = New-Object System.Windows.Forms.Label
  $info.Location = New-Object System.Drawing.Point(12, 50)
  $info.Width = 230
  $info.Text = 'Searches the rendered text.'
  $doFind = {
    $needle = $box.Text
    if ([string]::IsNullOrEmpty($needle)) { return }
    $from = $rtb.SelectionStart + $rtb.SelectionLength
    if ($from -ge $rtb.TextLength) { $from = 0 }
    $idx = $rtb.Text.IndexOf($needle, $from, [System.StringComparison]::Ordinal)
    if ($idx -lt 0 -and $from -gt 0) { $idx = $rtb.Text.IndexOf($needle, 0, [System.StringComparison]::Ordinal) }
    if ($idx -lt 0) { $info.Text = 'No match.'; return }
    $rtb.Select($idx, $needle.Length)
    $rtb.ScrollToCaret()
    $info.Text = 'Match at offset ' + [string]$idx + '.'
  }
  $btn.Add_Click($doFind)
  $box.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return) { & $doFind } })
  [void]$dlg.Controls.Add($box)
  [void]$dlg.Controls.Add($btn)
  [void]$dlg.Controls.Add($info)
  [void]$dlg.ShowDialog($State.form)
  $dlg.Dispose()
}

function New-RunForm {
  param($State)
  $form = New-Object System.Windows.Forms.Form
  $form.Width = 1020
  $form.Height = 720
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $form.MinimumSize = New-Object System.Drawing.Size(560, 260)
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
  $icon = New-Object System.Windows.Forms.ToolStripStatusLabel
  $icon.Image = New-StatusIcon -Color ([System.Drawing.Color]::FromArgb(0, 90, 158))
  [void]$status.Items.Add($icon)
  $label = New-Object System.Windows.Forms.ToolStripStatusLabel
  $label.Text = 'RUNNING'
  $label.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
  $label.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
  [void]$status.Items.Add($label)
  [void]$status.Items.Add((New-Object System.Windows.Forms.ToolStripStatusLabel))
  $detail = New-Object System.Windows.Forms.ToolStripStatusLabel
  $detail.Spring = $true
  $detail.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  [void]$status.Items.Add($detail)

  $header = New-Object System.Windows.Forms.Label
  $header.Dock = [System.Windows.Forms.DockStyle]::Top
  $header.Height = 74
  $header.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
  $header.BackColor = [System.Drawing.Color]::FromArgb(244, 244, 244)
  $header.Font = New-Object System.Drawing.Font('Consolas', 9)
  $header.Text = 'Run      ' + $State.runId

  $menu = New-Object System.Windows.Forms.MenuStrip
  $editMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Edit')
  $copyItem = New-Object System.Windows.Forms.ToolStripMenuItem('Copy')
  $copyItem.ShortcutKeys = [System.Windows.Forms.Keys]::Control -bor [System.Windows.Forms.Keys]::C
  $copyItem.Add_Click({ $State.rtb.Copy() })
  $allItem = New-Object System.Windows.Forms.ToolStripMenuItem('Select all')
  $allItem.ShortcutKeys = [System.Windows.Forms.Keys]::Control -bor [System.Windows.Forms.Keys]::A
  $allItem.Add_Click({ $State.rtb.SelectAll() })
  $findItem = New-Object System.Windows.Forms.ToolStripMenuItem('Find...')
  $findItem.ShortcutKeys = [System.Windows.Forms.Keys]::Control -bor [System.Windows.Forms.Keys]::F
  $findItem.Add_Click({ Show-FindDialog -State $State })
  [void]$editMenu.DropDownItems.Add($copyItem)
  [void]$editMenu.DropDownItems.Add($allItem)
  [void]$editMenu.DropDownItems.Add($findItem)
  $viewMenu = New-Object System.Windows.Forms.ToolStripMenuItem('View')
  $wrapItem = New-Object System.Windows.Forms.ToolStripMenuItem('Line wrap')
  $wrapItem.CheckOnClick = $true
  $wrapItem.Checked = $false
  $wrapItem.Add_Click({ $State.rtb.WordWrap = $wrapItem.Checked })
  [void]$viewMenu.DropDownItems.Add($wrapItem)
  [void]$menu.Items.Add($editMenu)
  [void]$menu.Items.Add($viewMenu)

  [void]$form.Controls.Add($rtb)
  [void]$form.Controls.Add($status)
  [void]$form.Controls.Add($header)
  [void]$form.Controls.Add($menu)
  $form.MainMenuStrip = $menu

  $State.form = $form
  $State.rtb = $rtb
  $State.headerLabel = $header
  $State.statusIcon = $icon
  $State.statusLabel = $label
  $State.statusDetail = $detail

  $form.add_FormClosed({
    param($sender, $e)
    $State.formDetached = $true
    $State.form = $null
    $State.rtb = $null
  })

  Update-Header -State $State
  Update-StatusBar -State $State
  $form.Show()
  $form.Activate()
  Update-WindowTitle -State $State
}

# ---------------------------------------------------------------------------
# Replay mode (headless formatter/driver for automated checks)
# ---------------------------------------------------------------------------

function Invoke-Replay {
  param($State)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($script:ReplayTimeoutMs)
  while ($true) {
    Invoke-Tick -State $State -DeadlineUtc ([DateTime]::UtcNow.AddMilliseconds(250))
    # Invoke-Tick releases the source only once a terminal Run is fully drained.
    if ($State.terminalSeen -and $State.sourceReleased) { break }
    if ([DateTime]::UtcNow -ge $deadline) { break }
    Start-Sleep -Milliseconds 20
  }
  Render-Batch -State $State
  $text = $State.text.ToString()
  if (-not [string]::IsNullOrEmpty($script:ReplayOutPath)) {
    [System.IO.File]::WriteAllText($script:ReplayOutPath, $text, $script:utf8NoBom)
  }
  if (-not $State.terminalSeen) { Add-Integrity -State $State -Reason 'no-terminal-record' }
  $summary = [ordered]@{
    mode             = 'replay'
    runId            = $State.runId
    session          = $State.session
    header           = @(Get-HeaderLines -State $State)
    terminal         = [bool]$State.terminalSeen
    outcome          = $(if ($State.terminalSeen) { [string](Get-PropValue -Rec $State.terminal -Name 'outcome') } else { $null })
    token            = $State.token
    integrityOk      = ($State.integrity.Count -eq 0)
    integrityReasons = @($State.integrity.ToArray())
    soundDecision    = $State.soundDecision
    soundWouldAttempt = [bool]$State.soundWouldAttempt
    soundSuppressed  = [bool]$State.soundSuppressed
    sourceReleased   = [bool]$State.sourceReleased
    sourceCleaned    = [bool]$State.sourceCleaned
    records          = $State.recordCount
    replayed         = $State.replayedCount
    tailed           = $State.tailedCount
    textLength       = $text.Length
    hashExpected     = $(if ($State.terminalSeen) { [string](Get-PropValue -Rec $State.terminal -Name 'sha256') } else { $null })
    hashComputed     = $State.hashComputed
    hashBytes        = $(if ($State.hash.failed) { -1 } else { [int]$State.hash.bytes })
    hashLines        = $(if ($State.hash.failed) { -1 } else { [int]$State.hash.lines })
    fontsResolved    = [bool]$script:fontsResolved
    errors           = @($script:viewerErrors.ToArray())
  }
  Write-Host (ConvertTo-Json -InputObject ([pscustomobject]$summary) -Compress -Depth 8)
  return 0
}

# ---------------------------------------------------------------------------
# Self test: Unicode/RTF/font path + formatter honesty
# ---------------------------------------------------------------------------

# ASCII-safe base64. Decodes to CJK + Korean + emoji (incl. a ZWJ family) +
# combining marks + RTL Arabic/Hebrew + astral math letters + backslash + quote.
$TortureBase64 = '5Lit5paHIOaXpeacrOiqniDtlZzqta3slrQg8J+YgPCfjonwn5Go4oCN8J+RqeKAjfCfkafigI3wn5GmIGXMgSBhzIAg2YXYsdit2KjYpyDXqdec15XXnSDwnZSY8J2Uq/CdlKbwnZSg8J2UrPCdlKHwnZSiIFwgIg=='

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

  # One character per category, in category order, must produce exactly the
  # category font indexes as run prefixes.
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

  # Independent coverage over the whole torture text: each category's chosen
  # family must map every codepoint classified into that category.
  $catMap = [PiGlyphRuns]::GetUniqueCodePoints([string[]]@($expected))
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

  # Formatter honesty probes against the real production formatter.
  $formatterOk = $true
  $formatterDetail = ''
  $state = New-RunState -RunBundleDir (Join-Path $env:TEMP ('pi-viewer-selftest-' + [guid]::NewGuid().ToString()))
  $state.fs = $null
  $deltaLine = '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"hello world"}}'
  Format-StdoutLine -State $state -Line $deltaLine -RawLine $deltaLine
  $probe = [string]::Join("`n", $state.batch.ToArray())
  $state.batch.Clear()
  if ($probe.Contains($deltaLine) -or -not [string]::IsNullOrEmpty($probe)) {
    $formatterOk = $false
    $formatterDetail += 'delta-not-withheld;'
  }
  $textEnd = '{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":1,"content":"hello world"}}'
  Format-StdoutLine -State $state -Line $textEnd -RawLine $textEnd
  $probe = [string]::Join("`n", $state.batch.ToArray())
  $state.batch.Clear()
  if (($probe -notlike '*== assistant text*') -or ($probe -notlike '*hello world*') -or $probe.Contains($textEnd)) {
    $formatterOk = $false
    $formatterDetail += 'text-end-not-reconciled;'
  }
  $unknownLine = '{"type":"future_event","payload":{"n":1}}'
  Format-StdoutLine -State $state -Line $unknownLine -RawLine $unknownLine
  $probe = [string]::Join("`n", $state.batch.ToArray())
  $state.batch.Clear()
  if (-not $probe.Contains('? [event future_event] ' + $unknownLine)) {
    $formatterOk = $false
    $formatterDetail += 'unknown-raw-lost;'
  }
  $badLine = 'not json {'
  Format-StdoutLine -State $state -Line $badLine -RawLine $badLine
  $probe = [string]::Join("`n", $state.batch.ToArray())
  $state.batch.Clear()
  if (-not $probe.Contains('? [unparsed stdout] ' + $badLine)) {
    $formatterOk = $false
    $formatterDetail += 'malformed-raw-lost;'
  }
  # Unfinished fragments must surface once at message_end.
  Format-StdoutLine -State $state -Line $deltaLine -RawLine $deltaLine
  $msgEnd = '{"type":"message_end","message":{"role":"assistant","stopReason":"aborted"}}'
  Format-StdoutLine -State $state -Line $msgEnd -RawLine $msgEnd
  $probe = [string]::Join("`n", $state.batch.ToArray())
  $state.batch.Clear()
  if (-not $probe.Contains('-- unfinished text output [1]')) {
    $formatterOk = $false
    $formatterDetail += 'unfinished-fragments-hidden;'
  }

  # Newline handling: the rendering design depends on LF surviving replay.
  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Multiline = $true
  $tb.Text = "a`nb`n"
  $nlExact = ($tb.Text -ceq "a`nb`n")

  $rtb.Dispose()
  $tb.Dispose()

  $fonts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($cat in $script:displayFonts.Keys) { [void]$fonts.Add($cat + '=' + [string]$script:displayFonts[$cat]) }
  if ($exact -and ($len -gt 40000) -and $nlExact -and $assignmentOk -and $coverageOk -and $formatterOk) {
    Write-Host ('SELFTEST PASS unicode-roundtrip chars={0} newlineRoundtrip=ok font-runs=ok font-coverage=ok formatter-honesty=ok fonts={1}' -f $len, [string]::Join(' ', $fonts.ToArray()))
    return 0
  }
  Write-Host ('SELFTEST FAIL unicode-roundtrip chars={0} exact={1} newlineRoundtrip={2} font-runs={3} font-coverage={4} formatter-honesty={5} detail={6}{7}' -f $len, $exact, $nlExact, $assignmentOk, $coverageOk, $formatterOk, $coverageDetail, $formatterDetail)
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$script:ReplayMode = [bool]$Replay
$script:NoSoundMode = [bool]$NoSound
$script:ReplayOutPath = $OutPath
$script:instanceId = [guid]::NewGuid().ToString()
$script:viewerStartedAt = Get-NowMs
$script:boldFont = $null

if ($SelfTest) { exit (Invoke-SelfTest) }

if ([string]::IsNullOrWhiteSpace($BundleDir)) {
  throw '-BundleDir is required unless -SelfTest is used.'
}
$BundleDir = [System.IO.Path]::GetFullPath($BundleDir)
if (-not [System.IO.Directory]::Exists($BundleDir)) {
  throw ('bundle directory does not exist: ' + $BundleDir)
}
if (-not $Replay -and $env:PI_SUBAGENT_VIEWER_MODE -eq 'replay') {
  $script:ReplayMode = $true
}

$script:runState = New-RunState -RunBundleDir $BundleDir
$manifest = $null
$manifestPath = Join-Path $BundleDir 'manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
  try { $manifest = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($manifestPath, $script:utf8)) } catch { $manifest = $null }
}
if ($null -ne $manifest) {
  $script:runState.runId = [string](Get-PropValue -Rec $manifest -Name 'runId')
  $script:runState.session = [string](Get-PropValue -Rec $manifest -Name 'session')
  $createdAt = Get-PropValue -Rec $manifest -Name 'createdAt'
  if ($null -ne $createdAt) {
    try { $script:runState.startedAtUtc = ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$createdAt)).UtcDateTime.ToString('o') } catch { }
  }
}
if ([string]::IsNullOrEmpty($script:runState.runId)) { $script:runState.runId = (Split-Path -Leaf $BundleDir) }

# A durable alertAttemptedAt from an earlier instance suppresses the sound on
# reopen: one attempt per Run, with no claim that the sound was heard.
$priorState = Read-ViewerState -State $script:runState
if ($null -ne $priorState -and $null -ne (Get-PropValue -Rec $priorState -Name 'alertAttemptedAt')) {
  $script:runState.soundPlayed = $true
  $script:runState.soundSuppressed = $true
}

if ($script:ReplayMode) {
  exit (Invoke-Replay -State $script:runState)
}

$apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState().ToString()
if ($apartment -ne 'STA') {
  throw "GUI mode requires an STA thread (current: $apartment). Node launches this script with -STA."
}
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

Write-ViewerState -State $script:runState -Lifecycle 'starting'

Resolve-DisplayFonts
New-RunForm -State $script:runState
Write-ViewerState -State $script:runState -Lifecycle 'ready'
Update-Header -State $script:runState
Update-StatusBar -State $script:runState
Update-WindowTitle -State $script:runState

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = $TickMs
$script:timer.Add_Tick({
  try {
    if (Test-FocusRequested -State $script:runState) {
      $form = $script:runState.form
      if ($null -ne $form) {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $form.TopMost = $true
        $form.Activate()
        $form.TopMost = $false
      }
    }
    Invoke-Tick -State $script:runState -DeadlineUtc ([DateTime]::UtcNow.AddMilliseconds([Math]::Max(50, $script:runState.tickBudgetMs)))
  }
  catch {
    [void]$script:viewerErrors.Add('tick: ' + $_.Exception.Message)
    $script:runState.displayError = $_.Exception.Message
    Update-StatusBar -State $script:runState
  }
})
$script:timer.Start()
[System.Windows.Forms.Application]::Run()
$script:timer.Stop()

Render-Batch -State $script:runState
# The bundle stays at the four declared files: any viewer diagnostics go into
# viewer-state.json's lastError rather than a fifth file.
$exitError = ''
if ($script:viewerErrors.Count -gt 0) {
  [void]$script:viewerErrors.Insert(0, '(' + [string]$script:viewerErrors.Count + ' viewer error(s))')
  $exitError = [string]::Join(' | ', @($script:viewerErrors.ToArray() | Select-Object -First 5))
}
Write-ViewerState -State $script:runState -Lifecycle 'exited' -Error $exitError
exit 0
