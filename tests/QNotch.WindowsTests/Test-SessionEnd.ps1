# Sign-out, restart and shutdown must leave the analytics run-state marker at "exited" (spec/analytics.md, previous_exit).
# Windows may end the process right after WM_ENDSESSION, before WPF's queued Shutdown reaches OnExit, so this sends the session-end
# messages and then terminates the process at once, as Windows does. A normal start is needed (debug control turns analytics off),
# so it runs with its own instance, data, profile folders and an unreachable PostHog host: nothing mixes with the user's app or is sent.
param([string]$Executable = (Join-Path $PSScriptRoot '../../dist/QNotch.exe'))
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path $Executable).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('qnotch-session-end-' + [guid]::NewGuid().ToString('N'))
$data = Join-Path $root 'data'
$state = Join-Path $data 'analytics-run-state'
New-Item -ItemType Directory -Force $data | Out-Null
$off = @('stats','media','clipboard','ai','agents','note','github','filetray','notifications','capture','scheduled','volume','timer','colorpicker','weather','search','terminal','calculator')
@{UpdateChecksChoiceMade=$true;CheckForUpdates=$false;OnboardingDone=$true;DisabledModules=$off} | ConvertTo-Json | Set-Content (Join-Path $data general.json)

Add-Type -Namespace QNotchTest -Name Session -MemberDefinition @'
delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
[DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
[DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
public static int SendEndSession(int processId)
{
    var windows = new System.Collections.Generic.List<IntPtr>();
    EnumWindows((h, _) => { uint pid; GetWindowThreadProcessId(h, out pid); if (pid == processId) windows.Add(h); return true; }, IntPtr.Zero);
    var logoff = new IntPtr(unchecked((int)0x80000000)); // ENDSESSION_LOGOFF
    IntPtr r;
    foreach (var h in windows) SendMessageTimeout(h, 0x0011, IntPtr.Zero, logoff, 0x0002, 5000, out r); // WM_QUERYENDSESSION, SMTO_ABORTIFHUNG
    foreach (var h in windows) SendMessageTimeout(h, 0x0016, new IntPtr(1), logoff, 0x0002, 5000, out r); // WM_ENDSESSION (ending)
    return windows.Count;
}
'@

$start = [Diagnostics.ProcessStartInfo]::new($exe)
$start.UseShellExecute = $false
$start.Environment['QNOTCH_INSTANCE'] = 'session-end-' + [guid]::NewGuid().ToString('N')
$start.Environment['QNOTCH_DATA_DIR'] = $data
$start.Environment['QNOTCH_POSTHOG_KEY'] = 'phc_session_end_test'
$start.Environment['QNOTCH_POSTHOG_HOST'] = 'https://127.0.0.1:9'
$start.Environment.Remove('QNOTCH_TELEMETRY_ENABLED') | Out-Null
foreach ($name in @('APPDATA','LOCALAPPDATA','USERPROFILE')) {
    $folder = Join-Path $root $name
    New-Item -ItemType Directory -Force $folder | Out-Null
    $start.Environment[$name] = $folder
}
$app = [Diagnostics.Process]::Start($start)
try {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (!(Test-Path $state) -or (Get-Content $state -Raw).Trim() -ne 'running') {
        if ($app.HasExited) { throw "QNotch exited during startup ($($app.ExitCode))" }
        if ($clock.Elapsed.TotalSeconds -gt 60) { throw 'The launch never wrote the running marker' }
        Start-Sleep -Milliseconds 100
    }
    [int]$reached = [QNotchTest.Session]::SendEndSession($app.Id)
    if ($reached -eq 0) { throw 'No QNotch windows received the session-end messages' }
    $app.Kill() # Windows may end the process as soon as WM_ENDSESSION returns
    $app.WaitForExit()
    $marker = (Get-Content $state -Raw).Trim()
    if ($marker -ne 'exited') { throw "Session end left the run-state marker at '$marker'; the next launch would report previous_exit=unclean" }
    'Session end marks a clean exit'
}
finally {
    if (!$app.HasExited) { $app.Kill(); $app.WaitForExit() }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
