#requires -Version 5.1
<#
  verify-prototype.ps1 - independent lossless/behaviour checker (ticket 03 prototype).

  Joins manifest.json (generator ground truth) with report.json (viewer state)
  on runId and checks, per Run:
    - the journal parses, seq is 1..N monotonic, no BOM;
    - rawSha256 recomputed from every record's data (joined with LF, UTF-8)
      equals both the manifest and the report value;
    - replayedCount + tailedCount == renderedCount == lastSeq == emittedCount;
    - replay/tail are judged against when the viewer opened: startedAt before
      manifest.generatedAt means the viewer ran concurrently with generation,
      so replayedCount > 0 and tailedCount > 0 are required (FAIL otherwise)
      and the volume latency thresholds are measurable; startedAt after
      generatedAt means a fully pre-generated backlog, so tailedCount == 0 is
      expected (NA) and latency thresholds are not applicable (NA);
    - the rendered text has the reported length/sha256 and contains every
      data payload verbatim in record order (advancing IndexOf scan, so the
      check is O(total text) not O(n * text));
    - completion semantics: a terminal with signal == null and no gap and no
      earlier captureError means complete + exactly one notification; a
      captureError or a terminal with signal != null means incomplete and no
      notification; duplicate terminal records must not notify twice;
    - scenario probes: volume latency/heartbeat thresholds, windowfail
      displayError, closure detached-window warning;
    - RUN-SENTINEL isolation: every sentinel appears in its own rendered
      text and in no other rendered text;
    - generation finished (generatorFinishedAt / generatedAt present).

  Overall status is FAIL when any check fails, else PASS (WARN allowed).
  Exit code is 1 on FAIL, 0 otherwise.

  -SelfTest builds synthetic fixture sets under <script dir>\_out\verify-selftest
  and asserts the checker PASSes a good set and FAILs (on the right check) for:
  corrupted hash, lost payload, double notification, notified capture failure,
  volume threshold breach, missing run, plus a WARN case for an unclosed
  closure window. It prints VERIFY SELFTEST PASS/FAIL and exits.

  Examples
  --------
    powershell -NoProfile -ExecutionPolicy Bypass -File verify-prototype.ps1 `
      -FixtureDir .\prototype\_out
    powershell -NoProfile -ExecutionPolicy Bypass -File verify-prototype.ps1 -SelfTest
#>
[CmdletBinding()]
param(
  [string]$FixtureDir,
  [string]$ReportPath,
  [string]$ManifestPath,
  [switch]$SelfTest,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-NowMs {
  return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

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

function Get-Prop {
  param($Obj, [string]$Name)
  if ($null -eq $Obj) { return $null }
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

function Add-Check {
  param($Checks, [string]$Name, [string]$Status, [string]$Detail)
  $Checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    return (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)))
  }
  catch {
    return $null
  }
}

function Test-FileHasNoBom {
  param([string]$Path)
  try {
    $fs = [System.IO.File]::OpenRead($Path)
    try {
      $head = New-Object byte[] 3
      $n = $fs.Read($head, 0, 3)
      if ($n -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) { return $false }
      return $true
    }
    finally { $fs.Dispose() }
  }
  catch {
    return $false
  }
}

# ---- formatter mirror ----
# These mirror the production renderer in per-run-window.ps1 so the verifier
# can predict which payload text is formatted and which stays verbatim,
# without re-reading the viewer script.

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

# Collects the scalar strings that the production Add-ValueLines emits, in
# document order. Empty strings are skipped (they cannot be located in the
# rendered text by IndexOf). Depth 1 matches a formatted event payload.
function Add-LeafScalarStrings {
  param(
    [System.Collections.Generic.List[string]]$Out,
    $Value,
    [int]$Depth,
    [string[]]$Skip = @(),
    [bool]$IsTop = $true
  )
  if ($Depth -gt 20) {
    [void]$Out.Add((Format-ValueCompact -Value $Value))
    return
  }
  if (-not (Test-StructuredValue -Value $Value)) {
    $s = Format-ScalarText -Value $Value
    if ($s.Length -gt 0) { [void]$Out.Add($s) }
    return
  }
  if ($Value -is [System.Array]) {
    foreach ($item in @($Value)) { Add-LeafScalarStrings -Out $Out -Value $item -Depth ($Depth + 1) -Skip @() -IsTop $false }
    return
  }
  foreach ($p in @($Value.PSObject.Properties)) {
    if ($IsTop -and ($Skip -contains [string]$p.Name)) { continue }
    Add-LeafScalarStrings -Out $Out -Value $p.Value -Depth ($Depth + 1) -Skip @() -IsTop $false
  }
}

function Invoke-Verification {
  param(
    [Parameter(Mandatory = $true)][string]$FixtureDir,
    [string]$ManifestPath,
    [string]$ReportPath
  )
  $checks = New-Object 'System.Collections.Generic.List[object]'

  if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $FixtureDir 'manifest.json' }
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $FixtureDir 'report.json' }

  if (-not (Test-Path -LiteralPath $ManifestPath)) {
    Add-Check $checks 'manifest.json' 'FAIL' ('missing: ' + $ManifestPath)
    return [pscustomobject]@{ Checks = $checks; FailCount = 1; WarnCount = 0; Overall = 'FAIL' }
  }
  if (-not (Test-Path -LiteralPath $ReportPath)) {
    Add-Check $checks 'report.json' 'FAIL' ('missing: ' + $ReportPath)
    return [pscustomobject]@{ Checks = $checks; FailCount = 1; WarnCount = 0; Overall = 'FAIL' }
  }

  $manifest = Read-JsonFile -Path $ManifestPath
  if ($null -eq $manifest) {
    Add-Check $checks 'manifest.json' 'FAIL' 'unparseable JSON'
    return [pscustomobject]@{ Checks = $checks; FailCount = 1; WarnCount = 0; Overall = 'FAIL' }
  }
  Add-Check $checks 'manifest.json' 'PASS' ('scenario=' + [string]$manifest.scenario)

  $report = Read-JsonFile -Path $ReportPath
  if ($null -eq $report) {
    Add-Check $checks 'report.json' 'FAIL' 'unparseable JSON'
    return [pscustomobject]@{ Checks = $checks; FailCount = 1; WarnCount = 0; Overall = 'FAIL' }
  }
  Add-Check $checks 'report.json' 'PASS' ('headless=' + [string]$report.headless + ' ticks=' + [string]$report.ticks)

  if (Test-FileHasNoBom -Path $ManifestPath) { Add-Check $checks 'encoding no-BOM manifest' 'PASS' 'no BOM' }
  else { Add-Check $checks 'encoding no-BOM manifest' 'FAIL' 'manifest.json starts with a UTF-8 BOM' }
  if (Test-FileHasNoBom -Path $ReportPath) { Add-Check $checks 'encoding no-BOM report' 'PASS' 'no BOM' }
  else { Add-Check $checks 'encoding no-BOM report' 'FAIL' 'report.json starts with a UTF-8 BOM' }

  $manifestRuns = @($manifest.runs)
  $reportRuns = @($report.runs)
  $manifestByRun = @{}
  foreach ($m in $manifestRuns) { if ($null -ne $m) { $manifestByRun[[string]$m.runId] = $m } }
  $reportByRun = @{}
  foreach ($r in $reportRuns) { if ($null -ne $r) { $reportByRun[[string]$r.runId] = $r } }

  $setProblems = New-Object 'System.Collections.Generic.List[string]'
  foreach ($id in $manifestByRun.Keys) { if (-not $reportByRun.ContainsKey($id)) { [void]$setProblems.Add('report missing ' + $id) } }
  foreach ($id in $reportByRun.Keys) { if (-not $manifestByRun.ContainsKey($id)) { [void]$setProblems.Add('report extra ' + $id) } }
  if ($setProblems.Count -eq 0) {
    Add-Check $checks 'run-set manifest-vs-report' 'PASS' ($manifestByRun.Count.ToString() + ' runs')
  }
  else {
    Add-Check $checks 'run-set manifest-vs-report' 'FAIL' ([string]::Join('; ', $setProblems.ToArray()))
  }

  # Viewer start vs generator finish decides which streaming expectations
  # apply. Both timestamps are unix ms written by the two processes.
  $reportStartedAt = $null
  $reportStartedProp = Get-Prop -Obj $report -Name 'startedAt'
  if ($null -ne $reportStartedProp) { $reportStartedAt = [long]$reportStartedProp }
  $generatedAt = $null
  $generatedAtProp = Get-Prop -Obj $manifest -Name 'generatedAt'
  if ($null -ne $generatedAtProp) { $generatedAt = [long]$generatedAtProp }
  $concurrentViewer = $false
  if ($null -ne $reportStartedAt -and $null -ne $generatedAt -and $reportStartedAt -lt $generatedAt) {
    $concurrentViewer = $true
  }
  if ($null -eq $reportStartedAt -or $null -eq $generatedAt) {
    Add-Check $checks 'viewer-open-context' 'WARN' 'missing startedAt/generatedAt; treating streaming expectations as post-hoc'
  }
  elseif ($concurrentViewer) {
    Add-Check $checks 'viewer-open-context' 'PASS' 'concurrent: viewer started before generation finished'
  }
  else {
    Add-Check $checks 'viewer-open-context' 'PASS' 'post-hoc: generation finished before the viewer started'
  }

  if ($null -eq $manifest.generatedAt) { Add-Check $checks 'generator finished' 'FAIL' 'manifest.generatedAt missing' }
  else { Add-Check $checks 'generator finished' 'PASS' 'generatedAt present' }

  $renderedTexts = @{}
  $notificationList = @($report.notifications)
  $forceErrorFile = Join-Path $FixtureDir 'force-display-error.txt'
  $forcedDisplayIds = @()
  if (Test-Path -LiteralPath $forceErrorFile) {
    try { $forcedDisplayIds = @(Get-Content -LiteralPath $forceErrorFile -ErrorAction SilentlyContinue) }
    catch { $forcedDisplayIds = @() }
  }
  $hasClosure = $false
  $hasVolume = $false

  foreach ($m in $manifestRuns) {
    if ($null -eq $m) { continue }
    $runId = [string]$m.runId
    $scenario = [string]$m.scenario
    $r = $null
    if ($reportByRun.ContainsKey($runId)) { $r = $reportByRun[$runId] }

    if ($scenario -eq 'closure') { $hasClosure = $true }
    if ($scenario -eq 'volume') { $hasVolume = $true }

    if ($null -eq $m.generatorFinishedAt) {
      Add-Check $checks ('run ' + $runId + ' generator-finished') 'FAIL' 'generatorFinishedAt missing'
    }

    # ---- journal ----
    $journalPath = Join-Path $FixtureDir ([string]$m.journal)
    $records = New-Object 'System.Collections.Generic.List[object]'
    $dataList = New-Object 'System.Collections.Generic.List[string]'
    $journalOk = $false
    $seqOk = $true
    $terminalRecords = 0
    $captureErrorRecords = 0
    $journalDetail = ''
    if (-not (Test-Path -LiteralPath $journalPath)) {
      $journalDetail = 'missing journal: ' + $journalPath
    }
    else {
      try {
        $lines = [System.IO.File]::ReadAllLines($journalPath, [System.Text.Encoding]::UTF8)
        $expected = 1
        foreach ($ln in $lines) {
          if ([string]::IsNullOrEmpty($ln)) { continue }
          $rec = ConvertFrom-Json -InputObject $ln
          if ($null -eq $rec -or $null -eq $rec.seq -or [int]$rec.seq -ne $expected) { $seqOk = $false }
          $expected++
          $records.Add($rec)
          if ($null -ne $rec.data) { [void]$dataList.Add([string]$rec.data) }
          if ($null -ne $rec.ch -and [string]$rec.ch -eq 'meta' -and $null -ne $rec.kind) {
            if ([string]$rec.kind -eq 'terminal') { $terminalRecords++ }
            if ([string]$rec.kind -eq 'captureError') { $captureErrorRecords++ }
          }
        }
        $journalOk = $true
        if (-not $seqOk) { $journalDetail = 'seq not 1..N monotonic' }
        else { $journalDetail = ($records.Count.ToString() + ' records, seq 1..' + $records.Count.ToString()) }
      }
      catch {
        $journalDetail = 'parse error: ' + $_.Exception.Message
      }
    }
    if ($journalOk -and $seqOk) { Add-Check $checks ('run ' + $runId + ' journal') 'PASS' $journalDetail }
    else { Add-Check $checks ('run ' + $runId + ' journal') 'FAIL' $journalDetail }

    if ((Test-Path -LiteralPath $journalPath) -and (Test-FileHasNoBom -Path $journalPath)) {
      Add-Check $checks ('run ' + $runId + ' encoding no-BOM') 'PASS' 'no BOM'
    }
    elseif (Test-Path -LiteralPath $journalPath) {
      Add-Check $checks ('run ' + $runId + ' encoding no-BOM') 'FAIL' 'journal starts with a UTF-8 BOM'
    }

    if ($null -eq $r) {
      continue
    }

    # ---- hash ----
    if ($journalOk) {
      $rawJoined = [string]::Join("`n", $dataList.ToArray())
      $recomputed = Get-Sha256Hex -Text $rawJoined
      $mHash = [string]$m.rawSha256
      $rHash = [string]$r.rawSha256
      if ($recomputed -ceq $mHash -and $recomputed -ceq $rHash) {
        Add-Check $checks ('run ' + $runId + ' rawSha256') 'PASS' $recomputed
      }
      else {
        Add-Check $checks ('run ' + $runId + ' rawSha256') 'FAIL' ('journal=' + $recomputed + ' manifest=' + $mHash + ' report=' + $rHash)
      }
    }

    # ---- counts ----
    if ($journalOk) {
      $journalCount = $records.Count
      $sum = [int]$r.replayedCount + [int]$r.tailedCount
      $problems = New-Object 'System.Collections.Generic.List[string]'
      if ([int]$m.emittedCount -ne $journalCount) { [void]$problems.Add('emittedCount=' + [string]$m.emittedCount + ' != journal=' + $journalCount) }
      if ([int]$m.lastSeq -ne $journalCount) { [void]$problems.Add('manifest lastSeq != journal') }
      if ($sum -ne $journalCount) { [void]$problems.Add('replayed+tailed=' + $sum + ' != journal=' + $journalCount) }
      if ([int]$r.renderedCount -ne $journalCount) { [void]$problems.Add('renderedCount=' + [string]$r.renderedCount + ' != journal=' + $journalCount) }
      if ([int]$r.lastSeq -ne $journalCount) { [void]$problems.Add('report lastSeq=' + [string]$r.lastSeq + ' != journal=' + $journalCount) }
      if ($sum -ne [int]$r.renderedCount) { [void]$problems.Add('replayed+tailed != renderedCount') }
      if ($null -eq (Get-Prop -Obj $r -Name 'receivedOrderOk') -or (-not [bool]$r.receivedOrderOk)) { [void]$problems.Add('receivedOrderOk=false') }
      if ($problems.Count -eq 0) {
        Add-Check $checks ('run ' + $runId + ' counts') 'PASS' ('emitted=' + $journalCount + ' replayed=' + [string]$r.replayedCount + ' tailed=' + [string]$r.tailedCount + ' rendered=' + [string]$r.renderedCount)
      }
      else {
        Add-Check $checks ('run ' + $runId + ' counts') 'FAIL' ([string]::Join('; ', $problems.ToArray()))
      }
      if ([int]$r.replayedCount -le 0) {
        Add-Check $checks ('run ' + $runId + ' replay observed') 'FAIL' 'replayedCount=0 even though the journal existed when the viewer opened'
      }
      else {
        Add-Check $checks ('run ' + $runId + ' replay observed') 'PASS' ([string]$r.replayedCount + ' records replayed')
      }
      if ([int]$r.tailedCount -le 0) {
        if ($concurrentViewer) {
          Add-Check $checks ('run ' + $runId + ' tail observed') 'FAIL' 'tailedCount=0 while the viewer ran concurrently with generation'
        }
        else {
          Add-Check $checks ('run ' + $runId + ' tail observed') 'NA' 'tailedCount=0 (journal was already complete when the viewer opened)'
        }
      }
      else {
        Add-Check $checks ('run ' + $runId + ' tail observed') 'PASS' ([string]$r.tailedCount + ' records tailed')
      }
    }

    # ---- rendered text ----
    $renderedPath = Join-Path $FixtureDir ($runId + '.rendered.txt')
    if (-not (Test-Path -LiteralPath $renderedPath)) {
      Add-Check $checks ('run ' + $runId + ' rendered text') 'FAIL' ('missing: ' + $renderedPath)
    }
    else {
      $text = [System.IO.File]::ReadAllText($renderedPath, [System.Text.Encoding]::UTF8)
      $renderedTexts[$runId] = $text
      $problems = New-Object 'System.Collections.Generic.List[string]'
      if ($text.Length -ne [int]$r.textLength) { [void]$problems.Add('length=' + $text.Length + ' != report=' + [string]$r.textLength) }
      $textHash = Get-Sha256Hex -Text $text
      if ($textHash -cne [string]$r.textSha256) { [void]$problems.Add('textSha256 mismatch') }
      if ($journalOk) {
        $knownEventTypes = @('session', 'agent_start', 'agent_settled', 'turn_start', 'turn_end', 'agent_end', 'message_start', 'message_end', 'message_update', 'tool_execution_start', 'tool_execution_update', 'tool_execution_end')
        $forbiddenRaw = New-Object 'System.Collections.Generic.HashSet[string]'
        $pos = 0
        $missingAt = -1
        $missingWhat = ''
        for ($i = 0; $i -lt $records.Count; $i++) {
          $rec = $records[$i]
          $ch = ''
          if ($null -ne $rec.ch) { $ch = [string]$rec.ch }
          $kind = ''
          if ($null -ne $rec.kind) { $kind = [string]$rec.kind }
          $data = ''
          if ($null -ne $rec.data) { $data = [string]$rec.data }
          $rawVisible = $false
          $header = ''
          $leafValues = New-Object 'System.Collections.Generic.List[string]'
          if ($ch -eq 'stdout') {
            $evt = $null
            try { $evt = ConvertFrom-Json -InputObject $data } catch { $evt = $null }
            if ($null -eq $evt -or $null -eq $evt.type) {
              $rawVisible = $true
            }
            elseif ($knownEventTypes -notcontains [string]$evt.type) {
              $rawVisible = $true
            }
            else {
              # Recognised event: formatted block, raw JSON must not reappear.
              $header = '== ' + [string]$evt.type
              Add-LeafScalarStrings -Out $leafValues -Value $evt -Depth 1 -Skip @('type') -IsTop $true
              [void]$forbiddenRaw.Add($data)
            }
          }
          elseif ($ch -eq 'meta' -and $kind -eq 'terminal') {
            $header = '== terminal status=' + (Format-ScalarText -Value $rec.status) + ' exit=' + (Format-ScalarText -Value $rec.exitCode) + ' signal=' + (Format-ScalarText -Value $rec.signal)
            $dataObj = $null
            try { $dataObj = ConvertFrom-Json -InputObject $data } catch { $dataObj = $null }
            if (Test-StructuredValue -Value $dataObj) {
              Add-LeafScalarStrings -Out $leafValues -Value $dataObj -Depth 2 -Skip @('status', 'exitCode', 'signal') -IsTop $true
              [void]$forbiddenRaw.Add($data)
            }
            else {
              # Payload not parseable: kept verbatim on a data: line.
              $rawVisible = $true
            }
          }
          elseif ($ch -eq 'meta' -or $ch -eq 'stderr') {
            # launch/captureError/other meta kinds and stderr keep data verbatim.
            $rawVisible = $true
          }
          else {
            # Non-stdout channel: raw passthrough.
            $rawVisible = $true
          }

          if ($rawVisible) {
            if ($data.Length -gt 0) {
              $idx = $text.IndexOf($data, $pos)
              if ($idx -lt 0) {
                $missingAt = $i + 1
                $missingWhat = 'raw payload not found in order'
                break
              }
              $pos = $idx + $data.Length
            }
          }
          else {
            $idx = $text.IndexOf($header, $pos)
            if ($idx -lt 0) {
              $missingAt = $i + 1
              $missingWhat = 'formatted header not found: ' + $header
              break
            }
            $pos = $idx + $header.Length
            $valueMissing = ''
            foreach ($v in $leafValues) {
              $vi = $text.IndexOf($v, $pos)
              if ($vi -lt 0) { $valueMissing = $v; break }
              $pos = $vi + $v.Length
            }
            if ($valueMissing.Length -gt 0) {
              $missingAt = $i + 1
              $preview = $valueMissing
              if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 60) + '...' }
              $missingWhat = 'formatted value not found in order: ' + $preview
              break
            }
          }
        }
        if ($missingAt -lt 0 -and $forbiddenRaw.Count -gt 0) {
          foreach ($line in $text.Split("`n")) {
            $trim = $line.TrimEnd([char]13)
            if ($forbiddenRaw.Contains($trim)) {
              $missingAt = -2
              $missingWhat = 'raw JSON duplicated as its own line'
              break
            }
            if ($trim.StartsWith('raw: ') -and $forbiddenRaw.Contains($trim.Substring(5))) {
              $missingAt = -2
              $missingWhat = 'legacy raw: copy present for a formatted record'
              break
            }
          }
        }
        if ($missingAt -eq -2) {
          [void]$problems.Add($missingWhat)
        }
        elseif ($missingAt -ge 0) {
          [void]$problems.Add('record seq ' + $missingAt + ': ' + $missingWhat)
        }
      }
      if ($problems.Count -eq 0) {
        Add-Check $checks ('run ' + $runId + ' rendered payloads') 'PASS' ($text.Length.ToString() + ' chars, formatted/verbatim payloads in order, no duplicate raw JSON')
      }
      else {
        Add-Check $checks ('run ' + $runId + ' rendered payloads') 'FAIL' ([string]::Join('; ', $problems.ToArray()))
      }
    }

    # ---- window title ----
    $title = ''
    if ($null -ne (Get-Prop -Obj $r -Name 'windowTitle')) { $title = [string]$r.windowTitle }
    if ($title.StartsWith('Run ' + $runId + ' - ')) {
      Add-Check $checks ('run ' + $runId + ' window-title') 'PASS' $title
    }
    else {
      Add-Check $checks ('run ' + $runId + ' window-title') 'FAIL' ('title must start with Run <full-runId> - , got: ' + $title)
    }

    # ---- completion / notification semantics ----
    $expectedComplete = ($null -ne $m.terminal) -and ($captureErrorRecords -eq 0)
    $notified = [bool](Get-Prop -Obj $r -Name 'notified')
    $counts = Get-Prop -Obj $report -Name 'notificationCounts'
    $notifyCount = 0
    if ($null -ne $counts) {
      $cp = $counts.PSObject.Properties[$runId]
      if ($null -ne $cp) { $notifyCount = [int]$cp.Value }
    }
    $listCount = 0
    foreach ($nid in $notificationList) { if ([string]$nid -ceq $runId) { $listCount++ } }

    if ($expectedComplete) {
      $problems = New-Object 'System.Collections.Generic.List[string]'
      if (-not [bool]$r.terminal) { [void]$problems.Add('report terminal=false') }
      if ($null -ne (Get-Prop -Obj $r -Name 'incomplete') -and [bool]$r.incomplete) { [void]$problems.Add('report incomplete=true') }
      $expectedStatus = [string]$m.terminal.status
      if ([string]$r.status -cne $expectedStatus) { [void]$problems.Add('status=' + [string]$r.status + ' != manifest=' + $expectedStatus) }
      if (-not $notified) { [void]$problems.Add('notified=false') }
      if ($notifyCount -ne 1) { [void]$problems.Add('notificationCounts=' + $notifyCount) }
      if ($listCount -ne 1) { [void]$problems.Add('notifications list count=' + $listCount) }
      if ($problems.Count -eq 0) {
        Add-Check $checks ('run ' + $runId + ' completion') 'PASS' ('complete status=' + $expectedStatus + ' notified once')
      }
      else {
        Add-Check $checks ('run ' + $runId + ' completion') 'FAIL' ([string]::Join('; ', $problems.ToArray()))
      }
    }
    else {
      $problems = New-Object 'System.Collections.Generic.List[string]'
      if ([bool]$r.terminal) { [void]$problems.Add('report terminal=true') }
      if (-not [bool]$r.captureError) { [void]$problems.Add('report captureError=false') }
      if (-not [bool]$r.incomplete) { [void]$problems.Add('report incomplete=false') }
      if ($notified) { [void]$problems.Add('notified=true') }
      if ($notifyCount -ne 0) { [void]$problems.Add('notificationCounts=' + $notifyCount) }
      if ($listCount -ne 0) { [void]$problems.Add('notifications list count=' + $listCount) }
      if ($problems.Count -eq 0) {
        Add-Check $checks ('run ' + $runId + ' capture-failure semantics') 'PASS' 'incomplete, no notification'
      }
      else {
        Add-Check $checks ('run ' + $runId + ' capture-failure semantics') 'FAIL' ([string]::Join('; ', $problems.ToArray()))
      }
    }

    # ---- scenario probes ----
    if ($scenario -eq 'volume') {
      if ([int]$r.maxHeartbeatGapMs -lt 500) { Add-Check $checks ('run ' + $runId + ' heartbeat-gap') 'PASS' ([string]$r.maxHeartbeatGapMs + ' ms < 500 ms') }
      else { Add-Check $checks ('run ' + $runId + ' heartbeat-gap') 'FAIL' ([string]$r.maxHeartbeatGapMs + ' ms >= 500 ms') }
      if ([int]$r.tailedCount -le 0) {
        if ($concurrentViewer) {
          Add-Check $checks ('run ' + $runId + ' p95-latency') 'FAIL' ([string]$r.p95LatencyMs + ' ms but no tailed records were observed during generation')
          Add-Check $checks ('run ' + $runId + ' max-latency') 'FAIL' ([string]$r.maxLatencyMs + ' ms but no tailed records were observed during generation')
        }
        else {
          Add-Check $checks ('run ' + $runId + ' p95-latency') 'NA' ([string]$r.p95LatencyMs + ' ms on a fully pre-generated backlog; streaming latency is not measurable post-hoc')
          Add-Check $checks ('run ' + $runId + ' max-latency') 'NA' ([string]$r.maxLatencyMs + ' ms on a fully pre-generated backlog; streaming latency is not measurable post-hoc')
        }
      }
      else {
        if ([int]$r.p95LatencyMs -lt 2000) { Add-Check $checks ('run ' + $runId + ' p95-latency') 'PASS' ([string]$r.p95LatencyMs + ' ms < 2000 ms') }
        else { Add-Check $checks ('run ' + $runId + ' p95-latency') 'FAIL' ([string]$r.p95LatencyMs + ' ms >= 2000 ms') }
        if ([int]$r.maxLatencyMs -lt 8000) { Add-Check $checks ('run ' + $runId + ' max-latency') 'PASS' ([string]$r.maxLatencyMs + ' ms < 8000 ms') }
        else { Add-Check $checks ('run ' + $runId + ' max-latency') 'FAIL' ([string]$r.maxLatencyMs + ' ms >= 8000 ms') }
      }
    }
    if ($scenario -eq 'windowfail') {
      $expectDisplayError = $false
      foreach ($fid in $forcedDisplayIds) { if ([string]$fid -ceq $runId) { $expectDisplayError = $true } }
      $hasDisplayError = -not [string]::IsNullOrEmpty([string]$r.displayError)
      if ($expectDisplayError -and $hasDisplayError) {
        Add-Check $checks ('run ' + $runId + ' display-error recorded') 'PASS' ([string]$r.displayError)
      }
      elseif ($expectDisplayError) {
        Add-Check $checks ('run ' + $runId + ' display-error recorded') 'FAIL' 'expected a simulated display error'
      }
      elseif ($hasDisplayError) {
        Add-Check $checks ('run ' + $runId + ' display-error recorded') 'FAIL' ('unexpected display error: ' + [string]$r.displayError)
      }
      else {
        Add-Check $checks ('run ' + $runId + ' display-error recorded') 'PASS' 'no forced display error for this run'
      }
    }
    if ($scenario -eq 'duplicate') {
      if ($terminalRecords -eq 2) { Add-Check $checks ('run ' + $runId + ' duplicate-terminal') 'PASS' 'two terminal records, one notification' }
      else { Add-Check $checks ('run ' + $runId + ' duplicate-terminal') 'FAIL' ('terminal records=' + $terminalRecords) }
    }

    # ---- sentinel isolation (own copy) ----
    $sentinel = [string]$m.uniqueSentinel
    if (-not [string]::IsNullOrEmpty($sentinel)) {
      if ($renderedTexts.ContainsKey($runId) -and $renderedTexts[$runId].Contains($sentinel)) {
        Add-Check $checks ('run ' + $runId + ' sentinel-present') 'PASS' $sentinel
      }
      else {
        Add-Check $checks ('run ' + $runId + ' sentinel-present') 'FAIL' ('sentinel not found in own rendered text: ' + $sentinel)
      }
    }
  }

  # ---- sentinel isolation (cross-run) ----
  $sentinelProblems = New-Object 'System.Collections.Generic.List[string]'
  $sentinelCount = 0
  foreach ($m in $manifestRuns) {
    if ($null -eq $m) { continue }
    $sentinel = [string]$m.uniqueSentinel
    if ([string]::IsNullOrEmpty($sentinel)) { continue }
    $sentinelCount++
    $owner = [string]$m.runId
    foreach ($otherId in $renderedTexts.Keys) {
      if ($otherId -ceq $owner) { continue }
      if ($renderedTexts[$otherId].Contains($sentinel)) {
        [void]$sentinelProblems.Add($sentinel + ' leaked into ' + $otherId)
      }
    }
  }
  if ($sentinelCount -eq 0) {
    Add-Check $checks 'sentinel isolation' 'NA' 'no sentinel runs in this fixture'
  }
  elseif ($sentinelProblems.Count -eq 0) {
    Add-Check $checks 'sentinel isolation' 'PASS' ($sentinelCount.ToString() + ' sentinels confined to their own windows')
  }
  else {
    Add-Check $checks 'sentinel isolation' 'FAIL' ([string]::Join('; ', $sentinelProblems.ToArray()))
  }

  # ---- closure detach (human action probe) ----
  if ($hasClosure) {
    $anyDetached = $false
    foreach ($m in $manifestRuns) {
      if ($null -eq $m -or [string]$m.scenario -ne 'closure') { continue }
      $r = $null
      if ($reportByRun.ContainsKey([string]$m.runId)) { $r = $reportByRun[[string]$m.runId] }
      if ($null -ne $r -and [bool]$r.formDetached) { $anyDetached = $true }
    }
    if ($anyDetached) { Add-Check $checks 'closure-detached' 'PASS' 'a window was closed mid-stream and the Run kept capturing' }
    else { Add-Check $checks 'closure-detached' 'WARN' 'no closure window was closed mid-stream (human checklist item)' }
  }
  else {
    Add-Check $checks 'closure-detached' 'NA' 'no closure run in this fixture'
  }

  # ---- display font metadata ----
  $fontProblems = New-Object 'System.Collections.Generic.List[string]'
  $fontFamilies = Get-Prop -Obj $report -Name 'fontFamiliesResolved'
  if ($null -eq $fontFamilies) { [void]$fontProblems.Add('fontFamiliesResolved missing') }
  elseif (([int]$fontFamilies -le 0) -or ([int]$fontFamilies -gt 30)) { [void]$fontProblems.Add('fontFamiliesResolved=' + [string]$fontFamilies + ' outside 1..30') }
  $details = Get-Prop -Obj $report -Name 'displayFontDetails'
  if ($null -eq $details) { [void]$fontProblems.Add('displayFontDetails missing') }
  else {
    foreach ($cat in @('base', 'cjk', 'hangul', 'emoji', 'rtl', 'math', 'symbol')) {
      $dProp = $details.PSObject.Properties[$cat]
      if ($null -eq $dProp) { [void]$fontProblems.Add($cat + ': missing detail') ; continue }
      $dv = $dProp.Value
      if (-not [bool](Get-Prop -Obj $dv -Name 'resolved')) { [void]$fontProblems.Add($cat + ': not resolved') }
      $sm = Get-Prop -Obj $dv -Name 'sampleMissing'
      if ($null -ne $sm -and @($sm).Count -gt 0) { [void]$fontProblems.Add($cat + ': sampleMissing=' + [string]::Join(',', @($sm))) }
      if ([int](Get-Prop -Obj $dv -Name 'glyphCount') -le 0) { [void]$fontProblems.Add($cat + ': glyphCount<=0') }
    }
  }
  $cache = Get-Prop -Obj $report -Name 'fontCache'
  if ($null -eq $cache) { [void]$fontProblems.Add('fontCache missing') }
  else {
    foreach ($p in @($cache.PSObject.Properties)) {
      $cv = $p.Value
      if (-not [bool](Get-Prop -Obj $cv -Name 'resolved')) { [void]$fontProblems.Add('fontCache ' + $p.Name + ': not resolved') }
      if ([int](Get-Prop -Obj $cv -Name 'glyphCount') -le 0) { [void]$fontProblems.Add('fontCache ' + $p.Name + ': glyphCount<=0') }
    }
  }
  if ($fontProblems.Count -eq 0) {
    Add-Check $checks 'display fonts' 'PASS' ([string]$fontFamilies + ' families cached, every category resolved with sampleMissing empty')
  }
  else {
    Add-Check $checks 'display fonts' 'FAIL' ([string]::Join('; ', $fontProblems.ToArray()))
  }

  # ---- viewer error log ----
  $errPath = Join-Path $FixtureDir 'viewer-errors.log'
  if (Test-Path -LiteralPath $errPath) {
    $errLines = @([System.IO.File]::ReadAllLines($errPath, [System.Text.Encoding]::UTF8))
    $unexpected = @($errLines | Where-Object { $_ -and ($_ -notlike '*simulated display failure*') })
    if ($unexpected.Count -eq 0) {
      Add-Check $checks 'viewer-errors.log' 'NA' ($errLines.Count.ToString() + ' line(s), all simulated display failures')
    }
    else {
      Add-Check $checks 'viewer-errors.log' 'WARN' ($unexpected.Count.ToString() + ' unexpected line(s); first: ' + $unexpected[0])
    }
  }

  $failCount = 0
  $warnCount = 0
  foreach ($c in $checks) {
    if ($c.Status -eq 'FAIL') { $failCount++ }
    elseif ($c.Status -eq 'WARN') { $warnCount++ }
  }
  $overall = 'PASS'
  if ($failCount -gt 0) { $overall = 'FAIL' }
  return [pscustomobject]@{ Checks = $checks; FailCount = $failCount; WarnCount = $warnCount; Overall = $overall }
}

function Write-CheckTable {
  param($Result)
  foreach ($c in $Result.Checks) {
    $color = 'Gray'
    if ($c.Status -eq 'PASS') { $color = 'Green' }
    elseif ($c.Status -eq 'FAIL') { $color = 'Red' }
    elseif ($c.Status -eq 'WARN') { $color = 'Yellow' }
    Write-Host ('{0,-4} {1,-46} {2}' -f $c.Status, $c.Name, $c.Detail) -ForegroundColor $color
  }
  $color = 'Green'
  if ($Result.Overall -eq 'FAIL') { $color = 'Red' }
  Write-Host ('== overall: {0} ({1} fail, {2} warn)' -f $Result.Overall, $Result.FailCount, $Result.WarnCount) -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Self-test: synthetic fixtures
# ---------------------------------------------------------------------------

function Save-JsonFile {
  param([string]$Path, $Obj)
  $json = ConvertTo-Json -InputObject $Obj -Depth 12
  [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function New-SyntheticFixture {
  param([string]$Dir)
  if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force }
  New-Item -ItemType Directory -Path $Dir -Force | Out-Null

  $specs = @(
    @{ runId = 'iso-0001'; scenario = 'isolation'; complete = $true;  status = 'completed'; cap = $false; sentinel = 'RUN-SENTINEL-01'; maxGap = 50.0;  p95 = 40.0;  maxLat = 80.0;  detached = $false },
    @{ runId = 'volu-0001'; scenario = 'volume';   complete = $true;  status = 'completed'; cap = $false; sentinel = $null;              maxGap = 120.0; p95 = 900.0; maxLat = 1500.0; detached = $false },
    @{ runId = 'clos-0001'; scenario = 'closure';  complete = $true;  status = 'completed'; cap = $false; sentinel = $null;              maxGap = 60.0;  p95 = 50.0;  maxLat = 90.0;  detached = $true },
    @{ runId = 'cap-0001';  scenario = 'capturefail'; complete = $false; status = $null;    cap = $true;  sentinel = $null;              maxGap = 30.0;  p95 = 20.0;  maxLat = 40.0;  detached = $false }
  )

  $manifestRuns = New-Object 'System.Collections.Generic.List[object]'
  $reportRuns = New-Object 'System.Collections.Generic.List[object]'
  $notifications = New-Object 'System.Collections.Generic.List[string]'
  $counts = @{}

  foreach ($s in $specs) {
    $runId = [string]$s.runId
    $journalName = $runId + '.journal.jsonl'
    $journalPath = Join-Path $Dir $journalName
    $records = New-Object 'System.Collections.Generic.List[object]'
    $records.Add([pscustomobject][ordered]@{ seq = 1; ts = 1000; ch = 'meta'; kind = 'launch'; data = ('pi -p "synthetic ' + $runId + '" --mode json') })
    $sessionData = '{"type":"session","id":"' + $runId + '"'
    if (-not [string]::IsNullOrEmpty([string]$s.sentinel)) { $sessionData += ',"sentinel":"' + [string]$s.sentinel + '"' }
    $sessionData += '}'
    $records.Add([pscustomobject][ordered]@{ seq = 2; ts = 1001; ch = 'stdout'; data = $sessionData })
    $terminalObj = $null
    if ($s.cap) {
      $records.Add([pscustomobject][ordered]@{ seq = 3; ts = 1002; ch = 'meta'; kind = 'captureError'; message = 'synthetic capture failure'; data = 'synthetic capture failure for ' + $runId })
    }
    else {
      $termData = '{"exitCode":0,"signal":null,"status":"' + [string]$s.status + '"}'
      $records.Add([pscustomobject][ordered]@{ seq = 3; ts = 1002; ch = 'meta'; kind = 'terminal'; status = [string]$s.status; exitCode = 0; signal = $null; data = $termData })
      $terminalObj = [pscustomobject][ordered]@{ status = [string]$s.status; exitCode = 0; signal = $null }
    }

    $journalLines = New-Object 'System.Collections.Generic.List[string]'
    $dataList = New-Object 'System.Collections.Generic.List[string]'
    $renderedLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rec in $records) {
      [void]$journalLines.Add((ConvertTo-Json -InputObject $rec -Compress -Depth 8))
      [void]$dataList.Add([string]$rec.data)
      if ([string]$rec.ch -eq 'meta' -and [string]$rec.kind -eq 'launch') {
        [void]$renderedLines.Add('== launch: ' + [string]$rec.data)
      }
      elseif ([string]$rec.ch -eq 'stdout') {
        [void]$renderedLines.Add('== session')
        [void]$renderedLines.Add('   id: ' + $runId)
        if (-not [string]::IsNullOrEmpty([string]$s.sentinel)) { [void]$renderedLines.Add('   sentinel: ' + [string]$s.sentinel) }
      }
      elseif ([string]$rec.ch -eq 'meta' -and [string]$rec.kind -eq 'captureError') {
        [void]$renderedLines.Add('!! capture error: ' + [string]$rec.data)
      }
      else {
        [void]$renderedLines.Add('== terminal status=' + [string]$rec.status + ' exit=0 signal=null')
      }
    }
    [System.IO.File]::WriteAllLines($journalPath, $journalLines.ToArray(), $utf8NoBom)
    $rawJoined = [string]::Join("`n", $dataList.ToArray())
    $rawHash = Get-Sha256Hex -Text $rawJoined

    $text = [string]::Join([Environment]::NewLine, $renderedLines.ToArray()) + [Environment]::NewLine
    $textPath = Join-Path $Dir ($runId + '.rendered.txt')
    [System.IO.File]::WriteAllText($textPath, $text, $utf8NoBom)

    $manifestRuns.Add([pscustomobject][ordered]@{
      runId               = $runId
      journal             = $journalName
      scenario            = [string]$s.scenario
      emittedCount        = $records.Count
      lastSeq             = $records.Count
      rawSha256           = $rawHash
      terminal            = $terminalObj
      uniqueSentinel      = $s.sentinel
      generatorFinishedAt = 2000
    })

    $reportRuns.Add([pscustomobject][ordered]@{
      runId             = $runId
      scenario          = [string]$s.scenario
      replayedCount     = 2
      tailedCount       = 1
      renderedCount     = $records.Count
      lastSeq           = $records.Count
      receivedOrderOk   = $true
      rawSha256         = $rawHash
      textLength        = $text.Length
      textSha256        = (Get-Sha256Hex -Text $text)
      terminal          = (-not [bool]$s.cap)
      status            = $s.status
      incomplete        = [bool]$s.cap
      captureError      = [bool]$s.cap
      displayError      = $null
      notified          = (-not [bool]$s.cap)
      maxLatencyMs      = [int]$s.maxLat
      p95LatencyMs      = [int]$s.p95
      maxHeartbeatGapMs = [int]$s.maxGap
      formDetached      = [bool]$s.detached
      windowTitle       = $(if ($s.cap) { 'Run ' + $runId + ' - incomplete (capture error)' } else { 'Run ' + $runId + ' - ' + [string]$s.status })
    })
    if (-not $s.cap) {
      [void]$notifications.Add($runId)
      $counts[$runId] = 1
    }
  }

  $manifest = [pscustomobject][ordered]@{
    tool          = 'verify-prototype-selftest'
    scenario      = 'synthetic'
    generatedAt   = 3000
    requestedRuns = $specs.Count
    runs          = $manifestRuns
  }
  $report = [pscustomobject][ordered]@{
    tool              = 'verify-prototype-selftest'
    startedAt         = 1
    endedAt           = 2
    headless          = $true
    ticks             = 10
    maxHeartbeatGapMs = 120
    notifications     = @($notifications)
    notificationCounts = $counts
    displayFonts      = [pscustomobject][ordered]@{ base = 'Cascadia Mono'; cjk = 'Microsoft YaHei UI'; hangul = 'Malgun Gothic'; emoji = 'Segoe UI Emoji'; rtl = 'Segoe UI'; math = 'Segoe UI Symbol'; symbol = 'Segoe UI Symbol' }
    displayFontDetails = [pscustomobject][ordered]@{
      base    = [pscustomobject][ordered]@{ font = 'Cascadia Mono'; sampleMissing = @(); resolved = $true; glyphCount = 2426; typefaceCount = 1; error = '' }
      cjk     = [pscustomobject][ordered]@{ font = 'Microsoft YaHei UI'; sampleMissing = @(); resolved = $true; glyphCount = 29905; typefaceCount = 1; error = '' }
      hangul  = [pscustomobject][ordered]@{ font = 'Malgun Gothic'; sampleMissing = @(); resolved = $true; glyphCount = 27133; typefaceCount = 1; error = '' }
      emoji   = [pscustomobject][ordered]@{ font = 'Segoe UI Emoji'; sampleMissing = @(); resolved = $true; glyphCount = 2025; typefaceCount = 1; error = '' }
      rtl     = [pscustomobject][ordered]@{ font = 'Segoe UI'; sampleMissing = @(); resolved = $true; glyphCount = 3996; typefaceCount = 1; error = '' }
      math    = [pscustomobject][ordered]@{ font = 'Segoe UI Symbol'; sampleMissing = @(); resolved = $true; glyphCount = 7536; typefaceCount = 1; error = '' }
      symbol  = [pscustomobject][ordered]@{ font = 'Segoe UI Symbol'; sampleMissing = @(); resolved = $true; glyphCount = 7536; typefaceCount = 1; error = '' }
    }
    fontFamiliesResolved = 5
    fontCache         = [pscustomobject][ordered]@{
      'Cascadia Mono'    = [pscustomobject][ordered]@{ resolved = $true; glyphCount = 2426; typefaceCount = 1 }
      'Microsoft YaHei UI' = [pscustomobject][ordered]@{ resolved = $true; glyphCount = 29905; typefaceCount = 1 }
      'Malgun Gothic'    = [pscustomobject][ordered]@{ resolved = $true; glyphCount = 27133; typefaceCount = 1 }
      'Segoe UI Emoji'   = [pscustomobject][ordered]@{ resolved = $true; glyphCount = 2025; typefaceCount = 1 }
      'Segoe UI Symbol'  = [pscustomobject][ordered]@{ resolved = $true; glyphCount = 7536; typefaceCount = 1 }
      'Segoe UI'         = [pscustomobject][ordered]@{ resolved = $true; glyphCount = 3996; typefaceCount = 1 }
    }
    runs              = $reportRuns
  }
  Save-JsonFile -Path (Join-Path $Dir 'manifest.json') -Obj $manifest
  Save-JsonFile -Path (Join-Path $Dir 'report.json') -Obj $report
}

function Invoke-VerifySelfTest {
  $root = Join-Path $PSScriptRoot '_out\verify-selftest'
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  $failures = New-Object 'System.Collections.Generic.List[string]'

  function Invoke-AssertCase {
    param([string]$CaseLabel, [string]$Dir, [string]$ExpectedOverall, [string]$ExpectedCheckPart, [string]$ExpectedCheckStatus)
    $res = Invoke-Verification -FixtureDir $Dir
    $ok = ($res.Overall -ceq $ExpectedOverall)
    $detail = 'overall=' + $res.Overall
    if ($ok -and -not [string]::IsNullOrEmpty($ExpectedCheckPart)) {
      $found = $false
      foreach ($c in $res.Checks) {
        if ($c.Name -like ('*' + $ExpectedCheckPart + '*') -and $c.Status -ceq $ExpectedCheckStatus) { $found = $true; break }
      }
      $ok = $found
      $detail = $detail + ' check(' + $ExpectedCheckPart + ' -> ' + $ExpectedCheckStatus + ')=' + $found
    }
    if ($ok) {
      Write-Host ('case {0}: PASS ({1})' -f $CaseLabel, $detail) -ForegroundColor Green
    }
    else {
      Write-Host ('case {0}: FAIL ({1})' -f $CaseLabel, $detail) -ForegroundColor Red
      [void]$failures.Add($CaseLabel)
    }
  }

  $good = Join-Path $root 'good'
  New-SyntheticFixture -Dir $good
  Invoke-AssertCase -CaseLabel 'good-pass' -Dir $good -ExpectedOverall 'PASS' -ExpectedCheckPart '' -ExpectedCheckStatus ''

  $case = Join-Path $root 'fail-hash'
  Copy-Item -LiteralPath $good -Destination $case -Recurse -Force
  $rep = Read-JsonFile -Path (Join-Path $case 'report.json')
  $rep.runs[0].rawSha256 = ('0' * 64)
  Save-JsonFile -Path (Join-Path $case 'report.json') -Obj $rep
  Invoke-AssertCase -CaseLabel 'fail-hash' -Dir $case -ExpectedOverall 'FAIL' -ExpectedCheckPart 'rawSha256' -ExpectedCheckStatus 'FAIL'

  $case = Join-Path $root 'fail-lossless'
  Copy-Item -LiteralPath $good -Destination $case -Recurse -Force
  $rep = Read-JsonFile -Path (Join-Path $case 'report.json')
  $journalLines = [System.IO.File]::ReadAllLines((Join-Path $case 'iso-0001.journal.jsonl'), [System.Text.Encoding]::UTF8)
  $records = @()
  foreach ($ln in $journalLines) { if ($ln) { $records += ,(ConvertFrom-Json -InputObject $ln) } }
  $text = '== meta seq=1' + [Environment]::NewLine + '   raw: ' + [string]$records[0].data + [Environment]::NewLine
  [System.IO.File]::WriteAllText((Join-Path $case 'iso-0001.rendered.txt'), $text, $utf8NoBom)
  $isoReport = $rep.runs | Where-Object { $_.runId -eq 'iso-0001' }
  $isoReport.textLength = $text.Length
  $isoReport.textSha256 = Get-Sha256Hex -Text $text
  Save-JsonFile -Path (Join-Path $case 'report.json') -Obj $rep
  Invoke-AssertCase -CaseLabel 'fail-lossless' -Dir $case -ExpectedOverall 'FAIL' -ExpectedCheckPart 'payloads' -ExpectedCheckStatus 'FAIL'

  $case = Join-Path $root 'fail-notify-twice'
  Copy-Item -LiteralPath $good -Destination $case -Recurse -Force
  $rep = Read-JsonFile -Path (Join-Path $case 'report.json')
  $rep.notificationCounts.PSObject.Properties['iso-0001'].Value = 2
  $rep.notifications = @($rep.notifications) + @('iso-0001')
  Save-JsonFile -Path (Join-Path $case 'report.json') -Obj $rep
  Invoke-AssertCase -CaseLabel 'fail-notify-twice' -Dir $case -ExpectedOverall 'FAIL' -ExpectedCheckPart 'completion' -ExpectedCheckStatus 'FAIL'

  $case = Join-Path $root 'fail-capturefail-notified'
  Copy-Item -LiteralPath $good -Destination $case -Recurse -Force
  $rep = Read-JsonFile -Path (Join-Path $case 'report.json')
  $cap = $rep.runs | Where-Object { $_.runId -eq 'cap-0001' }
  $cap.notified = $true
  $rep.notifications = @($rep.notifications) + @('cap-0001')
  $rep.notificationCounts | Add-Member -NotePropertyName 'cap-0001' -NotePropertyValue 1
  Save-JsonFile -Path (Join-Path $case 'report.json') -Obj $rep
  Invoke-AssertCase -CaseLabel 'fail-capturefail-notified' -Dir $case -ExpectedOverall 'FAIL' -ExpectedCheckPart 'capture' -ExpectedCheckStatus 'FAIL'

  $case = Join-Path $root 'fail-threshold'
  Copy-Item -LiteralPath $good -Destination $case -Recurse -Force
  $rep = Read-JsonFile -Path (Join-Path $case 'report.json')
  $vol = $rep.runs | Where-Object { $_.runId -eq 'volu-0001' }
  $vol.maxHeartbeatGapMs = 900
  Save-JsonFile -Path (Join-Path $case 'report.json') -Obj $rep
  Invoke-AssertCase -CaseLabel 'fail-threshold' -Dir $case -ExpectedOverall 'FAIL' -ExpectedCheckPart 'heartbeat' -ExpectedCheckStatus 'FAIL'

  $case = Join-Path $root 'fail-missing-run'
  Copy-Item -LiteralPath $good -Destination $case -Recurse -Force
  $rep = Read-JsonFile -Path (Join-Path $case 'report.json')
  $rep.runs = @($rep.runs | Where-Object { $_.runId -ne 'cap-0001' })
  Save-JsonFile -Path (Join-Path $case 'report.json') -Obj $rep
  Invoke-AssertCase -CaseLabel 'fail-missing-run' -Dir $case -ExpectedOverall 'FAIL' -ExpectedCheckPart 'run-set' -ExpectedCheckStatus 'FAIL'

  $case = Join-Path $root 'warn-detached'
  Copy-Item -LiteralPath $good -Destination $case -Recurse -Force
  $rep = Read-JsonFile -Path (Join-Path $case 'report.json')
  $clos = $rep.runs | Where-Object { $_.runId -eq 'clos-0001' }
  $clos.formDetached = $false
  Save-JsonFile -Path (Join-Path $case 'report.json') -Obj $rep
  Invoke-AssertCase -CaseLabel 'warn-detached' -Dir $case -ExpectedOverall 'PASS' -ExpectedCheckPart 'closure-detached' -ExpectedCheckStatus 'WARN'

  if ($failures.Count -eq 0) {
    Write-Host 'VERIFY SELFTEST PASS' -ForegroundColor Green
    return 0
  }
  Write-Host ('VERIFY SELFTEST FAIL: ' + [string]::Join(', ', $failures.ToArray())) -ForegroundColor Red
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($SelfTest) {
  exit (Invoke-VerifySelfTest)
}

if ([string]::IsNullOrWhiteSpace($FixtureDir)) {
  throw '-FixtureDir is required unless -SelfTest is used.'
}
$FixtureDir = (Resolve-Path -LiteralPath $FixtureDir).Path

$result = Invoke-Verification -FixtureDir $FixtureDir -ManifestPath $ManifestPath -ReportPath $ReportPath
if (-not $Quiet) {
  Write-Host ('== verification fixture=' + $FixtureDir)
  Write-CheckTable -Result $result
}

if ($result.Overall -eq 'FAIL') { exit 1 }
exit 0
