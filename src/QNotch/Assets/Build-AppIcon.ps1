<#
.SYNOPSIS
  Regenerates AppIcon.ico (and optional PNG previews) from the brand mark in AppIcon.svg.
.DESCRIPTION
  The mark is three shapes: a dark rounded square, a white pill (the notch) and a blue dot. They are drawn
  with GDI+ at every size (16, 20, 24, 32, 40, 48, 64, 128, 256). Up to 48 px the pill and dot are snapped to
  whole pixels (the table below) so the pill edges stay sharp and the dot stays a clean dot; 64 px and up use
  the exact SVG geometry scaled. Sizes below 256 are stored as 32-bit BMP entries (widest compatibility), 256 as PNG.
  Run on Windows from anywhere: pwsh src/QNotch/Assets/Build-AppIcon.ps1 [-PreviewDir <dir>]
  With -PngOnly it writes icon-<size>.png for -Sizes into -PreviewDir and leaves AppIcon.ico alone (the MSIX logos use this).
#>
param([string]$PreviewDir, [int[]]$Sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256), [switch]$PngOnly)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# size -> pill (x0, y0, x1, y1), dot radius, background corner radius. The dot sits at the pill's right cap center.
$snap = @{
    16 = @{ P = 3, 4, 13, 8;     R = 1.0; C = 4 }
    20 = @{ P = 4, 6, 16, 10;    R = 1.1; C = 5 }
    24 = @{ P = 5, 7, 19, 12;    R = 1.3; C = 6 }
    32 = @{ P = 7, 9, 25, 16;    R = 1.6; C = 8 }
    40 = @{ P = 9, 11, 31, 20;   R = 2.0; C = 10 }
    48 = @{ P = 10, 13, 38, 24;  R = 2.4; C = 12 }
}

function New-Capsule([double]$x0, [double]$y0, [double]$x1, [double]$y1, [double]$r) {
    $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $d = $r * 2
    $p.AddArc($x0, $y0, $d, $d, 180, 90); $p.AddArc($x1 - $d, $y0, $d, $d, 270, 90)
    $p.AddArc($x1 - $d, $y1 - $d, $d, $d, 0, 90); $p.AddArc($x0, $y1 - $d, $d, $d, 90, 90)
    $p.CloseFigure(); $p
}

function New-IconBitmap([int]$s) {
    if ($snap.ContainsKey($s)) { $t = $snap[$s]; $x0, $y0, $x1, $y1 = $t.P; $dotR = $t.R; $corner = $t.C }
    else { $k = $s / 32.0; $x0 = 7 * $k; $y0 = 9 * $k; $x1 = 25 * $k; $y1 = 16 * $k; $dotR = 1.6 * $k; $corner = 8 * $k }
    $pillR = ($y1 - $y0) / 2
    $bmp = [System.Drawing.Bitmap]::new($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'Half'; $g.Clear([System.Drawing.Color]::Transparent)
    $bg = New-Capsule 0 0 $s $s $corner
    $g.FillPath([System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#0B0B0D')), $bg)
    $g.FillPath([System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#F4F4F7')), (New-Capsule $x0 $y0 $x1 $y1 $pillR))
    $cx = $x1 - $pillR; $cy = ($y0 + $y1) / 2
    $g.FillEllipse([System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#5B9DFF')), $cx - $dotR, $cy - $dotR, 2 * $dotR, 2 * $dotR)
    $g.Dispose(); $bmp
}

function Get-PngBytes($bmp) { $ms = [System.IO.MemoryStream]::new(); $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $ms.ToArray() }

function Get-DibBytes($bmp, [int]$s) {
    $ms = [System.IO.MemoryStream]::new(); $w = [System.IO.BinaryWriter]::new($ms)
    $w.Write([uint32]40); $w.Write([int32]$s); $w.Write([int32]($s * 2)); $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]0); $w.Write([uint32]($s * $s * 4)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    for ($y = $s - 1; $y -ge 0; $y--) { for ($x = 0; $x -lt $s; $x++) { $c = $bmp.GetPixel($x, $y); $w.Write([byte[]]@($c.B, $c.G, $c.R, $c.A)) } }
    $w.Write([byte[]]::new([int]([Math]::Ceiling($s / 32.0) * 4 * $s))) # AND mask: all opaque, alpha channel decides
    $w.Flush(); $ms.ToArray()
}

$sizes = $Sizes
if ($PngOnly) {
    if (-not $PreviewDir) { throw '-PngOnly needs -PreviewDir.' }
    New-Item -ItemType Directory -Force $PreviewDir | Out-Null
    foreach ($s in $sizes) { $bmp = New-IconBitmap $s; $bmp.Save((Join-Path $PreviewDir "icon-$s.png"), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose() }
    return
}
$images = foreach ($s in $sizes) {
    $bmp = New-IconBitmap $s
    if ($PreviewDir) { New-Item -ItemType Directory -Force $PreviewDir | Out-Null; $bmp.Save((Join-Path $PreviewDir "icon-$s.png"), [System.Drawing.Imaging.ImageFormat]::Png) }
    [pscustomobject]@{ Size = $s; Data = $(if ($s -ge 256) { Get-PngBytes $bmp } else { Get-DibBytes $bmp $s }) }
    $bmp.Dispose()
}

$out = Join-Path $PSScriptRoot 'AppIcon.ico'
$ms = [System.IO.MemoryStream]::new(); $w = [System.IO.BinaryWriter]::new($ms)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($i in $images) {
    $dim = if ($i.Size -ge 256) { 0 } else { $i.Size }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$i.Data.Length); $w.Write([uint32]$offset); $offset += $i.Data.Length
}
foreach ($i in $images) { $w.Write([byte[]]$i.Data) }
$w.Flush(); [System.IO.File]::WriteAllBytes($out, $ms.ToArray())
"Wrote $out ($($ms.Length) bytes, sizes $($sizes -join ', '))"
