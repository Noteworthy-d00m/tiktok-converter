# TikTok Converter

A small Windows app that converts any video to TikTok's vertical format (1080x1920, H.264/AAC MP4) with
visually lossless quality, and lets you trim clips on a CapCut-style timeline first.

## Features

- Drag and drop videos, batch convert, progress bar
- Player with a draggable timeline (thumbnails, time ruler, start/end handles) to trim each clip
- Layouts: blurred background (nothing cropped), center crop, or black bars
- Quality: visually lossless (CRF 14) or high (CRF 18, smaller files)
- Frame-rate cap (30 / 60 fps), GPU encoding (NVENC / AMF / QuickSync) when available, CPU otherwise
- Already-vertical 1080x1920 H.264 files are remuxed instantly with no re-encode
- Never overwrites: repeat conversions become `name_tiktok_2.mp4`, `_3`, ...
- Remembers your settings, optional sound and "open folder" when done

## Install (for users)

Download `TikTokConverter-Setup.exe` from the [Releases](../../releases) page and run it. On first run it:

1. copies the app to `%LOCALAPPDATA%\TikTokConverter`
2. downloads FFmpeg (about 110 MB) if you don't already have it
3. adds Desktop and Start menu shortcuts (plus an uninstall shortcut)

Windows may show "Windows protected your PC" because the file isn't code-signed: click **More info**, then
**Run anyway**. Requires Windows 10/11 and internet on first run. No admin rights needed.

## How it's built

| File | Purpose |
| --- | --- |
| `TikTokConverter.ps1` | The whole app: WinForms UI + WPF media player, driving FFmpeg |
| `Launcher.cs` | Tiny C# exe that embeds the script; handles install, FFmpeg download, shortcuts, uninstall |
| `Build.ps1` | Generates `app.ico`, compiles the exe with the C# compiler built into Windows |
| `TikTokConverter.bat` | Dev shortcut: runs the script directly without building |

No Python, Node or SDK needed. To build:

```powershell
powershell -ExecutionPolicy Bypass -File .\Build.ps1
```

This produces `TikTokConverter.exe` and `dist\TikTokConverter-Setup.exe` (same file). Add `-CopyToDesktop` to also
copy it to your Desktop.

### Testing hooks

`Launcher.cs` honours `TTC_INSTALL_DIR`, `TTC_SHORTCUT_DIR`, `TTC_YES`, `TTC_NO_LAUNCH`, `TTC_FFMPEG_ZIP` and
`TTC_NO_SYSTEM_FFMPEG` so the installer can be tested without touching the real machine. The script has a
headless self-test mode that runs when `TTC_TEST_FILE` is set.

## FFmpeg

FFmpeg is not bundled. The installer downloads a Windows build from
[gyan.dev](https://www.gyan.dev/ffmpeg/builds/) (fallback: [BtbN](https://github.com/BtbN/FFmpeg-Builds)) and
runs it as a separate program. FFmpeg is licensed under the LGPL/GPL, see <https://ffmpeg.org/legal.html>.
