param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$WorkDir,
    [Parameter(Mandatory = $true)][int]$ParentId,
    [Parameter(Mandatory = $true)][long]$ParentStarted,
    [Parameter(Mandatory = $true)][string]$ResultFile,
    [Parameter(Mandatory = $true)][string]$Version
)
$ErrorActionPreference = 'Stop'
$replaced = $false
$ready = $false
try {
    $Target = [IO.Path]::GetFullPath($Target)
    $WorkDir = [IO.Path]::GetFullPath($WorkDir).TrimEnd('\')
    $installDir = [IO.Path]::GetDirectoryName($Target)
    # Both replacement and backup stay on the same volume for atomic File.Replace.
    if ([IO.Path]::GetDirectoryName($WorkDir) -ne $installDir -or
        [IO.Path]::GetFileName($WorkDir) -notmatch '^\.qnotch-update-[a-f0-9]{32}$' -or
        [IO.Path]::GetExtension($Target) -ne '.exe') { throw 'Invalid update paths.' }
    $staged = [IO.Path]::Combine($WorkDir, 'QNotch.exe')
    $backup = [IO.Path]::Combine($WorkDir, 'previous.exe')
    if (!(Test-Path -LiteralPath $staged -PathType Leaf) -or !(Test-Path -LiteralPath $Target -PathType Leaf)) { throw 'The update files are missing.' }
    [IO.File]::WriteAllText([IO.Path]::Combine($WorkDir, 'ready'), 'ready')
    $ready = $true
    $parent = Get-Process -Id $ParentId -ErrorAction SilentlyContinue
    if ($null -ne $parent -and $parent.StartTime.ToUniversalTime().Ticks -eq $ParentStarted) {
        if (!$parent.WaitForExit(30000)) { throw 'QNotch did not exit in time. Nothing was installed.' }
    }
    # Retry sharing violations briefly (antivirus or a process still releasing the image).
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try { [IO.File]::Replace($staged, $Target, $backup); $replaced = $true; break }
        catch [IO.IOException] { if ($attempt -eq 19) { throw }; Start-Sleep -Milliseconds 250 }
    }
    [IO.File]::WriteAllText($ResultFile, "Updated to $Version.")
    Start-Process -FilePath explorer.exe -ArgumentList ('"' + $Target + '"') -WindowStyle Hidden
    # Retain one previous executable for manual recovery. Do not touch settings or other install files.
    # Cleanup is best effort after launch; a cleanup failure must never roll back a running update.
    try {
        $previous = [IO.Path]::Combine($installDir, '.QNotch.previous.exe')
        if (Test-Path -LiteralPath $previous -PathType Leaf) { [IO.File]::Delete($previous) }
        [IO.File]::Move($backup, $previous)
        # Verified above: this exact staging directory is a direct child of the install directory.
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    } catch { }
}
catch {
    $message = $_.Exception.Message
    if ($replaced -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
        try { [IO.File]::Replace($backup, $Target, [IO.Path]::Combine($WorkDir, 'failed-update.exe')); $replaced = $false }
        catch { $message += ' Could not restore the backup: ' + $_.Exception.Message }
    }
    try { [IO.File]::WriteAllText($ResultFile, 'Update failed: ' + $message) } catch { }
    if ($ready) { try { Start-Process -FilePath explorer.exe -ArgumentList ('"' + $Target + '"') -WindowStyle Hidden } catch { } }
    exit 1
}
