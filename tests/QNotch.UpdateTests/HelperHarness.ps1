param([string]$Target, [string]$WorkDir, [int]$ParentId, [long]$ParentStarted, [string]$ResultFile, [string]$Mode)
# Only the test process replaces Start-Process. The production helper still calls Explorer.
function Start-Process {
    param([string]$FilePath, [string]$ArgumentList, [string]$WindowStyle)
    if ($FilePath -ne 'explorer.exe' -or $WindowStyle -ne 'Hidden' -or $ArgumentList -ne ('"' + $Target + '"')) { throw 'Incorrect restart command.' }
    $marker = $ResultFile + '.restart'
    $alreadyTried = Test-Path -LiteralPath $marker
    [IO.File]::AppendAllText($marker, "restart`n")
    if ($Mode -eq 'restart-failure' -and !$alreadyTried) { throw 'Simulated Explorer failure.' }
}
& (Join-Path $PSScriptRoot 'ApplyUpdate.ps1') -Target $Target -WorkDir $WorkDir -ParentId $ParentId -ParentStarted $ParentStarted -ResultFile $ResultFile -Version 'v0.4.0'
if ($LASTEXITCODE) { exit $LASTEXITCODE }
