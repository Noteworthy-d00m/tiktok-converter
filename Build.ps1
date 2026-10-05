# Generates app.ico and compiles TikTokConverter.exe (no downloads needed: uses the .NET Framework compiler built into Windows).
# -Test builds TikTokConverter-test.exe WITH the TTC_* test hooks (never ship that one); the default build ignores them.
param([switch]$CopyToDesktop, [switch]$Test)
Add-Type -AssemblyName System.Drawing
Set-Location $PSScriptRoot

# --- icon: dark rounded square with a glitchy play triangle ---
$size = 256
$bmp = New-Object System.Drawing.Bitmap $size, $size
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.Clear([System.Drawing.Color]::Transparent)

$r = 52
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
$path.AddArc($size - $r * 2 - 1, 0, $r * 2, $r * 2, 270, 90)
$path.AddArc($size - $r * 2 - 1, $size - $r * 2 - 1, $r * 2, $r * 2, 0, 90)
$path.AddArc(0, $size - $r * 2 - 1, $r * 2, $r * 2, 90, 90)
$path.CloseFigure()
$g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 17, 17, 20))), $path)

function Tri($dx, $color) {
    $pts = @(
        (New-Object System.Drawing.PointF((84 + $dx), 58)),
        (New-Object System.Drawing.PointF((84 + $dx), 198)),
        (New-Object System.Drawing.PointF((196 + $dx), 128))
    )
    $g.FillPolygon((New-Object System.Drawing.SolidBrush $color), $pts)
}
Tri -9 ([System.Drawing.Color]::FromArgb(255, 37, 244, 238))
Tri 9 ([System.Drawing.Color]::FromArgb(255, 254, 44, 85))
Tri 0 ([System.Drawing.Color]::White)
$g.Dispose()

$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$png = $ms.ToArray()
$fs = [System.IO.File]::Create((Join-Path $PSScriptRoot 'app.ico'))
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)             # ICONDIR
$bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0) # 256x256, no palette
$bw.Write([uint16]1); $bw.Write([uint16]32)
$bw.Write([uint32]$png.Length); $bw.Write([uint32]22)
$bw.Write($png)
$bw.Close(); $fs.Close(); $bmp.Dispose()

# --- compile ---
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$outName = if ($Test) { 'TikTokConverter-test.exe' } else { 'TikTokConverter.exe' }
$define = if ($Test) { '-define:TESTHOOKS' } else { '-define:RELEASE' }
& $csc -nologo -target:winexe "-out:$outName" $define -win32icon:app.ico `
    -r:System.Windows.Forms.dll -r:System.Drawing.dll -r:System.IO.Compression.dll -r:System.IO.Compression.FileSystem.dll `
    -resource:TikTokConverter.ps1,TikTokConverter.ps1 `
    -resource:app.ico,app.ico `
    Launcher.cs
if ($LASTEXITCODE -ne 0) { throw 'Compile failed' }

if ($Test) { Write-Host "Built $outName (test hooks ON, do not distribute)"; return }

# the file to send to friends: first run installs it (copy, FFmpeg, Desktop + Start menu shortcuts)
New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot 'dist') -Force | Out-Null
Copy-Item TikTokConverter.exe (Join-Path $PSScriptRoot 'dist\TikTokConverter-Setup.exe') -Force

if ($CopyToDesktop) {
    Copy-Item TikTokConverter.exe ([Environment]::GetFolderPath('Desktop')) -Force
}
Write-Host 'Built TikTokConverter.exe'
