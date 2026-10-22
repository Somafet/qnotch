param([string]$Executable = (Join-Path $PSScriptRoot '../../dist/QNotch.exe'))
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path $Executable).Path
$data = Join-Path ([IO.Path]::GetTempPath()) ('qnotch-terminal-ui-' + [guid]::NewGuid().ToString('N'))
$env:QNOTCH_INSTANCE = 'terminal-ui-' + [guid]::NewGuid().ToString('N')
$env:QNOTCH_DATA_DIR = $data
New-Item -ItemType Directory -Force $data | Out-Null
$off = @('stats','media','clipboard','ai','agents','note','github','filetray','notifications','capture','scheduled','volume','timer','colorpicker','weather','search')
@{UpdateChecksChoiceMade=$true;CheckForUpdates=$false;OnboardingDone=$true;DisabledModules=$off} | ConvertTo-Json | Set-Content (Join-Path $data general.json)
function Call($cmd, $arguments=@{}) {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'QNotch.Debug.' + $env:QNOTCH_INSTANCE, [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(10000)
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
        $writer.AutoFlush = $true
        $reader = [IO.StreamReader]::new($pipe)
        $writer.WriteLine((@{cmd=$cmd;args=$arguments} | ConvertTo-Json -Compress))
        return ($reader.ReadLine() | ConvertFrom-Json)
    } finally { $pipe.Dispose() }
}
function Must($response) { if (!$response.ok) { throw $response.error }; return $response.result }
function Boot {
    $start = [Diagnostics.ProcessStartInfo]::new($exe)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.ArgumentList.Add('--debug-control'); $start.ArgumentList.Add('--data-dir'); $start.ArgumentList.Add($data)
    foreach ($name in @('APPDATA','LOCALAPPDATA')) {
        $folder = Join-Path $data $name
        New-Item -ItemType Directory -Force $folder | Out-Null
        $start.Environment[$name] = $folder
    }
    return [Diagnostics.Process]::Start($start)
}
function Quit($app) { Call 'quit' | Out-Null; if (!$app.WaitForExit(10000)) { throw 'Owned app failed to quit' } }
function WaitText($marker) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $text = (Must (Call 'outline' @{window='panel'})).text
        if ($text.Contains($marker)) { return $text }
        Start-Sleep -Milliseconds 100
    } while ($clock.Elapsed.TotalSeconds -lt 15)
    throw "Missing terminal output: $marker"
}
function Alive($processId) { return $null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue) }
$app = Boot
try {
    $state = Must (Call 'state')
    if (($state.modules | Where-Object id -eq 'terminal').running) { throw 'Terminal constructed while off' }
    if ((Call 'select-tab' @{id='terminal'}).ok) { throw 'Default-off Terminal accepted entry' }
    Must (Call 'settings' @{section='features'}) | Out-Null
    Must (Call 'press' @{id='feature-terminal'}) | Out-Null
    Quit $app
    $settings = Get-Content (Join-Path $data general.json) -Raw | ConvertFrom-Json
    if ($settings.LocalEnabledModules -notcontains 'terminal' -or $settings.DisabledModules -contains 'terminal') { throw 'Terminal opt-in was not local' }
    $app = Boot
    Must (Call 'select-tab' @{id='terminal'}) | Out-Null
    WaitText 'PS ' | Out-Null
    Must (Call 'type' @{id='terminal-input';text="`$m='QNOTCH'; `$m+'_UI_READY'; `$m+'_PID='+`$PID`r"}) | Out-Null
    $text = WaitText 'QNOTCH_UI_READY'
    $text = WaitText 'QNOTCH_PID='
    if ($text -notmatch 'QNOTCH_PID=(\d+)') { throw 'Shell PID not reported' }
    $terminalProcessId = [int]$Matches[1]
    if ($text -notmatch '#terminal-input.*focused') { throw 'Terminal input lacks focus' }
    Must (Call 'hotkey' @{action='toggle'}) | Out-Null
    if (!(Alive $terminalProcessId)) { throw 'Panel close terminated retained session' }
    Must (Call 'hotkey' @{action='toggle'}) | Out-Null
    $text = WaitText 'QNOTCH_UI_READY'
    if ($text -notmatch '#terminal-input.*focused' -or !(Alive $terminalProcessId)) { throw 'Hotkey reopen lost focus or session' }
    Must (Call 'settings' @{section='features'}) | Out-Null
    Must (Call 'press' @{id='feature-terminal'}) | Out-Null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ((Alive $terminalProcessId) -and $clock.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 50 }
    if (Alive $terminalProcessId) { throw 'Disabling did not reap owned shell' }
    Quit $app
    $app = Boot
    if ((Must (Call 'state')).modules.Where({$_.id -eq 'terminal'}).running) { throw 'Terminal constructed after disabled restart' }
    Must (Call 'settings' @{section='features'}) | Out-Null
    Must (Call 'press' @{id='feature-terminal'}) | Out-Null
    Quit $app
    $app = Boot
    Must (Call 'select-tab' @{id='terminal'}) | Out-Null
    WaitText 'PS ' | Out-Null
    Must (Call 'type' @{id='terminal-input';text="'QNOTCH_PID='+`$PID`r"}) | Out-Null
    $text = WaitText 'QNOTCH_PID='
    $text -match 'QNOTCH_PID=(\d+)' | Out-Null
    $terminalProcessId = [int]$Matches[1]
    Quit $app
    if (Alive $terminalProcessId) { throw 'Quit did not reap owned shell' }
    'PASS native Terminal default-off boot, Features local opt-in/restart, real UI input, hotkey focus/retention, disable/restart and quit process reap.'
} finally {
    if (!$app.HasExited) { try { Quit $app } catch { Stop-Process -Id $app.Id } }
    # This uniquely created test folder is the only recursive target.
    $resolved = [IO.Path]::GetFullPath($data)
    if (!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
