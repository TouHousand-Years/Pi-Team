#requires -Version 5.1
<#
  fixture-generator.ps1 - synthetic NDJSON journal generator (ticket 03 prototype).

  Purpose
  -------
  Writes one journal per synthetic Run under -OutDir, exactly like the real
  post-run fixture schema described in _prototype-exploration.md sections 5
  and 6: one JSON object per line, UTF-8 without BOM, LF-terminated, flushed
  per record so an independent reader can replay and tail the file.

  Journal record schema (prototype)
  ---------------------------------
  Every record carries a verbatim "data" string (the raw upstream line for
  stdout/stderr, a command line for kind=launch, a compact JSON payload for
  kind=terminal, the failure text for kind=captureError). Terminal records
  additionally carry top-level status/exitCode/signal. This lets the viewer
  and the verifier recompute rawSha256 over exactly what the viewer received:
  all data values joined with LF, hashed as UTF-8.

  Files written into -OutDir
  --------------------------
    <runId>.journal.jsonl     one record per line
    force-display-error.txt   (windowfail only) names one runId the viewer must
                              fail to render once, then recover
    gate.ready                written after every journal preamble exists
    manifest.json             written only after every journal is complete
    gate.go                   created by the viewer (not by this script)

  Gate handshake (prototype determinism)
  --------------------------------------
  After writing every journal's two preamble records (launch + session) this
  script creates gate.ready and waits (bounded by -GateWaitMs) for the viewer
  to drop gate.go after it has opened the journals. Only then are record
  bodies streamed. That guarantees replayedCount > 0 and tailedCount > 0 for
  every Run. -GatePostSleepMs adds one more bounded pause after gate.go is
  observed, so the viewer has finished replaying the preambles before any
  paced body record is written (headless concurrent validation relies on
  this). Set -GateWaitMs 0 to disable the handshake.

  Pacing
  ------
  -Stream paces every scenario in small sleeps EXCEPT volume. Volume is the
  unbounded throughput fixture and stays unpaced (or honors -Rate); pacing it
  would defeat the responsiveness test. This exception is deliberate.

  Examples
  --------
    powershell -NoProfile -ExecutionPolicy Bypass -File fixture-generator.ps1 `
      -OutDir .\prototype\_out -Scenario all -Runs 4 -Stream
    powershell -NoProfile -ExecutionPolicy Bypass -File fixture-generator.ps1 `
      -OutDir .\prototype\_out -Scenario volume -VolumeEvents 200 -GateWaitMs 0
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$OutDir,

  [ValidateSet('happy', 'volume', 'unicode', 'isolation', 'closure', 'windowfail', 'capturefail', 'duplicate', 'all')]
  [string]$Scenario = 'all',

  [ValidateRange(1, 16)]
  [int]$Runs = 4,

  [switch]$Stream,

  [ValidateRange(0, 100000)]
  [int]$Rate = 0,

  [ValidateRange(1, 500000)]
  [int]$VolumeEvents = 50000,

  [int]$Seed = 0,

  [ValidateRange(0, 600000)]
  [int]$GateWaitMs = 60000,

  [ValidateRange(0, 60000)]
  [int]$GatePostSleepMs = 0,

  [ValidateRange(0, 1000)]
  [int]$StreamIntervalMs = 5
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

# Torture string built from a base64 UTF-8 payload so this script stays pure
# ASCII (Windows PowerShell 5.1 misreads BOM-less UTF-8 sources as ANSI).
# Decodes to: CJK + Korean + emoji (incl. a ZWJ family) + combining marks +
# RTL Arabic/Hebrew + astral math letters + backslash + double quote.
$TortureBase64 = '5Lit5paHIOaXpeacrOiqniDtlZzqta3slrQg8J+YgPCfjonwn5Go4oCN8J+RqeKAjfCfkafigI3wn5GmIGXMgSBhzIAg2YXYsdit2KjYpyDXqdec15XXnSDwnZSY8J2Uq/CdlKbwnZSg8J2UrPCdlKHwnZSiIFwgIg=='

$script:runStates = New-Object 'System.Collections.Generic.List[object]'
$script:stateByRunId = @{}
$script:startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

function Get-NowMs {
  return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Get-TortureString {
  return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($TortureBase64))
}

function New-RunState {
  param(
    [string]$RunId,
    [string]$ScenarioName,
    [bool]$Paced,
    [int]$RateLimit,
    [string]$Sentinel
  )
  $journal = Join-Path $OutDir ($RunId + '.journal.jsonl')
  $fs = New-Object System.IO.FileStream($journal, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
  $sw = New-Object System.IO.StreamWriter($fs, $utf8)
  $sw.AutoFlush = $true
  return @{
    runId             = $RunId
    scenario          = $ScenarioName
    journal           = $journal
    writer            = $sw
    seq               = 0
    dataList          = (New-Object 'System.Collections.Generic.List[string]')
    terminal          = $null
    uniqueSentinel    = $Sentinel
    generatorFinishedAt = $null
    rawSha256         = $null
    emittedCount      = 0
    lastSeq           = 0
    paced             = $Paced
    rate              = $RateLimit
    stopwatch         = [System.Diagnostics.Stopwatch]::StartNew()
    prompt            = "prototype run $RunId ($ScenarioName)"
  }
}

function Write-Record {
  param(
    [Parameter(Mandatory = $true)] $Run,
    [Parameter(Mandatory = $true)][string]$Ch,
    [Parameter(Mandatory = $true)][string]$Data,
    [string]$Kind,
    [System.Collections.IDictionary]$Extra
  )
  $Run.seq = $Run.seq + 1
  $rec = [ordered]@{
    seq = $Run.seq
    ts  = Get-NowMs
    ch  = $Ch
  }
  if (-not [string]::IsNullOrEmpty($Kind)) { $rec['kind'] = $Kind }
  if ($null -ne $Extra) {
    foreach ($k in $Extra.Keys) { $rec[$k] = $Extra[$k] }
  }
  $rec['data'] = $Data
  $line = ConvertTo-Json -InputObject ([pscustomobject]$rec) -Compress
  $Run.writer.WriteLine($line)
  [void]$Run.dataList.Add($Data)

  if ($Run.paced) {
    if ($StreamIntervalMs -gt 0) { Start-Sleep -Milliseconds $StreamIntervalMs }
  }
  elseif ($Run.rate -gt 0) {
    $elapsed = $Run.stopwatch.Elapsed.TotalSeconds
    $target = $Run.seq / [double]$Run.rate
    if ($elapsed -lt $target) {
      Start-Sleep -Milliseconds ([int](($target - $elapsed) * 1000.0))
    }
  }
}

function Write-Preamble {
  param($Run)
  $launch = 'pi -p "' + $Run.prompt + '" --mode json --session-id ' + $Run.runId +
            ' --provider mock --model mock-model --no-skills --no-context-files --tools bash'
  Write-Record -Run $Run -Ch 'meta' -Kind 'launch' -Data $launch

  $session = [pscustomobject][ordered]@{
    type      = 'session'
    version   = 3
    id        = $Run.runId
    timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    cwd       = 'C:\work\pi-subagent-prototype'
  }
  Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $session -Compress -Depth 10)
}

function Write-Terminal {
  param($Run, [string]$Status, [int]$ExitCode, $Signal)
  $payload = [pscustomobject][ordered]@{ status = $Status; exitCode = $ExitCode; signal = $Signal }
  $data = ConvertTo-Json -InputObject $payload -Compress
  $extra = [ordered]@{ status = $Status; exitCode = $ExitCode; signal = $Signal }
  Write-Record -Run $Run -Ch 'meta' -Kind 'terminal' -Data $data -Extra $extra
  $Run.terminal = [pscustomobject][ordered]@{ status = $Status; exitCode = $ExitCode; signal = $Signal }
}

function Write-CaptureError {
  param($Run, [string]$Message)
  $extra = [ordered]@{ message = $Message }
  Write-Record -Run $Run -Ch 'meta' -Kind 'captureError' -Data $Message -Extra $extra
}

function Complete-Run {
  param($Run)
  if ($null -ne $Run.writer) {
    $Run.writer.Flush()
    $Run.writer.Dispose()
    $Run.writer = $null
  }
  $joined = [string]::Join("`n", $Run.dataList.ToArray())
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))
  }
  finally {
    $sha.Dispose()
  }
  $Run.rawSha256 = ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
  $Run.emittedCount = $Run.seq
  $Run.lastSeq = $Run.seq
  $Run.generatorFinishedAt = Get-NowMs
}

# ---------------------------------------------------------------------------
# Scenario bodies
# ---------------------------------------------------------------------------

function Emit-HappyBody {
  param($Run)
  # Canonical 36-event sequence from _prototype-exploration.md section 4.1,
  # plus one stderr diagnostic, one unknown event and one malformed line.
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_start"}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_start"}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"Please run the echo command."}],"timestamp":"2026-01-01T00:00:00.000Z"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"Please run the echo command."}],"timestamp":"2026-01-01T00:00:00.001Z"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_start","message":{"role":"assistant","api":"mock","provider":"mockprovider","model":"mock-model","content":[{"type":"thinking","thinking":"Let me think about this."}],"usage":{"input":10,"output":1,"total":11},"stopReason":null,"timestamp":"2026-01-01T00:00:00.002Z"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":10,"output":1,"total":11},"assistantMessageEvent":{"type":"thinking_start","contentIndex":0}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":10,"output":3,"total":13},"assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"Let me think about this."}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":10,"output":6,"total":16},"assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"I should echo."}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":10,"output":6,"total":16},"assistantMessageEvent":{"type":"text_start","contentIndex":1}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":10,"output":10,"total":20},"assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"I will run "}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":10,"output":14,"total":24},"assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"echo now."}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":10,"output":16,"total":26},"assistantMessageEvent":{"type":"toolcall_start","contentIndex":2,"id":"call_1","toolName":"bash"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":10,"output":16,"total":26},"assistantMessageEvent":{"type":"toolcall_delta","contentIndex":2,"delta":""}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":10,"output":20,"total":30},"assistantMessageEvent":{"type":"toolcall_delta","contentIndex":2,"delta":"{\"command\":"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":10,"output":24,"total":34},"assistantMessageEvent":{"type":"toolcall_delta","contentIndex":2,"delta":"\"echo HI\"}"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":10,"output":28,"total":38},"assistantMessageEvent":{"type":"thinking_end","contentIndex":0,"content":"Let me think about this. I should echo."}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":10,"output":32,"total":42},"assistantMessageEvent":{"type":"text_end","contentIndex":1,"content":"I will run echo now."}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":10,"output":36,"total":46},"assistantMessageEvent":{"type":"toolcall_end","contentIndex":2,"toolCall":{"id":"call_1","name":"bash","arguments":{"command":"echo HI"}}}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me think about this. I should echo."},{"type":"text","text":"I will run echo now."},{"type":"toolCall","id":"call_1","name":"bash","arguments":{"command":"echo HI"}}],"stopReason":"toolUse","usage":{"input":10,"output":36,"total":46},"timestamp":"2026-01-01T00:00:01.000Z"}}'
  Write-Record -Run $Run -Ch 'stderr' -Data 'Could not parse message into JSON: {bad'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"tool_execution_start","toolCallId":"call_1","toolName":"bash","args":{"command":"echo HI"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"tool_execution_update","toolCallId":"call_1","toolName":"bash","args":{"command":"echo HI"},"partialResult":{"content":[{"type":"text","text":"HI\n"}],"details":{}}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"tool_execution_end","toolCallId":"call_1","toolName":"bash","result":{"content":[{"type":"text","text":"HI\n"}],"details":{}},"isError":false}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_start","message":{"role":"toolResult","toolCallId":"call_1","toolName":"bash","content":[{"type":"text","text":"HI\n"}],"isError":false,"timestamp":"2026-01-01T00:00:01.100Z"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_end","message":{"role":"toolResult","toolCallId":"call_1","toolName":"bash","content":[{"type":"text","text":"HI\n"}],"isError":false,"timestamp":"2026-01-01T00:00:01.101Z"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me think about this. I should echo."},{"type":"text","text":"I will run echo now."},{"type":"toolCall","id":"call_1","name":"bash","arguments":{"command":"echo HI"}}],"stopReason":"toolUse"},"toolResults":[{"role":"toolResult","toolCallId":"call_1","toolName":"bash","content":[{"type":"text","text":"HI\n"}],"isError":false}]}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_start"}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_start","message":{"role":"assistant","api":"mock","provider":"mockprovider","model":"mock-model","content":[],"usage":{"input":20,"output":0,"total":20},"stopReason":null,"timestamp":"2026-01-01T00:00:02.000Z"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":20,"output":0,"total":20},"assistantMessageEvent":{"type":"text_start","contentIndex":0}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":20,"output":3,"total":23},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"The command "}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":20,"output":7,"total":27},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"printed HI."}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","usage":{"input":20,"output":9,"total":29},"assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"The command printed HI."}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"The command printed HI."}],"stopReason":"stop","usage":{"input":20,"output":9,"total":29},"timestamp":"2026-01-01T00:00:02.500Z"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_end","message":{"role":"assistant","content":[{"type":"text","text":"The command printed HI."}],"stopReason":"stop"},"toolResults":[]}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"Please run the echo command."}]},{"role":"assistant","content":[{"type":"text","text":"I will run echo now."}]},{"role":"toolResult","toolName":"bash","content":[{"type":"text","text":"HI\n"}]},{"role":"assistant","content":[{"type":"text","text":"The command printed HI."}]}],"willRetry":false}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_settled"}'
  # Unknown future event: must stay visible, with its payload.
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"future_extension_event","payload":{"note":"unknown event kept visible","n":1}}'
  # Malformed upstream line: must stay visible verbatim.
  Write-Record -Run $Run -Ch 'stdout' -Data 'this is not json { truncated'
  Write-Terminal -Run $Run -Status 'completed' -ExitCode 0 -Signal $null
}

function Emit-VolumeBody {
  param($Run)
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_start"}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_start"}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":null}}'
  $base = ('The quick brown fox jumps over the lazy dog 0123456789 abcdefghijklmnopqrstuvwxyz ' * 3)
  for ($i = 1; $i -le $VolumeEvents; $i++) {
    $delta = ('{0:D6}:' -f $i) + $base.Substring(($i % 100), 110)
    $data = '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"' + $delta + '"}}'
    Write-Record -Run $Run -Ch 'stdout' -Data $data
  }
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":1,"content":"volume stream complete"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"volume stream complete"}],"stopReason":"stop"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_end","message":{"role":"assistant","stopReason":"stop"},"toolResults":[]}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_end","messages":[{"role":"assistant"}],"willRetry":false}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_settled"}'
  Write-Terminal -Run $Run -Status 'completed' -ExitCode 0 -Signal $null
}

function Emit-UnicodeBody {
  param($Run)
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_start"}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_start"}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":null}}'
  $torture = Get-TortureString
  $acc = New-Object System.Text.StringBuilder
  # 700 chunks x ~67 chars > 40,000 chars of verbatim Unicode payload.
  $count = 700
  for ($i = 1; $i -le $count; $i++) {
    $chunk = $torture + ' [' + $i + ']'
    [void]$acc.Append($chunk)
    $evt = [pscustomobject][ordered]@{
      type = 'message_update'
      assistantMessageEvent = [pscustomobject][ordered]@{ type = 'text_delta'; contentIndex = 1; delta = $chunk }
    }
    Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $evt -Compress -Depth 10)
  }
  $endEvt = [pscustomobject][ordered]@{
    type = 'message_update'
    assistantMessageEvent = [pscustomobject][ordered]@{ type = 'text_end'; contentIndex = 1; content = $acc.ToString() }
  }
  Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $endEvt -Compress -Depth 10)
  $endMsg = [pscustomobject][ordered]@{
    type = 'message_end'
    message = [pscustomobject][ordered]@{
      role = 'assistant'
      content = @([pscustomobject][ordered]@{ type = 'text'; text = $acc.ToString() })
      stopReason = 'stop'
    }
  }
  Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $endMsg -Compress -Depth 10)
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_end","message":{"role":"assistant","stopReason":"stop"},"toolResults":[]}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_end","messages":[{"role":"assistant"}],"willRetry":false}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_settled"}'
  Write-Terminal -Run $Run -Status 'completed' -ExitCode 0 -Signal $null
}

function Emit-IsolationBody {
  param($Run, [int]$Index)
  $sent = $Run.uniqueSentinel
  $unique = $Index * 7
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_start"}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_start"}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":null}}'

  $delta = "Isolation run $Index reporting; only this window may show $sent and payload marker unique-$unique."
  $evt = [pscustomobject][ordered]@{
    type = 'message_update'
    assistantMessageEvent = [pscustomobject][ordered]@{ type = 'text_delta'; contentIndex = 1; delta = $delta }
  }
  Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $evt -Compress -Depth 10)

  $start = [pscustomobject][ordered]@{
    type = 'tool_execution_start'; toolCallId = "call_$Index"; toolName = 'bash'
    args = [pscustomobject][ordered]@{ command = "echo $sent" }
  }
  Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $start -Compress -Depth 10)

  $partial = [pscustomobject][ordered]@{
    type = 'tool_execution_update'; toolCallId = "call_$Index"; toolName = 'bash'
    args = [pscustomobject][ordered]@{ command = "echo $sent" }
    partialResult = [pscustomobject][ordered]@{ content = @([pscustomobject][ordered]@{ type = 'text'; text = "$sent partial output" }); details = [pscustomobject][ordered]@{} }
  }
  Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $partial -Compress -Depth 10)

  $end = [pscustomobject][ordered]@{
    type = 'tool_execution_end'; toolCallId = "call_$Index"; toolName = 'bash'
    result = [pscustomobject][ordered]@{ content = @([pscustomobject][ordered]@{ type = 'text'; text = "$sent`: isolation payload $Index (unique-$unique)" }); details = [pscustomobject][ordered]@{} }
    isError = $false
  }
  Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $end -Compress -Depth 10)

  $trStart = [pscustomobject][ordered]@{
    type = 'message_start'
    message = [pscustomobject][ordered]@{ role = 'toolResult'; toolCallId = "call_$Index"; toolName = 'bash'; content = @([pscustomobject][ordered]@{ type = 'text'; text = "$sent result" }); isError = $false }
  }
  Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $trStart -Compress -Depth 10)
  $trEnd = [pscustomobject][ordered]@{
    type = 'message_end'
    message = [pscustomobject][ordered]@{ role = 'toolResult'; toolCallId = "call_$Index"; toolName = 'bash'; content = @([pscustomobject][ordered]@{ type = 'text'; text = "$sent result" }); isError = $false }
  }
  Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $trEnd -Compress -Depth 10)

  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"stop"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_end","message":{"role":"assistant","stopReason":"stop"},"toolResults":[]}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_end","messages":[{"role":"assistant"}],"willRetry":false}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_settled"}'
  Write-Terminal -Run $Run -Status 'completed' -ExitCode 0 -Signal $null
}

function Emit-ClosureBody {
  param($Run)
  # ~2400 paced records so a human can close this window mid-stream.
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_start"}'
  $iterations = 400
  for ($i = 1; $i -le $iterations; $i++) {
    Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_start"}'
    Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":null}}'
    $evt = [pscustomobject][ordered]@{
      type = 'message_update'
      assistantMessageEvent = [pscustomobject][ordered]@{ type = 'text_delta'; contentIndex = 1; delta = "closure keepalive $i of $iterations" }
    }
    Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $evt -Compress -Depth 10)
    $endEvt = [pscustomobject][ordered]@{
      type = 'message_update'
      assistantMessageEvent = [pscustomobject][ordered]@{ type = 'text_end'; contentIndex = 1; content = "closure keepalive $i of $iterations (final)" }
    }
    Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $endEvt -Compress -Depth 10)
    Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"stop"}}'
    Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_end","message":{"role":"assistant","stopReason":"stop"},"toolResults":[]}'
  }
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_end","messages":[{"role":"assistant"}],"willRetry":false}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_settled"}'
  Write-Terminal -Run $Run -Status 'completed' -ExitCode 0 -Signal $null
}

function Emit-CapturefailBody {
  param($Run)
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_start"}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_start"}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":null}}'
  $evt = [pscustomobject][ordered]@{
    type = 'message_update'
    assistantMessageEvent = [pscustomobject][ordered]@{ type = 'text_delta'; contentIndex = 1; delta = 'capturefail: partial output before the capture died' }
  }
  Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $evt -Compress -Depth 10)
  Write-Record -Run $Run -Ch 'stderr' -Data 'capturefail: stdout stream ended unexpectedly before a terminal event'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"tool_execution_start","toolCallId":"call_cf","toolName":"bash","args":{"command":"sleep forever"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"tool_execution_update","toolCallId":"call_cf","toolName":"bash","args":{"command":"sleep forever"},"partialResult":{"content":[{"type":"text","text":"partial"}],"details":{}}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"tool_execution_end","toolCallId":"call_cf","toolName":"bash","result":{"content":[{"type":"text","text":"partial"}],"details":{}},"isError":false}'
  Write-CaptureError -Run $Run -Message 'simulated capture failure: stdout closed without terminal event'
}

function Emit-DuplicateBody {
  param($Run)
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_start"}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_start"}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":null}}'
  $evt = [pscustomobject][ordered]@{
    type = 'message_update'
    assistantMessageEvent = [pscustomobject][ordered]@{ type = 'text_delta'; contentIndex = 1; delta = 'duplicate terminal probe' }
  }
  Write-Record -Run $Run -Ch 'stdout' -Data (ConvertTo-Json -InputObject $evt -Compress -Depth 10)
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"stop"}}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"turn_end","message":{"role":"assistant","stopReason":"stop"},"toolResults":[]}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_end","messages":[{"role":"assistant"}],"willRetry":false}'
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"agent_settled"}'
  Write-Terminal -Run $Run -Status 'completed' -ExitCode 0 -Signal $null
  # Late record between the two terminal records, then the duplicate terminal.
  Write-Record -Run $Run -Ch 'stdout' -Data '{"type":"queue_update","steering":[],"followUp":[]}'
  Write-Terminal -Run $Run -Status 'completed' -ExitCode 0 -Signal $null
}

# ---------------------------------------------------------------------------
# Gate + manifest
# ---------------------------------------------------------------------------

function Invoke-Gate {
  if ($GateWaitMs -le 0) { return }
  $readyPath = Join-Path $OutDir 'gate.ready'
  [System.IO.File]::WriteAllText($readyPath, ('ready ' + [DateTime]::UtcNow.ToString('o')), $utf8)
  $goPath = Join-Path $OutDir 'gate.go'
  $deadline = [DateTime]::UtcNow.AddMilliseconds($GateWaitMs)
  while (-not (Test-Path -LiteralPath $goPath)) {
    if ([DateTime]::UtcNow -gt $deadline) {
      Write-Host "[fixture-generator] gate wait timed out after $GateWaitMs ms; streaming without a viewer."
      break
    }
    Start-Sleep -Milliseconds 100
  }
  if ((Test-Path -LiteralPath $goPath) -and ($GatePostSleepMs -gt 0)) {
    # The viewer wrote gate.go from its first tick. Give it a bounded pause
    # to finish replaying the preambles before the paced bodies arrive, so
    # tailing starts from a replay-complete display.
    Start-Sleep -Milliseconds $GatePostSleepMs
  }
  Write-Host '[fixture-generator] gate open; streaming record bodies.'
}

function Write-Manifest {
  $runList = New-Object 'System.Collections.Generic.List[object]'
  foreach ($r in $script:runStates) {
    $runList.Add([pscustomobject][ordered]@{
      runId               = $r.runId
      journal             = [System.IO.Path]::GetFileName($r.journal)
      scenario            = $r.scenario
      emittedCount        = $r.emittedCount
      lastSeq             = $r.lastSeq
      rawSha256           = $r.rawSha256
      terminal            = $r.terminal
      uniqueSentinel      = $r.uniqueSentinel
      generatorFinishedAt = $r.generatorFinishedAt
    })
  }
  $manifest = [pscustomobject][ordered]@{
    tool          = 'fixture-generator.ps1'
    scenario      = $Scenario
    seed          = $Seed
    requestedRuns = $Runs
    stream        = [bool]$Stream
    rate          = $Rate
    volumeEvents  = $VolumeEvents
    generatedAt   = Get-NowMs
    runs          = $runList
  }
  $json = ConvertTo-Json -InputObject $manifest -Depth 10
  [System.IO.File]::WriteAllText((Join-Path $OutDir 'manifest.json'), $json, $utf8)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$plan = New-Object 'System.Collections.Generic.List[object]'
function Add-PlannedRun {
  param([string]$ScenarioName, [int]$Index, [string]$Body, [string]$Sentinel)
  $plan.Add([pscustomobject]@{
    runId    = ('{0}-{1:D4}' -f $ScenarioName, $Index)
    scenario = $ScenarioName
    body     = $Body
    index    = $Index
    sentinel = $Sentinel
  })
}

if ($Scenario -eq 'all') {
  # Volume first (stress), closure second (paced, long-running), then the rest.
  $order = @('volume', 'closure', 'happy', 'unicode', 'isolation', 'windowfail', 'capturefail', 'duplicate')
}
else {
  $order = @($Scenario)
}

foreach ($sc in $order) {
  if ($sc -eq 'isolation') {
    for ($i = 1; $i -le $Runs; $i++) {
      Add-PlannedRun -ScenarioName 'isolation' -Index $i -Body 'isolation' -Sentinel ('RUN-SENTINEL-{0:D2}' -f $i)
    }
  }
  elseif ($sc -eq 'windowfail') {
    for ($i = 1; $i -le $Runs; $i++) {
      Add-PlannedRun -ScenarioName 'windowfail' -Index $i -Body 'isolation' -Sentinel ('RUN-SENTINEL-W{0:D2}' -f $i)
    }
  }
  else {
    Add-PlannedRun -ScenarioName $sc -Index 1 -Body $sc -Sentinel $null
  }
}

try {
  foreach ($p in $plan) {
    $paced = ($Stream.IsPresent -and ($p.scenario -ne 'volume'))
    $rateLimit = 0
    if ($p.scenario -eq 'volume') { $rateLimit = $Rate }
    $state = New-RunState -RunId $p.runId -ScenarioName $p.scenario -Paced $paced -RateLimit $rateLimit -Sentinel $p.sentinel
    Write-Preamble -Run $state
    $script:runStates.Add($state)
    $script:stateByRunId[$p.runId] = $state
  }

  $wf = $script:runStates | Where-Object { $_.scenario -eq 'windowfail' } | Select-Object -First 1
  if ($null -ne $wf) {
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'force-display-error.txt'), $wf.runId, $utf8)
  }

  Invoke-Gate

  foreach ($p in $plan) {
    $state = $script:stateByRunId[$p.runId]
    switch ($p.body) {
      'happy' { Emit-HappyBody -Run $state }
      'volume' { Emit-VolumeBody -Run $state }
      'unicode' { Emit-UnicodeBody -Run $state }
      'isolation' { Emit-IsolationBody -Run $state -Index $p.index }
      'closure' { Emit-ClosureBody -Run $state }
      'capturefail' { Emit-CapturefailBody -Run $state }
      'duplicate' { Emit-DuplicateBody -Run $state }
      default { throw "unknown body emitter: $($p.body)" }
    }
    Write-Host ("[fixture-generator] finished {0} ({1} records)" -f $p.runId, $state.seq)
  }

  foreach ($state in $script:runStates) { Complete-Run -Run $state }
  Write-Manifest
  Write-Host ('[fixture-generator] scenario={0} runs={1} out={2}' -f $Scenario, $script:runStates.Count, $OutDir)
}
finally {
  foreach ($state in $script:runStates) {
    if ($null -ne $state.writer) {
      try { $state.writer.Dispose() } catch { }
      $state.writer = $null
    }
  }
}
