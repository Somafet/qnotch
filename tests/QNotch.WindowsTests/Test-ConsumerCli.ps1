param(
    [string]$Executable = (Join-Path $PSScriptRoot '../../dist/QNotch.exe'),
    [string]$ReportPath,
    [switch]$Measure
)
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path $Executable).Path
$data = Join-Path ([IO.Path]::GetTempPath()) ('qnotch-consumer-' + [guid]::NewGuid().ToString('N'))
$instance = 'consumer-' + [guid]::NewGuid().ToString('N')
New-Item -ItemType Directory -Force $data | Out-Null
$allModules = @('stats','media','clipboard','ai','agents','note','github','filetray','notifications','capture','scheduled','volume','timer','colorpicker','weather','search','terminal')
$general = @{ UpdateChecksChoiceMade=$true; CheckForUpdates=$false; OnboardingDone=$true; ShareUsageData=$false; DisabledModules=@($allModules | Where-Object { $_ -notin @('ai','agents') }) }
$general | ConvertTo-Json | Set-Content (Join-Path $data 'general.json')
@{ Providers=@{claude=$false;codex=$false} } | ConvertTo-Json | Set-Content (Join-Path $data 'ai.json')
@{ SoundNeedsYou=$false; SoundDone=$false } | ConvertTo-Json | Set-Content (Join-Path $data 'agents.json')

function StartInfo($arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($exe)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.Environment['QNOTCH_INSTANCE'] = $instance
    $start.Environment['QNOTCH_DATA_DIR'] = $data
    $start.Environment['CLAUDE_CONFIG_DIR'] = (Join-Path $data 'claude')
    $start.Environment['CODEX_HOME'] = (Join-Path $data 'codex')
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    return $start
}
function InvokeConsumerCli($arguments, $inputText=$null) {
    $start = StartInfo $arguments
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $null -ne $inputText
    $child = [Diagnostics.Process]::Start($start)
    try {
        if ($null -ne $inputText) { $child.StandardInput.WriteLine($inputText); $child.StandardInput.Close() }
        $outTask = $child.StandardOutput.ReadToEndAsync()
        $errTask = $child.StandardError.ReadToEndAsync()
        if (!$child.WaitForExit(10000)) { $child.Kill($true); throw 'Owned InvokeConsumerCli timed out' }
        if ($child.ExitCode -ne 0) { throw "InvokeConsumerCli failed ($($child.ExitCode)): $($errTask.GetAwaiter().GetResult())" }
        return $outTask.GetAwaiter().GetResult()
    } finally { $child.Dispose() }
}
function DebugCall($command) {
    # Debug is used only for isolated app shutdown, never for consumer data.
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'QNotch.Debug.' + $instance, [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(10000)
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
        $writer.AutoFlush = $true
        $reader = [IO.StreamReader]::new($pipe)
        $writer.WriteLine((@{cmd=$command;args=@{}} | ConvertTo-Json -Compress))
        return ($reader.ReadLine() | ConvertFrom-Json)
    } finally { $pipe.Dispose() }
}
function Boot {
    $app = [Diagnostics.Process]::Start((StartInfo @('--debug-control','--data-dir',$data)))
    if (!(DebugCall 'ping').ok) { throw 'Isolated app did not start' }
    return $app
}
function Quit($app) {
    if (!(DebugCall 'quit').ok) { throw 'Isolated app rejected quit' }
    if (!$app.WaitForExit(10000)) { throw 'Owned app did not quit' }
}
function SettingsFingerprint {
    return ((Get-ChildItem -LiteralPath $data -Filter '*.json' | Sort-Object Name | ForEach-Object { $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join '|')
}

$app = $null
try {
    $app = Boot
    $usage = InvokeConsumerCli @('usage','--json') | ConvertFrom-Json
    if ($usage.module_status -ne 'ready' -or $usage.data.accounts.Count -lt 2) { throw 'Usage endpoints not registered' }
    if (@($usage.data.accounts | Where-Object { $_.status -ne 'disabled' -or $_.windows.Count -ne 0 -or $null -ne $_.observed_at }).Count) { throw 'Disabled providers exposed readings' }
    $claude = $usage.data.accounts | Where-Object provider -eq 'claude' | Select-Object -First 1
    $filtered = InvokeConsumerCli @('usage','--json','--provider','claude','--account',$claude.account_id) | ConvertFrom-Json
    if ($filtered.data.accounts.Count -ne 1) { throw 'Account filtering failed' }

    $fixtureProject = Join-Path $data 'consumer-fixture-project'
    New-Item -ItemType Directory -Force $fixtureProject | Out-Null
    $transcript = Join-Path $data 'fixture.jsonl'
    @{type='custom-title';customTitle='Synthetic consumer fixture'} | ConvertTo-Json -Compress | Set-Content $transcript
    @{type='assistant';timestamp=[DateTime]::UtcNow.ToString('O');message=@{id='fixture-reply';model='claude-sonnet-4';usage=@{input_tokens=100;output_tokens=20}}} | ConvertTo-Json -Depth 8 -Compress | Add-Content $transcript
    $hook = @{hook_event_name='UserPromptSubmit';session_id='fixture-session';cwd=$fixtureProject;transcript_path=$transcript} | ConvertTo-Json -Compress
    InvokeConsumerCli @('agent') $hook | Out-Null
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    do {
        $snapshot = InvokeConsumerCli @('agents','--json','--details') | ConvertFrom-Json
        $session = $snapshot.data.sessions | Where-Object project -eq 'consumer-fixture-project' | Select-Object -First 1
        $reading = $snapshot.data.usage | Where-Object session_id -eq $session.session_id | Select-Object -First 1
        if ($reading.status -eq 'ok') { break }
        Start-Sleep -Milliseconds 150
    } while ($deadline.Elapsed.TotalSeconds -lt 15)
    if ($session.status -ne 'working' -or $reading.total.tokens -ne 120) { throw 'Observed hook/transcript usage did not reach snapshot' }
    $private = InvokeConsumerCli @('agents','--json')
    if ($private.Contains('Synthetic consumer fixture') -or $private.Contains('consumer-fixture-project') -or $private.Contains('fixture-session') -or $private.Contains('fixture.jsonl')) { throw 'Default output leaked private fixture fields' }
    $hook = @{hook_event_name='Notification';notification_type='permission_prompt';session_id='fixture-session';cwd=$fixtureProject;message='Private permission content'} | ConvertTo-Json -Compress
    InvokeConsumerCli @('agent') $hook | Out-Null
    $deadline.Restart()
    do {
        $snapshot = InvokeConsumerCli @('agents','--json') | ConvertFrom-Json
        $waiting = $snapshot.data.sessions | Where-Object session_id -eq $session.session_id | Select-Object -First 1
        if ($waiting.status -eq 'needs_you') { break }
        Start-Sleep -Milliseconds 100
    } while ($deadline.Elapsed.TotalSeconds -lt 5)
    if ($waiting.status -ne 'needs_you') { throw 'Agent attention state missing' }

    # Let the existing settings debounce settle; reads must leave persisted settings byte-for-byte unchanged.
    Start-Sleep -Seconds 1
    $before = SettingsFingerprint
    $latencies = @()
    for ($i=0; $i -lt 30; $i++) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        InvokeConsumerCli @('usage','--json') | ConvertFrom-Json | Out-Null
        $latencies += $clock.Elapsed.TotalMilliseconds
    }
    if ((SettingsFingerprint) -ne $before) { throw 'Queries changed persisted settings' }
    $sorted = @($latencies | Sort-Object)
    $report = [ordered]@{
        platform='Windows'; app_version=$usage.app_version; build='Release'; state='collapsed'; samples=$latencies.Count
        method='Isolated normal startup in debug-control mode; only Ai/Agents enabled, providers disabled, synthetic hook/transcript. Timed CLI process startup, pipe exchange and ConvertFrom-Json.'
        latency_min_ms=[Math]::Round($sorted[0],2); latency_p50_ms=[Math]::Round($sorted[14],2); latency_p95_ms=[Math]::Round($sorted[28],2); latency_max_ms=[Math]::Round($sorted[-1],2)
        writes_from_queries=$false; synthetic_tokens=$reading.total.tokens
    }
    if ($Measure) {
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class ConsumerCycles {
    [DllImport("kernel32.dll")] public static extern bool QueryProcessCycleTime(IntPtr handle, out ulong cycles);
    public static double Hertz() {
        using var p = Process.GetCurrentProcess();
        QueryProcessCycleTime(p.Handle, out var start);
        var clock = Stopwatch.StartNew(); while (clock.ElapsedMilliseconds < 150) { }
        QueryProcessCycleTime(p.Handle, out var end);
        return (end-start)/clock.Elapsed.TotalSeconds;
    }
}
'@
        Start-Sleep -Seconds 5
        $hz = [ConsumerCycles]::Hertz()
        $app.Refresh()
        $resident0 = $app.WorkingSet64
        [ulong]$cycles0=0; [ulong]$cycles1=0
        [ConsumerCycles]::QueryProcessCycleTime($app.Handle, [ref]$cycles0) | Out-Null
        $idle = [Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Seconds 30
        [ConsumerCycles]::QueryProcessCycleTime($app.Handle, [ref]$cycles1) | Out-Null
        $seconds=$idle.Elapsed.TotalSeconds
        $app.Refresh()
        $report.idle_interval_seconds=[Math]::Round($seconds,3)
        $report.idle_cpu_percent_one_core=[Math]::Round((($cycles1-$cycles0)/$hz/$seconds*100),4)
        $report.resident_bytes_start=$resident0
        $report.resident_bytes_end=$app.WorkingSet64
        $report.cpu_model=(Get-CimInstance Win32_Processor | Select-Object -First 1).Name
        $report.logical_processors=[Environment]::ProcessorCount
        $report.os=[Environment]::OSVersion.VersionString
        $report.idle_state=(DebugCall 'state').result.panel
    }
    Quit $app
    # Account pseudonyms survive restart; disabled modules still answer without being constructed.
    $app = Boot
    $restarted = InvokeConsumerCli @('usage','--json','--provider','claude','--account',$claude.account_id) | ConvertFrom-Json
    if ($restarted.data.accounts[0].account_id -ne $claude.account_id) { throw 'Account ID changed on restart' }
    Quit $app
    $general.DisabledModules=$allModules
    $general | ConvertTo-Json | Set-Content (Join-Path $data 'general.json')
    $app = Boot
    foreach ($verb in @('usage','agents')) {
        $disabled = InvokeConsumerCli @($verb,'--json') | ConvertFrom-Json
        if ($disabled.module_status -ne 'disabled' -or $null -ne $disabled.data) { throw 'Disabled module exposed data' }
    }
    $state=(DebugCall 'state').result
    if (@($state.modules | Where-Object { $_.id -in @('ai','agents') -and $_.running }).Count) { throw 'Disabled module was constructed' }
    Quit $app
    if ($ReportPath) {
        $target = [IO.Path]::GetFullPath($ReportPath)
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $target
    }
    $report | ConvertTo-Json -Depth 8
    'PASS consumer CLI lifecycle, cached snapshots, filters, opaque IDs, privacy, synthetic hook/transcript, unchanged settings and disabled modules.'
} finally {
    if ($null -ne $app) {
        if (!$app.HasExited) { try { Quit $app } catch { Stop-Process -Id $app.Id } }
        $app.Dispose()
    }
    $resolved=[IO.Path]::GetFullPath($data)
    if (!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
