<#
.SYNOPSIS
  Builds dist\QNotch.msix, the Microsoft Store package of the self-contained QNotch.exe.
.DESCRIPTION
  Publishes the win-x64-self-contained profile (unless -SkipPublish), stages QNotch.exe with AppxManifest.xml and logos drawn by
  Assets/Build-AppIcon.ps1, indexes the logo variants with makepri and packs with makeappx (Windows 10 SDK). The package is unsigned:
  the Store signs it on upload. Neither the release assets nor the single-exe ZIP change.

  To try it locally without signing, turn on Developer Mode and pass -Register: Windows installs the staged folder as the package,
  with identity, the startup task and the qnotch alias. Remove it again with Get-AppxPackage Somafet.QNotch | Remove-AppxPackage.

  pwsh src/QNotch/Packaging/Build-Msix.ps1 -Version 0.9.0 [-SkipPublish] [-Register]
#>
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [switch]$SkipPublish,
    [switch]$Register
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$dist = Join-Path $root 'dist'
$exe = Join-Path $dist 'self-contained\QNotch.exe'
$stage = Join-Path $dist 'msix\stage'
$out = Join-Path $dist 'QNotch.msix'

function Find-SdkTool([string]$name) {
    $bin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $tool = Get-ChildItem $bin -Directory -Filter '10.*' -ErrorAction SilentlyContinue | Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName "x64\$name" } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $tool) { throw "$name not found. Install the Windows 10/11 SDK." }
    $tool
}

if (-not $SkipPublish) {
    dotnet publish (Join-Path $root 'src\QNotch\QNotch.csproj') -p:PublishProfile=win-x64-self-contained -p:Version=$Version
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)." }
}
if (-not (Test-Path $exe)) { throw "Missing $exe. Publish the win-x64-self-contained profile first." }

# A registered package runs from the stage folder; remove it before the folder is rebuilt.
if ($Register) { Get-AppxPackage Somafet.QNotch | Remove-AppxPackage }
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$assets = New-Item -ItemType Directory -Force (Join-Path $stage 'Assets')
Copy-Item $exe $stage

# Logos: plain names for the manifest, scale and targetsize variants that makepri indexes. altform-unplated keeps the mark's own
# dark tile on the taskbar and Start instead of an accent-colored plate behind it.
$icons = Join-Path $dist 'msix\icons'
& (Join-Path $root 'src\QNotch\Assets\Build-AppIcon.ps1') -PngOnly -PreviewDir $icons -Sizes 16, 24, 32, 44, 48, 50, 88, 100, 150, 256, 300
$copy = @{
    'StoreLogo.png' = 50; 'StoreLogo.scale-200.png' = 100
    'Square150x150Logo.png' = 150; 'Square150x150Logo.scale-200.png' = 300
    'Square44x44Logo.png' = 44; 'Square44x44Logo.scale-200.png' = 88
}
foreach ($t in 16, 24, 32, 48, 256) {
    $copy["Square44x44Logo.targetsize-$t.png"] = $t
    $copy["Square44x44Logo.targetsize-${t}_altform-unplated.png"] = $t
}
foreach ($name in $copy.Keys) { Copy-Item (Join-Path $icons "icon-$($copy[$name]).png") (Join-Path $assets $name) }

(Get-Content (Join-Path $PSScriptRoot 'AppxManifest.xml') -Raw).Replace('{{VERSION}}', "$Version.0") |
    Set-Content (Join-Path $stage 'AppxManifest.xml') -Encoding utf8NoBOM

$makepri = Find-SdkTool 'makepri.exe'
$priConfig = Join-Path $dist 'msix\priconfig.xml'
& $makepri createconfig /cf $priConfig /dq en-US /pv 10.0.0 /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makepri createconfig failed ($LASTEXITCODE)." }
& $makepri new /pr $stage /cf $priConfig /mn (Join-Path $stage 'AppxManifest.xml') /of (Join-Path $stage 'resources.pri') /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makepri new failed ($LASTEXITCODE)." }

if ($Register) {
    Add-AppxPackage -Register (Join-Path $stage 'AppxManifest.xml')
    "Registered QNotch $Version from $stage. Start it from the Start menu or run qnotch."
}

$makeappx = Find-SdkTool 'makeappx.exe'
& $makeappx pack /d $stage /p $out /h SHA256 /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makeappx pack failed ($LASTEXITCODE)." }
"Wrote $out ($([math]::Round((Get-Item $out).Length / 1MB, 1)) MB, version $Version.0)"
