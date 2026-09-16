#requires -Version 5.1
<#
  run-prototype.ps1 - one-command human launcher (ticket 03 prototype).

  Sequence
  --------
    1. wipes and recreates prototype\_out
    2. starts fixture-generator.ps1 as a hidden background process with
       -Stream (volume stays unpaced by design) and redirected logs; the
       generator writes the journal preambles, creates gate.ready and waits
       for the viewer's gate.go
    3. waits for gate.ready (first-journal/readiness signal, NOT the final
       manifest) and starts per-run-window.ps1 while journals are still
       being appended; the viewer opens every journal, writes gate.go and
       starts replaying/tailing. The generator then pauses
       -GatePostSleepMs so replay completes before the paced bodies start.
    4. waits for the human to close the Run windows; the last close makes
       the viewer write report.json and <runId>.rendered.txt files
    5. waits for the generator to finish (capture keeps running even after
       every window is closed) and then runs verify-prototype.ps1

  -Headless replaces step 4 with an automated, bounded concurrent run: the
  same generator/gate handshake, but the viewer runs with -Headless (no
  Forms, -WindowStyle Hidden) and exits once every Run has settled and the
  generator manifest is on disk. This is the replay+tail validation path;
  it never shows a window.

  Exit code is the verifier's (1 = FAIL, 0 = PASS).

  The human launch command (from the repository root):
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File ".scratch\pi-subagent-slimming\prototype\run-prototype.ps1" -Scenario all -Runs 4

  Examples
  --------
    ... run-prototype.ps1 -Scenario all -Runs 4
    ... run-prototype.ps1 -Scenario volume -VolumeEvents 50000
    ... run-prototype.ps1 -Scenario happy
    ... run-prototype.ps1 -Headless -Scenario all -Runs 4 -VolumeEvents 200 -Rate 200
#>
[CmdletBinding()]
param(
  [ValidateSet('happy', 'volume', 'unicode', 'isolation', 'closure', 'windowfail', 'capturefail', 'duplicate', 'all')]
  [string]$Scenario = 'all',

  [ValidateRange(1, 16)]
  [int]$Runs = 4,

  [ValidateRange(0, 100000)]
  [int]$Rate = 0,

  [ValidateRange(1, 500000)]
  [int]$VolumeEvents = 50000,

  [int]$Seed = 0,

  [ValidateRange(10, 2000)]
  [int]$TickMs = 50,

  [ValidateRange(1, 20000)]
  [int]$BatchLines = 1000,

  # Bounded pause after the viewer's gate.go so the viewer has replayed the
  # preambles before the paced bodies arrive (guarantees replayedCount > 0
  # AND tailedCount > 0). 0 disables the pause.
  [ValidateRange(0, 60000)]
  [int]$GatePostSleepMs = 2000,

  [ValidateRange(5000, 3600000)]
  [int]$HeadlessTimeoutMs = 300000,

  [switch]$Headless,

  [switch]$NoVerify
)

$ErrorActionPreference = 'Stop'

function Quote-ProcessArg {
  param([string]$Value)
  if ($Value -match '[\s"]') {
    return '"' + ($Value -replace '"', '\"') + '"'
  }
  return $Value
}

function Quote-PsLiteral {
  param([string]$Value)
  return "'" + ($Value -replace "'", "''") + "'"
}

$prototypeDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($prototypeDir)) {
  throw 'Unable to resolve $PSScriptRoot; run this script from a file.'
}
$out = Join-Path $prototypeDir '_out'
$outFull = [System.IO.Path]::GetFullPath($out)
if (-not $outFull.StartsWith([System.IO.Path]::GetFullPath($prototypeDir), [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "refusing to clean unexpected output directory: $outFull"
}

$generatorScript = Join-Path $prototypeDir 'fixture-generator.ps1'
$viewerScript = Join-Path $prototypeDir 'per-run-window.ps1'
$verifyScript = Join-Path $prototypeDir 'verify-prototype.ps1'
foreach ($required in @($generatorScript, $viewerScript, $verifyScript)) {
  if (-not (Test-Path -LiteralPath $required)) { throw "missing script: $required" }
}

Write-Host '=============================================================='
Write-Host ' per-Run window prototype (ticket 03)'
Write-Host '=============================================================='
Write-Host (' scenario       : {0}' -f $Scenario)
Write-Host (' runs           : {0}' -f $Runs)
Write-Host (' volumeEvents   : {0} (volume scenario stays unpaced unless -Rate is set)' -f $VolumeEvents)
Write-Host (' output dir     : {0}' -f $outFull)
if ($Headless) { Write-Host ' mode           : headless concurrent validation (no windows)' }
Write-Host ''
if (-not $Headless) {
  Write-Host ' HUMAN LAUNCH (exact command):'
  Write-Host ('   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Scenario {1} -Runs {2}' -f $PSCommandPath, $Scenario, $Runs)
  Write-Host ''
  Write-Host ' HUMAN VISUAL CHECKS:'
  Write-Host '  1. Titles: every window title starts with "Run <full runId> - " (no truncated ids).'
  Write-Host '  2. Unicode: CJK, Hangul, emoji ZWJ family, combining marks, RTL Arabic/Hebrew and'
  Write-Host '     astral math symbols render legibly (no boxes, no tofu).'
  Write-Host '  3. Recognised events: one formatted block per event ("== <type>" plus indented'
  Write-Host '     fields) with NO second raw JSON copy underneath.'
  Write-Host '  4. Unknown/malformed/stderr records stay visible verbatim ("? [event ...]",'
  Write-Host '     "? [unparsed ...]", "! stderr: ...") so nothing is silently dropped.'
  Write-Host '  5. Close ONE still-running window mid-stream; its Run keeps capturing in the'
  Write-Host '     background while the other windows keep growing.'
  Write-Host '  6. Exactly one completion notification per completed Run (duplicate terminal'
  Write-Host '     records must not notify twice); completed windows stay open until closed.'
  Write-Host '  7. Keep every window open until all Runs are terminal/incomplete, then close all;'
  Write-Host '     the last close writes report.json and runs the verifier automatically.'
  Write-Host ''
}

if (Test-Path -LiteralPath $out) {
  Get-ChildItem -LiteralPath $out -Force | Remove-Item -Recurse -Force
}
else {
  New-Item -ItemType Directory -Path $out -Force | Out-Null
}

$reportPath = Join-Path $out 'report.json'
$genOutLog = Join-Path $out 'generator.stdout.log'
$genErrLog = Join-Path $out 'generator.stderr.log'
$genExitFile = Join-Path $out 'generator.exitcode.txt'

# Windows PowerShell 5.1 loses the process exit code when Start-Process is
# combined with -PassThru and redirected output, so the generator is invoked
# through a tiny generated wrapper that records $LASTEXITCODE itself.
$genScriptArgLine = @(
  '-OutDir', (Quote-PsLiteral $outFull)
  '-Scenario', (Quote-PsLiteral $Scenario)
  '-Runs', ([string]$Runs)
  '-VolumeEvents', ([string]$VolumeEvents)
  '-Seed', ([string]$Seed)
  '-Rate', ([string]$Rate)
  '-GatePostSleepMs', ([string]$GatePostSleepMs)
  '-Stream'
) -join ' '
$genWrapper = Join-Path $outFull '_run-generator.ps1'
$wrapperLines = @(
  '# generated by run-prototype.ps1; runs the fixture generator and records its exit code'
  '$ErrorActionPreference = ''Continue'''
  '$genCode = 0'
  ('& ' + (Quote-PsLiteral $generatorScript) + ' ' + $genScriptArgLine)
  'if (-not $?) { $genCode = 1 }'
  'if (($LASTEXITCODE -is [int]) -and ($LASTEXITCODE -ne 0)) { $genCode = $LASTEXITCODE }'
  ('[System.IO.File]::WriteAllText(' + (Quote-PsLiteral $genExitFile) + ', [string]$genCode)')
  'exit $genCode'
)
[System.IO.File]::WriteAllLines($genWrapper, [string[]]$wrapperLines, (New-Object System.Text.UTF8Encoding($false)))

$genArgLine = @(
  '-NoProfile'
  '-ExecutionPolicy', 'Bypass'
  '-File', (Quote-ProcessArg $genWrapper)
) -join ' '

Write-Host '[run-prototype] starting fixture generator (hidden background process)...'
$gen = Start-Process -FilePath 'powershell.exe' -ArgumentList $genArgLine -WindowStyle Hidden -PassThru -RedirectStandardOutput $genOutLog -RedirectStandardError $genErrLog

$gatePath = Join-Path $outFull 'gate.ready'
$gateDeadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath $gatePath)) {
  if ($gen.HasExited) {
    $earlyCode = 'unknown'
    if (Test-Path -LiteralPath $genExitFile) { $earlyCode = (Get-Content -LiteralPath $genExitFile -Raw).Trim() }
    Write-Warning ('generator exited early (exit ' + $earlyCode + '); see ' + $genErrLog)
    break
  }
  if ([DateTime]::UtcNow -gt $gateDeadline) {
    Write-Warning 'gate.ready was not seen within 30s; launching the viewer anyway.'
    break
  }
  Start-Sleep -Milliseconds 200
}
if (Test-Path -LiteralPath $gatePath) {
  Write-Host '[run-prototype] journal preambles are on disk; starting the viewer.'
}

$viewerArgList = @(
  '-NoProfile'
  '-STA'
  '-ExecutionPolicy', 'Bypass'
  '-File', (Quote-ProcessArg $viewerScript)
  '-FixtureDir', (Quote-ProcessArg $outFull)
  '-ReportPath', (Quote-ProcessArg $reportPath)
  '-TickMs', ([string]$TickMs)
  '-BatchLines', ([string]$BatchLines)
)
if ($Headless) {
  $viewerArgList += @('-Headless', '-HeadlessTimeoutMs', ([string]$HeadlessTimeoutMs))
}
$viewerArgLine = $viewerArgList -join ' '

if (-not $Headless) {
  Write-Host ''
  Write-Host '--------------------------------------------------------------'
  Write-Host ' HUMAN: one read-only window per Run is now open.'
  Write-Host ' Follow the HUMAN VISUAL CHECKS printed above (titles, Unicode,'
  Write-Host ' formatted events, raw fallbacks, one mid-stream close, exactly'
  Write-Host ' one completion notification per completed Run).'
  Write-Host ' The last window close writes report.json and runs the verifier.'
  Write-Host '--------------------------------------------------------------'
  Write-Host ''
}
else {
  Write-Host ''
  Write-Host '[run-prototype] headless validation: the viewer replays and tails in a hidden process; no window is shown.'
  Write-Host ''
}

$viewer = $null
if ($Headless) {
  $viewer = Start-Process -FilePath 'powershell.exe' -ArgumentList $viewerArgLine -WindowStyle Hidden -PassThru
}
else {
  $viewer = Start-Process -FilePath 'powershell.exe' -ArgumentList $viewerArgLine -PassThru
}
$viewer.WaitForExit()
Write-Host ('[run-prototype] viewer exited (exit ' + $viewer.ExitCode + ').')
if ($viewer.ExitCode -ne 0) { Write-Warning ('viewer exited non-zero: ' + $viewer.ExitCode) }

if (-not $gen.HasExited) {
  Write-Host '[run-prototype] waiting for the generator to finish capture...'
  $finished = $gen.WaitForExit(900000)
  if (-not $finished) {
    Write-Warning 'generator still running after 900s; continuing to verification.'
  }
}
$genExitCode = $null
if (Test-Path -LiteralPath $genExitFile) {
  $genExitText = (Get-Content -LiteralPath $genExitFile -Raw).Trim()
  if ($genExitText -match '^-?\d+$') { $genExitCode = [int]$genExitText }
}
if ($null -ne $genExitCode) {
  Write-Host ('[run-prototype] generator exit code: ' + $genExitCode)
  if ($genExitCode -ne 0) { Write-Warning ('generator exited non-zero: ' + $genExitCode + '; see ' + $genErrLog) }
}
else {
  Write-Warning ('generator exit code was not recorded; see ' + $genOutLog + ' and ' + $genErrLog)
}

$manifestPath = Join-Path $outFull 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
  Write-Warning 'manifest.json is missing; the generator did not finish a full scenario.'
}

if ($NoVerify) {
  Write-Host '[run-prototype] -NoVerify set; skipping verification.'
  exit 0
}

Write-Host ''
Write-Host '[run-prototype] verifying...'
& $verifyScript -FixtureDir $outFull -ReportPath $reportPath
$verifyCode = $LASTEXITCODE

$verdict = 'verifier FAIL'
if ($verifyCode -eq 0) { $verdict = 'verifier PASS' }
Write-Host ''
Write-Host '=============================================================='
Write-Host (' HUMAN LAUNCH: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Scenario {1} -Runs {2}' -f (Join-Path '.scratch\pi-subagent-slimming\prototype' 'run-prototype.ps1'), $Scenario, $Runs)
Write-Host (' artifacts   : {0}' -f $outFull)
Write-Host (' verdict     : {0}' -f $verdict)
Write-Host '=============================================================='
exit $verifyCode
