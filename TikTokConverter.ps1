Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -TypeDefinition @'
public class VideoItem {
    public string Path = "";
    public string Start = "";
    public string End = "";
    public override string ToString() {
        string t = "";
        if (Start != "" || End != "")
            t = "   [trim " + (Start == "" ? "0" : Start) + " - " + (End == "" ? "end" : End) + "]";
        return Path + t;
    }
}
'@

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Dwm {
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
}
'@

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, WindowsFormsIntegration

Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition @'
public class DbPanel : System.Windows.Forms.Panel {
    public DbPanel() {
        this.DoubleBuffered = true;
        this.SetStyle(System.Windows.Forms.ControlStyles.ResizeRedraw, true);
    }
}
'@

$inv = [Globalization.CultureInfo]::InvariantCulture
$appHome = if ($env:TTC_HOME) { $env:TTC_HOME } else { $PSScriptRoot }

# ---------- helpers ----------
function Find-Tool([string]$name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $roots = @(
        (Join-Path $appHome 'ffmpeg\bin'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        'C:\ffmpeg\bin', 'C:\Program Files\ffmpeg\bin'
    )
    foreach ($r in $roots) {
        if (Test-Path $r) {
            $hit = Get-ChildItem $r -Filter "$name.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

function Run-Capture([string]$exe, [string]$argLine) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = $argLine
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Out = $out; Err = $errTask.Result }
}

function Get-Gpu-Encoder([string]$ffmpeg) {
    foreach ($enc in 'h264_nvenc', 'h264_amf', 'h264_qsv') {
        $r = Run-Capture $ffmpeg "-hide_banner -loglevel error -f lavfi -i color=c=black:s=256x256:d=0.2 -c:v $enc -f null -"
        if ($r.Code -eq 0) { return $enc }
    }
    return $null
}

function Probe([string]$ffprobe, [string]$file) {
    $r = Run-Capture $ffprobe "-v error -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate:stream_side_data=rotation:stream_tags=rotate:format=duration -of default=nw=1 `"$file`""
    $info = @{ Codec = ''; W = 0; H = 0; Dur = 0.0; Fps = 0.0; Rot = 0 }
    foreach ($line in $r.Out -split "`r?`n") {
        if ($line -match '^(?:TAG:)?rotat(?:e|ion)=(-?\d+)') { if ([int]$Matches[1] -ne 0) { $info.Rot = [int]$Matches[1] }; continue }
        if ($line -match '^codec_name=(.+)$') { $info.Codec = $Matches[1] }
        elseif ($line -match '^width=(\d+)') { $info.W = [int]$Matches[1] }
        elseif ($line -match '^height=(\d+)') { $info.H = [int]$Matches[1] }
        elseif ($line -match '^r_frame_rate=(\d+)/(\d+)') {
            if ([double]$Matches[2] -gt 0) { $info.Fps = [double]$Matches[1] / [double]$Matches[2] }
        }
        elseif ($line -match '^duration=([\d\.]+)') { $info.Dur = [double]::Parse($Matches[1], $inv) }
    }
    return $info
}

# Accepts blank (-> $null), seconds (5, 12.5), mm:ss or hh:mm:ss. Returns -1 when invalid.
function Parse-Time([string]$s) {
    $s = $s.Trim()
    if ($s -eq '') { return $null }
    $parts = $s -split ':'
    if ($parts.Count -gt 3) { return -1 }
    $total = 0.0
    foreach ($p in $parts) {
        $v = 0.0
        if (-not [double]::TryParse($p, [Globalization.NumberStyles]::Float, $inv, [ref]$v) -or $v -lt 0) { return -1 }
        $total = $total * 60 + $v
    }
    return $total
}

function Fmt([double]$n) { return $n.ToString('0.###', $inv) }

$script:ffmpeg = Find-Tool 'ffmpeg'
$script:ffprobe = Find-Tool 'ffprobe'
$script:gpuEnc = $null
$script:gpuChecked = $false
$script:queue = New-Object System.Collections.ArrayList
$script:current = $null
$script:proc = $null
$script:cancel = $false
$script:loading = $false
$script:done = 0; $script:failed = 0; $script:total = 0
$script:lastOut = $null

# ---------- theme ----------
function RGB($r, $g, $b) { return [System.Drawing.Color]::FromArgb($r, $g, $b) }
$cBg = RGB 20 20 28
$cHeader = RGB 10 10 15
$cPanel = RGB 34 34 48
$cBtn = RGB 58 58 80
$cBtnHover = RGB 80 80 108
$cText = RGB 238 238 248
$cMuted = RGB 150 150 176
$cRed = RGB 254 44 85
$cRedHover = RGB 255 90 120
$cCyan = RGB 37 244 238
$cCyanHover = RGB 130 250 246
$cDark = RGB 12 12 18

# ---------- UI ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'TikTok Converter'
$form.ClientSize = New-Object System.Drawing.Size(1124, 690)
$form.StartPosition = 'CenterScreen'
$form.AllowDrop = $true
$form.BackColor = $cBg
$form.ForeColor = $cText
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$iconPath = Join-Path $PSScriptRoot 'app.ico'
if (Test-Path $iconPath) { try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch {} }
$form.Add_Shown({
        try { $v = 1; [void][Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4) } catch {}
    })

function New-Label($text, $x, $y, $w = 110) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, 24)
    $l.TextAlign = 'MiddleLeft'; $l.ForeColor = $cText; $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}
function New-Combo($items, $x, $y, $w) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'; $c.FlatStyle = 'Flat'
    $c.BackColor = $cPanel; $c.ForeColor = $cText
    $c.Location = New-Object System.Drawing.Point($x, $y); $c.Size = New-Object System.Drawing.Size($w, 26)
    foreach ($i in $items) { [void]$c.Items.Add($i) }
    $c.DrawMode = 'OwnerDrawFixed'; $c.ItemHeight = 22
    $c.Add_DrawItem({
            param($sender, $e)
            if ($e.Index -lt 0) { return }
            $hot = (([int]$e.State -band [int][System.Windows.Forms.DrawItemState]::Selected) -ne 0) -and
                   (([int]$e.State -band [int][System.Windows.Forms.DrawItemState]::ComboBoxEdit) -eq 0)
            $bg = New-Object System.Drawing.SolidBrush ($(if ($hot) { $cRed } else { $cPanel }))
            $fg = New-Object System.Drawing.SolidBrush $cText
            $e.Graphics.FillRectangle($bg, $e.Bounds)
            $e.Graphics.DrawString([string]$sender.Items[$e.Index], $sender.Font, $fg, ($e.Bounds.X + 4), ($e.Bounds.Y + 2))
            $bg.Dispose(); $fg.Dispose()
        })
    $c.SelectedIndex = 0; return $c
}
function New-Text($x, $y, $w) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y); $t.Size = New-Object System.Drawing.Size($w, 26)
    $t.BackColor = $cPanel; $t.ForeColor = $cText; $t.BorderStyle = 'FixedSingle'
    return $t
}
# kind: 'primary' (red), 'accent' (cyan), 'normal' (slate)
function New-Btn($text, $x, $y, $w, $h = 32, $kind = 'normal') {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'; $b.Cursor = 'Hand'
    $b.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
    switch ($kind) {
        'primary' { $b.BackColor = $cRed; $b.ForeColor = [System.Drawing.Color]::White; $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $cRedHover }
        'accent' { $b.BackColor = $cCyan; $b.ForeColor = $cDark; $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $cCyanHover }
        default { $b.BackColor = $cBtn; $b.ForeColor = $cText; $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.BorderColor = (RGB 110 110 150); $b.FlatAppearance.MouseOverBackColor = $cBtnHover }
    }
    return $b
}

# header
$header = New-Object System.Windows.Forms.Panel
$header.Location = '0,0'; $header.Size = '1124,50'; $header.BackColor = $cHeader
$title = New-Object System.Windows.Forms.Label
$title.Text = 'TikTok Converter'; $title.Location = '14,8'; $title.Size = '300,34'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16); $title.ForeColor = [System.Drawing.Color]::White
$title.BackColor = [System.Drawing.Color]::Transparent
$sub = New-Object System.Windows.Forms.Label
$sub.Text = 'any video  >  1080 x 1920 vertical'; $sub.Location = '810,16'; $sub.Size = '300,22'; $sub.TextAlign = 'MiddleRight'
$sub.ForeColor = $cCyan; $sub.BackColor = [System.Drawing.Color]::Transparent
$header.Controls.AddRange(@($title, $sub))
$stripRed = New-Object System.Windows.Forms.Panel
$stripRed.Location = '0,50'; $stripRed.Size = '562,3'; $stripRed.BackColor = $cRed
$stripCyan = New-Object System.Windows.Forms.Panel
$stripCyan.Location = '562,50'; $stripCyan.Size = '562,3'; $stripCyan.BackColor = $cCyan

$lbl = New-Label 'Drop videos anywhere in this window, or click Add videos' 12 62 600
$lbl.ForeColor = $cMuted

$list = New-Object System.Windows.Forms.ListBox
$list.Location = '12,90'; $list.Size = '610,150'
$list.SelectionMode = 'MultiExtended'; $list.HorizontalScrollbar = $true
$list.AllowDrop = $true
$list.BackColor = $cPanel; $list.ForeColor = $cText; $list.BorderStyle = 'FixedSingle'

$btnAdd = New-Btn 'Add videos...' 12 248 120 34 'accent'
$btnRemove = New-Btn 'Remove' 138 248 90 34
$btnClear = New-Btn 'Clear all' 234 248 90 34
$btnPreview = New-Btn 'Preview frame' 482 248 140 34 'accent'

$lblTrim = New-Label 'Trim selected' 12 296
$lblTrim.ForeColor = $cCyan; $lblTrim.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$lblStart = New-Label 'Start' 124 296 40
$txtStart = New-Text 166 296 80
$lblEnd = New-Label 'End' 258 296 34
$txtEnd = New-Text 294 296 80
$btnClearTrim = New-Btn 'Clear trim' 386 294 94 30
$lblHint = New-Label 'Drag the handles on the timeline (right), or type times: 5, 1:30, 0:01:30.5' 12 326 610
$lblHint.ForeColor = $cMuted

$lblMode = New-Label 'Layout' 12 362
$cmbMode = New-Combo @('Blurred background (no cropping)', 'Center crop (fills screen)', 'Black bars') 124 362 320
$lblQ = New-Label 'Quality' 12 396
$cmbQ = New-Combo @('Visually lossless (CRF 14)', 'High (CRF 18, smaller files)') 124 396 320
$lblFps = New-Label 'Frame rate' 12 430
$cmbFps = New-Combo @('Keep original', 'Cap at 30 fps', 'Cap at 60 fps') 124 430 320
$lblEnc = New-Label 'Encoder' 12 464
$cmbEnc = New-Combo @('Auto (GPU if available)', 'CPU only (best quality per MB)') 124 464 320
$lblOut = New-Label 'Save to' 12 498
$txtOut = New-Text 124 498 396
$txtOut.Text = [Environment]::GetFolderPath('MyVideos') + '\TikTok'
$btnBrowse = New-Btn 'Browse' 530 496 92 30

$chkOpen = New-Object System.Windows.Forms.CheckBox
$chkOpen.Text = 'Open folder when done'; $chkOpen.Location = '124,534'; $chkOpen.Size = '190,24'; $chkOpen.Checked = $true
$chkOpen.ForeColor = $cText; $chkOpen.BackColor = [System.Drawing.Color]::Transparent
$chkSound = New-Object System.Windows.Forms.CheckBox
$chkSound.Text = 'Play sound when done'; $chkSound.Location = '326,534'; $chkSound.Size = '190,24'; $chkSound.Checked = $true
$chkSound.ForeColor = $cText; $chkSound.BackColor = [System.Drawing.Color]::Transparent

$btnGo = New-Btn 'Convert' 12 574 150 42 'primary'
$btnGo.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$btnStop = New-Btn 'Stop' 168 574 80 42; $btnStop.Enabled = $false
$btnOpen = New-Btn 'Open folder' 254 574 120 42
$btnInstall = New-Btn 'Install FFmpeg' 480 574 142 42 'accent'
$btnInstall.Visible = (-not $script:ffmpeg)

$barTrack = New-Object System.Windows.Forms.Panel
$barTrack.Location = '12,630'; $barTrack.Size = '610,14'; $barTrack.BackColor = (RGB 48 48 66)
$barFill = New-Object System.Windows.Forms.Panel
$barFill.Location = '0,0'; $barFill.Size = '0,14'; $barFill.BackColor = $cRed
$barTrack.Controls.Add($barFill)
function Set-Bar([int]$v) { $barFill.Width = [int]($barTrack.Width * [Math]::Min(1000, [Math]::Max(0, $v)) / 1000) }

$status = New-Label '' 12 652 610
$status.ForeColor = $cCyan
$status.Text = if ($script:ffmpeg) { 'Ready.' } else { 'FFmpeg not found. Click "Install FFmpeg" (uses winget), then restart this app.' }

$form.Controls.AddRange(@($header, $stripRed, $stripCyan, $lbl, $list, $btnAdd, $btnRemove, $btnClear, $btnPreview,
        $lblTrim, $lblStart, $txtStart, $lblEnd, $txtEnd, $btnClearTrim, $lblHint,
        $lblMode, $cmbMode, $lblQ, $cmbQ, $lblFps, $cmbFps, $lblEnc, $cmbEnc, $lblOut, $txtOut, $btnBrowse,
        $chkOpen, $chkSound, $btnGo, $btnStop, $btnOpen, $btnInstall, $barTrack, $status))

# ---------- video player + timeline (right column) ----------
$mediaEl = New-Object System.Windows.Controls.MediaElement
$mediaEl.LoadedBehavior = 'Manual'; $mediaEl.UnloadedBehavior = 'Manual'
$mediaEl.Stretch = 'Uniform'; $mediaEl.ScrubbingEnabled = $true; $mediaEl.Volume = 0.8
$mediaHost = New-Object System.Windows.Forms.Integration.ElementHost
$mediaHost.Location = '650,62'; $mediaHost.Size = '462,300'; $mediaHost.BackColor = [System.Drawing.Color]::Black
$mediaHost.Child = $mediaEl; $mediaHost.Visible = $false

$placeholder = New-Object System.Windows.Forms.Label
$placeholder.Location = '650,62'; $placeholder.Size = '462,300'; $placeholder.BackColor = $cHeader
$placeholder.ForeColor = $cMuted; $placeholder.TextAlign = 'MiddleCenter'
$placeholder.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$placeholder.Text = "Add a video and click it in the list`r`nto preview and trim it here"

$btnPlay = New-Btn 'Play' 650 370 90 34 'accent'
$lblClock = New-Label '0:00.00 / 0:00.00' 746 370 146
$lblClock.Font = New-Object System.Drawing.Font('Consolas', 9)
$btnSetStart = New-Btn 'Set start [' 894 370 104 34
$btnSetEnd = New-Btn 'Set end ]' 1004 370 108 34

$timeline = New-Object DbPanel
$timeline.Location = '650,412'; $timeline.Size = '462,88'; $timeline.BackColor = $cBg

$lblInfo = New-Label '' 650 506 462
$lblInfo.ForeColor = $cCyan; $lblInfo.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$lblHint2 = New-Label 'Drag the cyan handles to trim. Click the timeline to scrub.' 650 532 462
$lblHint2.ForeColor = $cMuted

$form.Controls.AddRange(@($mediaHost, $placeholder, $btnPlay, $lblClock, $btnSetStart, $btnSetEnd, $timeline, $lblInfo, $lblHint2))

# The timeline replaces the typed Start/End row. The text boxes stay as hidden storage; only Reset trim is kept, next to the timeline.
foreach ($c in @($lblTrim, $lblStart, $txtStart, $lblEnd, $txtEnd, $lblHint)) { $c.Visible = $false }
$btnClearTrim.Text = 'Reset trim'; $btnClearTrim.Location = '1000,502'; $btnClearTrim.Size = '112,30'
$lblInfo.Size = '340,24'
$shift = 46
foreach ($c in @($lblMode, $cmbMode, $lblQ, $cmbQ, $lblFps, $cmbFps, $lblEnc, $cmbEnc, $lblOut, $txtOut, $btnBrowse,
        $chkOpen, $chkSound, $btnGo, $btnStop, $btnOpen, $btnInstall, $barTrack, $status)) { $c.Top -= $shift }
$form.ClientSize = New-Object System.Drawing.Size(1124, 644)

# ---------- settings ----------
$settingsFile = if ($env:TTC_TEST_FILE) { Join-Path $env:TEMP 'ttc_test_settings.json' } else { Join-Path $env:APPDATA 'TikTokConverter\settings.json' }
function Load-Settings {
    if (-not (Test-Path $settingsFile)) { return }
    try {
        $s = Get-Content $settingsFile -Raw | ConvertFrom-Json
        foreach ($pair in @(@($cmbMode, 'Mode'), @($cmbQ, 'Quality'), @($cmbFps, 'Fps'), @($cmbEnc, 'Enc'))) {
            $v = $s.($pair[1])
            if ($null -ne $v -and [int]$v -ge 0 -and [int]$v -lt $pair[0].Items.Count) { $pair[0].SelectedIndex = [int]$v }
        }
        if ($s.Out) { $txtOut.Text = [string]$s.Out }
        if ($null -ne $s.OpenWhenDone) { $chkOpen.Checked = [bool]$s.OpenWhenDone }
        if ($null -ne $s.Sound) { $chkSound.Checked = [bool]$s.Sound }
    }
    catch {}
}
function Save-Settings {
    try {
        New-Item -ItemType Directory -Path (Split-Path $settingsFile) -Force | Out-Null
        @{ Mode = $cmbMode.SelectedIndex; Quality = $cmbQ.SelectedIndex; Fps = $cmbFps.SelectedIndex
            Enc = $cmbEnc.SelectedIndex; Out = $txtOut.Text; OpenWhenDone = $chkOpen.Checked; Sound = $chkSound.Checked
        } | ConvertTo-Json | Set-Content -Path $settingsFile -Encoding UTF8
    }
    catch {}
}
Load-Settings

# ---------- list handling ----------
$videoExt = '.mp4', '.mov', '.mkv', '.avi', '.webm', '.m4v', '.wmv', '.flv', '.mts', '.m2ts', '.3gp'
function Add-FilesCore($paths) {
    foreach ($p in $paths) {
        if (Test-Path $p -PathType Container) {
            Add-FilesCore (Get-ChildItem $p -File | ForEach-Object FullName)
        }
        elseif ($videoExt -contains ([IO.Path]::GetExtension($p).ToLower())) {
            $exists = $false
            foreach ($it in $list.Items) { if ($it.Path -eq $p) { $exists = $true; break } }
            if (-not $exists) { $item = New-Object VideoItem; $item.Path = $p; [void]$list.Items.Add($item) }
        }
    }
}
function Add-Files($paths) {
    Add-FilesCore $paths
    # select something so the trim boxes always have a target
    if ($list.SelectedItems.Count -eq 0 -and $list.Items.Count -gt 0) { $list.SetSelected($list.Items.Count - 1, $true) }
}
$dragEnter = { if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } }
$dragDrop = { Add-Files ($_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)) }
$form.Add_DragEnter($dragEnter); $form.Add_DragDrop($dragDrop)
$list.Add_DragEnter($dragEnter); $list.Add_DragDrop($dragDrop)

# Re-render list text (trim tags) while keeping the selection
function Refresh-List {
    $script:loading = $true
    $sel = @($list.SelectedIndices | ForEach-Object { $_ })
    for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.Items[$i] = $list.Items[$i] }
    foreach ($i in $sel) { if ($i -lt $list.Items.Count) { $list.SetSelected($i, $true) } }
    $script:loading = $false
}

$list.Add_SelectedIndexChanged({
        if ($script:loading) { return }
        $script:loading = $true
        if ($list.SelectedItems.Count -eq 1) {
            $txtStart.Text = $list.SelectedItem.Start; $txtEnd.Text = $list.SelectedItem.End
        }
        else { $txtStart.Text = ''; $txtEnd.Text = '' }
        $script:loading = $false
        if ($list.SelectedItems.Count -eq 1) { Load-Editor $list.SelectedItem } else { Unload-Editor }
    })
$storeTrim = {
    if ($script:loading) { return }
    foreach ($it in $list.SelectedItems) { $it.Start = $txtStart.Text.Trim(); $it.End = $txtEnd.Text.Trim() }
    Refresh-List
    Sync-EditorFromText
}
$txtStart.Add_TextChanged($storeTrim); $txtEnd.Add_TextChanged($storeTrim)
$btnClearTrim.Add_Click({
        foreach ($it in $list.SelectedItems) { $it.Start = ''; $it.End = '' }
        $script:loading = $true; $txtStart.Text = ''; $txtEnd.Text = ''; $script:loading = $false
        Refresh-List
        Sync-EditorFromText
    })

$btnAdd.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Multiselect = $true
        $dlg.Filter = 'Videos|*.mp4;*.mov;*.mkv;*.avi;*.webm;*.m4v;*.wmv;*.flv;*.mts;*.m2ts;*.3gp|All files|*.*'
        if ($dlg.ShowDialog() -eq 'OK') { Add-Files $dlg.FileNames }
    })
$btnRemove.Add_Click({ foreach ($i in @($list.SelectedItems)) { $list.Items.Remove($i) } })
$btnClear.Add_Click({ $list.Items.Clear() })
$btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog() -eq 'OK') { $txtOut.Text = $dlg.SelectedPath }
    })
$btnOpen.Add_Click({
        if (-not (Test-Path $txtOut.Text)) { New-Item -ItemType Directory -Path $txtOut.Text -Force | Out-Null }
        Start-Process explorer.exe $txtOut.Text
    })
$btnInstall.Add_Click({
        Start-Process powershell -ArgumentList '-NoExit', '-Command', 'winget install --id Gyan.FFmpeg -e --accept-source-agreements --accept-package-agreements; Write-Host "Done. Close this window and restart TikTok Converter."'
    })

# ---------- editor: player + draggable timeline ----------
$script:ed = $null
$script:pos = 0.0
$script:playing = $false
$script:drag = ''
$script:thumbBmp = $null
$script:thumbCache = @{}
$script:proxyTried = $false
$script:seekSw = [Diagnostics.Stopwatch]::StartNew()
$tmpDir = Join-Path $env:TEMP 'TikTokConverter'
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$trackX0 = 14.0
$trackH = 56

function Fmt-Clock([double]$t) {
    $t = [Math]::Round([Math]::Max(0.0, $t), 2)
    $m = [int][Math]::Floor($t / 60); $s = $t - 60 * $m
    $sec = $s.ToString('00.00', $inv)
    if ($m -ge 60) { $h = [int][Math]::Floor($m / 60); $m = $m % 60; return ('{0}:{1}:{2}' -f $h, $m.ToString('00'), $sec) }
    return ('{0}:{1}' -f $m, $sec)
}
function Fmt-Tick([double]$t) {
    $m = [int][Math]::Floor($t / 60); $s = [int]($t - 60 * $m)
    if ($m -ge 60) { $h = [int][Math]::Floor($m / 60); $m = $m % 60; return ('{0}:{1:00}:{2:00}' -f $h, $m, $s) }
    return ('{0}:{1:00}' -f $m, $s)
}
function TimeToX([double]$t) {
    $tw = $timeline.Width - 2 * $trackX0
    return $trackX0 + ($t / $script:ed.Dur) * $tw
}
function XToTime([double]$x) {
    $tw = $timeline.Width - 2 * $trackX0
    $t = (($x - $trackX0) / $tw) * $script:ed.Dur
    return [Math]::Max(0.0, [Math]::Min($script:ed.Dur, $t))
}

function Update-Info {
    if (-not $script:ed) { $lblInfo.Text = ''; $lblClock.Text = '0:00.00 / 0:00.00'; return }
    $ed = $script:ed
    $lblInfo.Text = "Start $(Fmt-Clock $ed.Start)      End $(Fmt-Clock $ed.End)      Length $(Fmt-Clock ($ed.End - $ed.Start))"
    $lblClock.Text = "$(Fmt-Clock $script:pos) / $(Fmt-Clock $ed.Dur)"
}

function Seek-To([double]$t, [bool]$force = $false) {
    if (-not $script:ed) { return }
    $t = [Math]::Max(0.0, [Math]::Min($script:ed.Dur, $t))
    $script:pos = $t
    if ($force -or $script:seekSw.ElapsedMilliseconds -ge 40) {
        $mediaEl.Position = [TimeSpan]::FromSeconds($t)
        $script:seekSw.Restart()
    }
    Update-Info; $timeline.Invalidate()
}

# Apply a new trim range from the timeline: updates the item and the Start/End boxes
function Set-Trim([double]$s, [double]$e) {
    $ed = $script:ed
    $s = [Math]::Round($s, 2); $e = [Math]::Round($e, 2)
    $ed.Start = $s; $ed.End = $e
    $item = $ed.Item
    $item.Start = if ($s -gt 0.04) { Fmt-Clock $s } else { '' }
    $item.End = if ($e -lt ($ed.Dur - 0.04)) { Fmt-Clock $e } else { '' }
    $script:loading = $true; $txtStart.Text = $item.Start; $txtEnd.Text = $item.End; $script:loading = $false
    Update-Info; $timeline.Invalidate()
}

# Typed times -> timeline
function Sync-EditorFromText {
    $ed = $script:ed
    if (-not $ed -or $list.SelectedItems.Count -ne 1 -or -not [object]::ReferenceEquals($list.SelectedItem, $ed.Item)) { return }
    $s = Parse-Time $txtStart.Text; $e = Parse-Time $txtEnd.Text
    if ($s -eq -1 -or $e -eq -1) { return }
    $ss = if ($null -ne $s) { [Math]::Min([double]$s, $ed.Dur) } else { 0.0 }
    $ee = if ($null -ne $e) { [Math]::Min([double]$e, $ed.Dur) } else { $ed.Dur }
    if ($ee -gt $ss) { $ed.Start = $ss; $ed.End = $ee; Update-Info; $timeline.Invalidate() }
}

function Get-Thumbs($info, [string]$path) {
    if ($script:thumbCache.ContainsKey($path)) { return $script:thumbCache[$path] }
    $tw = [int]($timeline.Width - 2 * $trackX0)
    $bmp = New-Object System.Drawing.Bitmap $tw, $trackH
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear($cPanel)
    $cellW = 0.0; $i = 0; $x = 0.0
    while ($x -lt $tw -and $i -lt 24) {
        $t = if ($cellW -eq 0.0) { [Math]::Min($info.Dur * 0.02, 1.0) } else { (($x + $cellW / 2) / $tw) * $info.Dur }
        $f = Join-Path $tmpDir "th_$i.jpg"
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        $r = Run-Capture $script:ffmpeg "-y -hide_banner -loglevel error -ss $(Fmt $t) -i `"$path`" -frames:v 1 -vf scale=-2:$trackH `"$f`""
        if ($r.Code -ne 0 -or -not (Test-Path $f)) { break }
        $bytes = [IO.File]::ReadAllBytes($f)
        $img = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream(, $bytes)))
        if ($cellW -eq 0.0) { $cellW = [double]$img.Width }
        $g.DrawImage($img, [float]$x, [float]0, [float]$img.Width, [float]$trackH)
        $img.Dispose()
        $x += $cellW; $i++
    }
    $g.Dispose()
    $script:thumbCache[$path] = $bmp
    return $bmp
}

# Some formats (mkv/webm/HEVC, rotated phone clips) don't play in the built-in player: make a small H.264 proxy
function Use-Proxy {
    $script:proxyTried = $true
    $path = $script:ed.Path
    $status.Text = 'Preparing preview (one-time quick proxy for this file)...'
    $px = Join-Path $tmpDir ('proxy_' + [Math]::Abs($path.GetHashCode()) + '.mp4')
    if (-not (Test-Path $px)) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:ffmpeg
        $psi.Arguments = "-y -hide_banner -loglevel error -i `"$path`" -vf scale=-2:360,format=yuv420p -c:v libx264 -preset ultrafast -crf 30 -c:a aac -b:a 96k -movflags +faststart `"$px`""
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $null = $p.StandardError.ReadToEndAsync()
        while (-not $p.HasExited) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
        if ($p.ExitCode -ne 0) { Remove-Item $px -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path $px) {
        $mediaEl.Source = New-Object System.Uri($px)
        $mediaEl.Play()
        $status.Text = 'Ready.'
    }
    else { $status.Text = 'Cannot preview this file (converting it still works).' }
}

function Unload-Editor {
    if ($script:playing) { try { $mediaEl.Pause() } catch {} }
    $script:playing = $false; $btnPlay.Text = 'Play'
    try { $mediaEl.Stop(); $mediaEl.Source = $null } catch {}
    $script:ed = $null; $script:thumbBmp = $null; $script:pos = 0.0
    $mediaHost.Visible = $false; $placeholder.Visible = $true
    Update-Info; $timeline.Invalidate()
}

function Load-Editor($item) {
    if (-not $script:ffprobe -or -not $script:ffmpeg) { return }
    if ($script:ed -and [object]::ReferenceEquals($script:ed.Item, $item)) { return }
    Unload-Editor
    $form.Cursor = 'WaitCursor'; $status.Text = 'Loading video...'; $form.Refresh()
    try {
        $info = Probe $script:ffprobe $item.Path
        if ($info.Dur -le 0) { $status.Text = 'Could not read this video.'; return }
        $s = Parse-Time $item.Start; $e = Parse-Time $item.End
        $ss = if ($null -ne $s -and $s -ne -1) { [Math]::Min([double]$s, $info.Dur) } else { 0.0 }
        $ee = if ($null -ne $e -and $e -ne -1) { [Math]::Min([double]$e, $info.Dur) } else { $info.Dur }
        if ($ee -le $ss) { $ss = 0.0; $ee = $info.Dur }
        $script:ed = @{ Item = $item; Path = $item.Path; Dur = [double]$info.Dur; Start = $ss; End = $ee }
        $script:pos = $ss
        $script:thumbBmp = Get-Thumbs $info $item.Path
        $script:proxyTried = $false
        $placeholder.Visible = $false; $mediaHost.Visible = $true
        Update-Info; $timeline.Invalidate()
        if ($info.Rot -ne 0) { Use-Proxy }
        else { $mediaEl.Source = New-Object System.Uri($item.Path); $mediaEl.Play() }   # MediaOpened pauses on first frame
        $status.Text = 'Ready.'
    }
    finally { $form.Cursor = 'Default' }
}

function Toggle-Play {
    if (-not $script:ed) { return }
    if ($script:playing) {
        $mediaEl.Pause(); $script:playing = $false; $btnPlay.Text = 'Play'
    }
    else {
        $p = $mediaEl.Position.TotalSeconds
        if ($p -lt ($script:ed.Start - 0.05) -or $p -ge ($script:ed.End - 0.05)) { Seek-To $script:ed.Start $true }
        $mediaEl.Play(); $script:playing = $true; $btnPlay.Text = 'Pause'
    }
}

$mediaEl.Add_MediaOpened({
        if (-not $script:ed) { return }
        if (-not $mediaEl.HasVideo -and -not $script:proxyTried) { Use-Proxy; return }
        $mediaEl.Pause(); $script:playing = $false; $btnPlay.Text = 'Play'
        Seek-To $script:ed.Start $true
    })
$mediaEl.Add_MediaFailed({
        if ($script:ed -and -not $script:proxyTried) { Use-Proxy }
        else { $status.Text = 'Cannot preview this file (converting it still works).' }
    })
$mediaEl.Add_MediaEnded({ $script:playing = $false; $btnPlay.Text = 'Play' })

$btnPlay.Add_Click({ Toggle-Play })
$btnSetStart.Add_Click({
        if ($script:ed -and $script:pos -lt ($script:ed.End - 0.2)) { Set-Trim $script:pos $script:ed.End; Refresh-List }
    })
$btnSetEnd.Add_Click({
        if ($script:ed -and $script:pos -gt ($script:ed.Start + 0.2)) { Set-Trim $script:ed.Start $script:pos; Refresh-List }
    })
$form.KeyPreview = $true
$form.Add_KeyDown({
        param($sender, $ev)
        if ($ev.KeyCode -eq 'Space' -and -not ($form.ActiveControl -is [System.Windows.Forms.TextBox]) -and -not ($form.ActiveControl -is [System.Windows.Forms.ComboBox]) -and -not ($form.ActiveControl -is [System.Windows.Forms.Button])) {
            Toggle-Play; $ev.SuppressKeyPress = $true; $ev.Handled = $true
        }
    })

# playhead follows playback and stops at the trim end
$playTimer = New-Object System.Windows.Forms.Timer
$playTimer.Interval = 40
$playTimer.Add_Tick({
        if (-not $script:ed -or -not $script:playing) { return }
        $p = $mediaEl.Position.TotalSeconds
        $script:pos = $p
        if ($p -ge $script:ed.End) {
            $mediaEl.Pause(); $script:playing = $false; $btnPlay.Text = 'Play'
            Seek-To $script:ed.End $true
            return
        }
        Update-Info; $timeline.Invalidate()
    })
$playTimer.Start()

$timeline.Add_Paint({
        param($sender, $pe)
        $g = $pe.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $x0 = $trackX0; $tw = $sender.Width - 2 * $x0; $x1 = $x0 + $tw; $top = 6
        $g.Clear($cBg)
        $bPanel = New-Object System.Drawing.SolidBrush $cPanel
        $g.FillRectangle($bPanel, [float]$x0, [float]$top, [float]$tw, [float]$trackH); $bPanel.Dispose()
        if (-not $script:ed) {
            $f = New-Object System.Drawing.Font('Segoe UI', 9)
            $bm = New-Object System.Drawing.SolidBrush $cMuted
            $g.DrawString('Timeline', $f, $bm, [float]($x0 + 8), [float]($top + 18)); $f.Dispose(); $bm.Dispose()
            return
        }
        if ($script:thumbBmp) { $g.DrawImage($script:thumbBmp, [float]$x0, [float]$top) }
        $dur = $script:ed.Dur
        $xs = TimeToX $script:ed.Start; $xe = TimeToX $script:ed.End

        # dim everything outside the kept range
        $dim = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(175, 8, 8, 14))
        $g.FillRectangle($dim, [float]$x0, [float]$top, [float]($xs - $x0), [float]$trackH)
        $g.FillRectangle($dim, [float]$xe, [float]$top, [float]($x1 - $xe), [float]$trackH)
        $dim.Dispose()

        # cyan frame + handles
        $pen = New-Object System.Drawing.Pen $cCyan, 3
        $g.DrawLine($pen, [float]$xs, [float]($top - 1), [float]$xe, [float]($top - 1))
        $g.DrawLine($pen, [float]$xs, [float]($top + $trackH + 1), [float]$xe, [float]($top + $trackH + 1))
        $pen.Dispose()
        $bc = New-Object System.Drawing.SolidBrush $cCyan
        $g.FillRectangle($bc, [float]($xs - 12), [float]($top - 2), [float]12, [float]($trackH + 4))
        $g.FillRectangle($bc, [float]$xe, [float]($top - 2), [float]12, [float]($trackH + 4))
        $bc.Dispose()
        $grip = New-Object System.Drawing.Pen $cDark, 2
        $g.DrawLine($grip, [float]($xs - 6), [float]($top + 16), [float]($xs - 6), [float]($top + $trackH - 14))
        $g.DrawLine($grip, [float]($xe + 6), [float]($top + 16), [float]($xe + 6), [float]($top + $trackH - 14))
        $grip.Dispose()

        # time ruler
        $step = 3600
        foreach ($c in 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600) { if (($c / $dur) * $tw -ge 64) { $step = $c; break } }
        $tickPen = New-Object System.Drawing.Pen $cMuted, 1
        $tf = New-Object System.Drawing.Font('Segoe UI', 8)
        $tb = New-Object System.Drawing.SolidBrush $cMuted
        for ($t = 0.0; $t -le $dur + 0.001; $t += $step) {
            $x = TimeToX $t
            $g.DrawLine($tickPen, [float]$x, [float]($top + $trackH + 4), [float]$x, [float]($top + $trackH + 9))
            if ($x + 30 -le $sender.Width) { $g.DrawString((Fmt-Tick $t), $tf, $tb, [float]($x - 12), [float]($top + $trackH + 9)) }
        }
        $tickPen.Dispose(); $tf.Dispose(); $tb.Dispose()

        # playhead
        $px = TimeToX $script:pos
        $pp = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2
        $g.DrawLine($pp, [float]$px, [float]1, [float]$px, [float]($top + $trackH + 4))
        $pp.Dispose()
        $hb = New-Object System.Drawing.SolidBrush $cRed
        $g.FillEllipse($hb, [float]($px - 5), [float]0, [float]10, [float]10); $hb.Dispose()
    })

$timeline.Add_MouseDown({
        param($sender, $ev)
        if (-not $script:ed -or $ev.Button -ne 'Left') { return }
        $xs = TimeToX $script:ed.Start; $xe = TimeToX $script:ed.End
        if ($ev.X -ge ($xs - 16) -and $ev.X -le ($xs + 2)) { $script:drag = 'start' }
        elseif ($ev.X -ge ($xe - 2) -and $ev.X -le ($xe + 16)) { $script:drag = 'end' }
        else { $script:drag = 'seek'; Seek-To (XToTime $ev.X) $true }
    })
$timeline.Add_MouseMove({
        param($sender, $ev)
        if (-not $script:ed) { return }
        if ($script:drag -eq '') {
            $xs = TimeToX $script:ed.Start; $xe = TimeToX $script:ed.End
            $onHandle = ($ev.X -ge ($xs - 16) -and $ev.X -le ($xs + 2)) -or ($ev.X -ge ($xe - 2) -and $ev.X -le ($xe + 16))
            $sender.Cursor = if ($onHandle) { 'SizeWE' } else { 'Default' }
            return
        }
        $t = XToTime $ev.X
        switch ($script:drag) {
            'start' { $t = [Math]::Min($t, $script:ed.End - 0.2); Set-Trim $t $script:ed.End; Seek-To $t }
            'end' { $t = [Math]::Max($t, $script:ed.Start + 0.2); Set-Trim $script:ed.Start $t; Seek-To $t }
            'seek' { Seek-To $t }
        }
    })
$timeline.Add_MouseUp({
        if ($script:drag -eq '') { return }
        $script:drag = ''
        if ($script:ed) { Seek-To $script:pos $true }
        Refresh-List
    })

# ---------- filters / args ----------
function Get-FilterGraph([int]$modeIdx, [double]$fpsCap) {
    $core = switch ($modeIdx) {
        0 { '[0:v]split=2[a][b];[a]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=30:5[bg];[b]scale=1080:1920:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,setsar=1' }
        1 { '[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1' }
        2 { '[0:v]scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2,setsar=1' }
    }
    $fpsPart = if ($fpsCap -gt 0) { ",fps=$(Fmt $fpsCap)" } else { '' }
    return "$core$fpsPart,format=yuv420p[v]"
}

$progressFile = Join-Path $env:TEMP 'tiktokconv_progress.txt'

function Build-Args($info, $inFile, $outFile, $trimStart, $trimDur) {
    $q = if ($cmbQ.SelectedIndex -eq 0) { 14 } else { 18 }
    $capIdx = $cmbFps.SelectedIndex
    $cap = switch ($capIdx) { 1 { 30.0 } 2 { 60.0 } default { 0.0 } }
    $useCap = if ($cap -gt 0 -and $info.Fps -gt ($cap + 0.5)) { $cap } else { 0.0 }
    $vf = Get-FilterGraph $cmbMode.SelectedIndex $useCap

    $trimArgs = ''
    if ($null -ne $trimStart -and $trimStart -gt 0) { $trimArgs += "-ss $(Fmt $trimStart) " }
    if ($null -ne $trimDur) { $trimArgs += "-t $(Fmt $trimDur) " }
    $pre = "-y -hide_banner -loglevel error -nostats -progress `"$progressFile`" $trimArgs-i `"$inFile`""

    # already vertical 1080x1920 H.264, untrimmed, no fps cap needed: just remux (lossless and instant)
    if ($trimArgs -eq '' -and $useCap -eq 0.0 -and $info.Codec -eq 'h264' -and $info.W -eq 1080 -and $info.H -eq 1920) {
        return "$pre -map 0:v:0 -map 0:a? -c copy -movflags +faststart `"$outFile`""
    }

    $enc = if ($cmbEnc.SelectedIndex -eq 0) { $script:gpuEnc } else { $null }
    $venc = switch ($enc) {
        'h264_nvenc' { "-c:v h264_nvenc -preset p6 -rc vbr -cq $q -b:v 0" }
        'h264_amf' { "-c:v h264_amf -quality quality -rc cqp -qp_i $q -qp_p $q -qp_b $q" }
        'h264_qsv' { "-c:v h264_qsv -preset slow -global_quality $q" }
        default { "-c:v libx264 -preset medium -crf $q" }
    }
    return "$pre -filter_complex `"$vf`" -map `"[v]`" -map 0:a? $venc -c:a aac -b:a 192k -movflags +faststart `"$outFile`""
}

# ---------- preview ----------
$btnPreview.Add_Click({
        if (-not $script:ffmpeg -or -not $script:ffprobe) {
            [void][Windows.Forms.MessageBox]::Show('FFmpeg not found. Click "Install FFmpeg", then restart the app.'); return
        }
        $item = if ($list.SelectedItems.Count -gt 0) { $list.SelectedItems[0] } elseif ($list.Items.Count -gt 0) { $list.Items[0] } else { $null }
        if (-not $item) { [void][Windows.Forms.MessageBox]::Show('Add a video first.'); return }

        $s = Parse-Time $item.Start; $e = Parse-Time $item.End
        if ($s -eq -1 -or $e -eq -1) { [void][Windows.Forms.MessageBox]::Show('Trim times are not valid.'); return }
        $info = Probe $script:ffprobe $item.Path
        $from = if ($null -ne $s) { $s } else { 0.0 }
        $to = if ($null -ne $e) { $e } else { $info.Dur }
        $t = if ($to -gt $from) { $from + ($to - $from) / 2 } else { $from }

        $png = Join-Path $env:TEMP 'tiktokconv_preview.png'
        if (Test-Path $png) { Remove-Item $png -Force -ErrorAction SilentlyContinue }
        $status.Text = 'Rendering preview...'; $form.Refresh()
        $vf = Get-FilterGraph $cmbMode.SelectedIndex 0.0
        $r = Run-Capture $script:ffmpeg "-y -hide_banner -loglevel error -ss $(Fmt $t) -i `"$($item.Path)`" -filter_complex `"$vf`" -map `"[v]`" -frames:v 1 `"$png`""
        $status.Text = 'Ready.'
        if ($r.Code -ne 0 -or -not (Test-Path $png)) {
            [void][Windows.Forms.MessageBox]::Show("Could not render preview.`n`n$($r.Err)", 'FFmpeg error'); return
        }

        $bytes = [IO.File]::ReadAllBytes($png)
        $img = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream(, $bytes)))
        $pv = New-Object System.Windows.Forms.Form
        $pv.Text = 'Preview - ' + [IO.Path]::GetFileName($item.Path)
        $pv.StartPosition = 'CenterParent'
        $pv.ClientSize = New-Object System.Drawing.Size(405, 720)
        $pv.FormBorderStyle = 'FixedDialog'; $pv.MaximizeBox = $false; $pv.MinimizeBox = $false
        $pv.BackColor = $cBg
        $pb = New-Object System.Windows.Forms.PictureBox
        $pb.Dock = 'Fill'; $pb.SizeMode = 'Zoom'; $pb.Image = $img; $pb.BackColor = [System.Drawing.Color]::Black
        $pv.Controls.Add($pb)
        [void]$pv.ShowDialog($form)
        $pv.Dispose(); $img.Dispose()
    })

# ---------- conversion ----------
function Start-Next {
    if ($script:cancel -or $script:queue.Count -eq 0) { Finish; return }
    $item = $script:queue[0]; $script:queue.RemoveAt(0)
    $inFile = $item.Path
    $info = Probe $script:ffprobe $inFile

    $s = Parse-Time $item.Start; $e = Parse-Time $item.End
    $from = if ($null -ne $s) { $s } else { 0.0 }
    $to = if ($null -ne $e -and ($info.Dur -le 0 -or $e -lt $info.Dur)) { $e } else { $info.Dur }
    $dur = if ($to -gt 0) { $to - $from } else { 0.0 }
    if ($to -gt 0 -and $dur -le 0) {
        $script:failed++
        [void][Windows.Forms.MessageBox]::Show("Trim range is empty for:`n$inFile", 'Trim error')
        Start-Next; return
    }
    $trimmed = ($null -ne $e -or $null -ne $s)
    $trimDur = if ($trimmed -and $dur -gt 0) { $dur } else { $null }

    $base = [IO.Path]::GetFileNameWithoutExtension($inFile) + '_tiktok'
    $outFile = Join-Path $txtOut.Text ($base + '.mp4')
    $n = 2
    while (Test-Path -LiteralPath $outFile) {
        $outFile = Join-Path $txtOut.Text ("{0}_{1}.mp4" -f $base, $n)
        $n++
    }
    $script:current = @{ In = $inFile; Out = $outFile; Dur = $dur }
    $tag = if ($trimmed) { "  [trim $(Fmt $from)s - $(Fmt ($from + $dur))s]" } else { '' }
    $status.Text = "Converting: $([IO.Path]::GetFileName($inFile))$tag  ($($script:done + $script:failed + 1) of $($script:total))"
    Set-Bar 0
    if (Test-Path $progressFile) { Remove-Item $progressFile -Force -ErrorAction SilentlyContinue }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:ffmpeg
    $psi.Arguments = Build-Args $info $inFile $outFile $s $trimDur
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $script:proc = [System.Diagnostics.Process]::Start($psi)
    $script:errTask = $script:proc.StandardError.ReadToEndAsync()
}

function Finish {
    $timer.Stop()
    $btnGo.Enabled = $true; $btnStop.Enabled = $false
    Set-Bar 0
    $status.Text = if ($script:cancel) { "Stopped. $($script:done) done, $($script:failed) failed." } else { "Finished: $($script:done) converted, $($script:failed) failed. Saved in $($txtOut.Text)" }
    if (-not $script:cancel -and $script:done -gt 0) {
        if ($chkSound.Checked) { [System.Media.SystemSounds]::Asterisk.Play() }
        if ($chkOpen.Checked) {
            if ($script:lastOut -and (Test-Path -LiteralPath $script:lastOut)) { Start-Process explorer.exe "/select,`"$($script:lastOut)`"" }
            else { Start-Process explorer.exe $txtOut.Text }
        }
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
        if (-not $script:proc) { return }
        if (-not $script:proc.HasExited) {
            try {
                $fs = [IO.File]::Open($progressFile, 'Open', 'Read', 'ReadWrite')
                $sr = New-Object IO.StreamReader($fs); $txt = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
                $m = [regex]::Matches($txt, 'out_time_us=(\d+)')
                if ($m.Count -gt 0 -and $script:current.Dur -gt 0) {
                    $sec = [double]$m[$m.Count - 1].Groups[1].Value / 1e6
                    Set-Bar ([int](1000 * $sec / $script:current.Dur))
                }
            }
            catch {}
            return
        }
        $code = $script:proc.ExitCode
        if ($code -eq 0) { $script:done++; $script:lastOut = $script:current.Out } else {
            $script:failed++
            [void][Windows.Forms.MessageBox]::Show("Failed: $($script:current.In)`n`n$($script:errTask.Result)", 'FFmpeg error')
        }
        $script:proc = $null
        Start-Next
    })

$btnGo.Add_Click({
        if (-not $script:ffmpeg -or -not $script:ffprobe) {
            [void][Windows.Forms.MessageBox]::Show('FFmpeg not found. Click "Install FFmpeg", then restart the app.'); return
        }
        if ($list.Items.Count -eq 0) { [void][Windows.Forms.MessageBox]::Show('Add some videos first.'); return }
        foreach ($it in $list.Items) {
            $s = Parse-Time $it.Start; $e = Parse-Time $it.End
            if ($s -eq -1 -or $e -eq -1 -or ($null -ne $s -and $null -ne $e -and $e -le $s)) {
                [void][Windows.Forms.MessageBox]::Show("Trim times are not valid for:`n$($it.Path)`n`nUse seconds (5), mm:ss (1:30) or hh:mm:ss, and make End later than Start.", 'Trim error')
                return
            }
        }
        New-Item -ItemType Directory -Path $txtOut.Text -Force | Out-Null
        Save-Settings
        if ($cmbEnc.SelectedIndex -eq 0 -and -not $script:gpuChecked) {
            $status.Text = 'Detecting GPU encoder...'; $form.Refresh()
            $script:gpuEnc = Get-Gpu-Encoder $script:ffmpeg
            $script:gpuChecked = $true
        }
        $script:queue.Clear(); foreach ($i in $list.Items) { [void]$script:queue.Add($i) }
        $script:total = $script:queue.Count
        $script:done = 0; $script:failed = 0; $script:cancel = $false; $script:lastOut = $null
        $btnGo.Enabled = $false; $btnStop.Enabled = $true
        Start-Next
        $timer.Start()
    })
$btnStop.Add_Click({
        $script:cancel = $true
        if ($script:proc -and -not $script:proc.HasExited) { try { $script:proc.Kill() } catch {} }
    })
$form.Add_FormClosing({
        Save-Settings
        try { $playTimer.Stop(); $mediaEl.Stop(); $mediaEl.Source = $null } catch {}
        if ($script:proc -and -not $script:proc.HasExited) { try { $script:proc.Kill() } catch {} }
    })

# ---------- headless self-test (used only when TTC_TEST_FILE is set) ----------
if ($env:TTC_TEST_FILE) {
    $form.Show()
    $chkOpen.Checked = $false; $chkSound.Checked = $false
    $txtOut.Text = $env:TTC_TEST_OUT
    Add-Files @($env:TTC_TEST_FILE)                     # goes through the real add + auto-select path
    if ($env:TTC_TEST_START) { $txtStart.Text = $env:TTC_TEST_START }   # goes through the real TextChanged path
    if ($env:TTC_TEST_END) { $txtEnd.Text = $env:TTC_TEST_END }
    $pump = { param($sec) $w = [Diagnostics.Stopwatch]::StartNew(); while ($w.Elapsed.TotalSeconds -lt $sec) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 } }
    & $pump 3
    "EDITOR: loaded=$([bool]$script:ed) dur=$(if ($script:ed) { $script:ed.Dur }) hasVideo=$($mediaEl.HasVideo) host=$($mediaHost.Visible) status=$($status.Text)"
    if ($env:TTC_TEST_DRAG -and $script:ed) {
        $flags = [Reflection.BindingFlags]'NonPublic,Instance'
        $fire = { param($name, $x) $mi = [System.Windows.Forms.Control].GetMethod($name, $flags); $ma = [Windows.Forms.MouseEventArgs]::new([Windows.Forms.MouseButtons]::Left, 1, [int]$x, 20, 0); [void]$mi.Invoke($timeline, [object[]]@($ma)) }
        $xs = TimeToX $script:ed.Start
        & $fire 'OnMouseDown' ($xs - 6)
        & $fire 'OnMouseMove' ($xs + 60)
        & $fire 'OnMouseMove' ($xs + 120)
        & $fire 'OnMouseUp' ($xs + 120)
        $xe = TimeToX $script:ed.End
        & $fire 'OnMouseDown' ($xe + 6)
        & $fire 'OnMouseMove' ($xe - 40)
        & $fire 'OnMouseUp' ($xe - 40)
        & $pump 1
    }
    if ($env:TTC_TEST_PLAY -and $script:ed) {
        Toggle-Play; & $pump 1.5
        "PLAY: pos=$($script:pos) playing=$($script:playing) mediaPos=$($mediaEl.Position.TotalSeconds)"
    }
    if ($env:TTC_SHOT) {
        $form.Activate(); & $pump 0.5
        $bmp = New-Object System.Drawing.Bitmap $form.Width, $form.Height
        $gg = [System.Drawing.Graphics]::FromImage($bmp)
        $gg.CopyFromScreen($form.Location.X, $form.Location.Y, 0, 0, $bmp.Size)
        $gg.Dispose(); $bmp.Save($env:TTC_SHOT); $bmp.Dispose()
    }
    "LIST: " + (($list.Items | ForEach-Object { $_.ToString() }) -join ' | ')
    $btnGo.PerformClick()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $btnGo.Enabled -and $sw.Elapsed.TotalSeconds -lt 120) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    "STATUS: " + $status.Text
    $form.Close(); return
}

[void]$form.ShowDialog()
