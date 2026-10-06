using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// TikTokConverter.exe: first run installs the app (copy, FFmpeg, shortcuts); every later run just opens it.
static class Launcher
{
    const string AppName = "TikTok Converter";
    const string Version = "1.1";   // single source of truth: Build.ps1 reads it for the file name
    const string RegKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\TikTokConverter";
    // { zip url, checksum url, file name to look for in the checksum file (null = file holds just the hash) }
    static readonly string[][] FfmpegSources = {
        new[] { "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip",
                "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip.sha256", null },
        new[] { "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip",
                "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/checksums.sha256", "ffmpeg-master-latest-win64-gpl.zip" }
    };

    // TTC_* variables only exist so the installer can be tested without touching the real machine.
    // They are compiled in only for test builds (Build.ps1 -Test); the release exe ignores them completely.
    static string Env(string name)
    {
#if TESTHOOKS
        return Environment.GetEnvironmentVariable(name);
#else
        return null;
#endif
    }
    static bool TestMode { get { return Env("TTC_INSTALL_DIR") != null; } }
    static string InstallDir
    {
        get
        {
            string d = Env("TTC_INSTALL_DIR");
            return d ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TikTokConverter");
        }
    }
    static string InstalledExe { get { return Path.Combine(InstallDir, "TikTokConverter.exe"); } }
    static string SelfPath { get { return Assembly.GetExecutingAssembly().Location; } }

    [STAThread]
    static void Main(string[] args)
    {
        try
        {
            if (args.Length > 0 && args[0].Equals("/uninstall", StringComparison.OrdinalIgnoreCase)) { Uninstall(); return; }

            bool installed = string.Equals(Path.GetFullPath(SelfPath), Path.GetFullPath(InstalledExe), StringComparison.OrdinalIgnoreCase);
            if (!installed)
            {
                bool update = File.Exists(InstalledExe);
                if (Env("TTC_YES") == null)
                {
                    string msg = (update ? "Update " : "Install ") + AppName + "?\n\n" +
                        "  - Copies the app to " + InstallDir + "\n" +
                        "  - Adds shortcuts on your Desktop and Start menu\n" +
                        (HasFfmpeg() ? "" : "  - Downloads FFmpeg (about 110 MB, needs internet)\n") +
                        "\nNothing else on your PC is changed. You can remove it any time from Start > Uninstall.";
                    if (MessageBox.Show(msg, AppName + " Setup", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
                }
                string error = RunSetup(true);
                if (error != null) MessageBox.Show(error, AppName + " Setup");
                if (Env("TTC_NO_LAUNCH") == null && File.Exists(InstalledExe))
                    Process.Start(new ProcessStartInfo(InstalledExe) { UseShellExecute = false });
                return;
            }

            if (!HasFfmpeg())
            {
                if (MessageBox.Show("FFmpeg (the video engine) is missing.\n\nDownload it now? (about 110 MB, needs internet)",
                        AppName, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                {
                    string error = RunSetup(false);
                    if (error != null) MessageBox.Show(error, AppName + " Setup");
                }
            }
            RunApp();
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, AppName);
        }
    }

    // ---------- run the app ----------
    static void RunApp()
    {
        string dir = Path.Combine(Path.GetTempPath(), "TikTokConverter");
        Directory.CreateDirectory(dir);
        string script = Path.Combine(dir, "TikTokConverter.ps1");
        Extract("TikTokConverter.ps1", script);
        Extract("app.ico", Path.Combine(dir, "app.ico"));

        var psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.EnvironmentVariables["TTC_HOME"] = Path.GetDirectoryName(SelfPath);
        psi.EnvironmentVariables["TTC_VERSION"] = Version;
        Process.Start(psi);
    }

    static void Extract(string resource, string target)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource))
        {
            if (s == null) return;
            using (FileStream f = File.Create(target)) s.CopyTo(f);
        }
    }

    // ---------- FFmpeg detection ----------
    static bool BothIn(string dir)
    {
        return File.Exists(Path.Combine(dir, "ffmpeg.exe")) && File.Exists(Path.Combine(dir, "ffprobe.exe"));
    }

    static bool HasFfmpeg()
    {
        if (BothIn(Path.Combine(InstallDir, "ffmpeg", "bin"))) return true;
        if (Env("TTC_NO_SYSTEM_FFMPEG") != null) return false;   // test hook
        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string p in path.Split(';'))
        {
            try { if (p.Trim().Length > 0 && BothIn(p.Trim())) return true; } catch { }
        }
        foreach (string p in new[] { @"C:\ffmpeg\bin", @"C:\Program Files\ffmpeg\bin" })
            if (BothIn(p)) return true;
        try
        {
            string wg = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WinGet\Packages");
            if (Directory.Exists(wg))
                foreach (string f in Directory.GetFiles(wg, "ffmpeg.exe", SearchOption.AllDirectories))
                    if (BothIn(Path.GetDirectoryName(f))) return true;
        }
        catch { }
        return false;
    }

    // ---------- setup ----------
    // returns null on success, otherwise a message for the user
    static string RunSetup(bool fullInstall)
    {
        string result = null;
        var form = new SetupForm(fullInstall ? "Installing " + AppName : "Getting FFmpeg");
        form.Work = delegate (SetupForm f)
        {
            if (fullInstall)
            {
                f.Status("Copying app files...", 3);
                Directory.CreateDirectory(InstallDir);
                if (!string.Equals(Path.GetFullPath(SelfPath), Path.GetFullPath(InstalledExe), StringComparison.OrdinalIgnoreCase))
                    File.Copy(SelfPath, InstalledExe, true);
            }
            if (!HasFfmpeg())
            {
                string err = InstallFfmpeg(f);
                if (err != null) result = err;
            }
            if (fullInstall)
            {
                f.Status("Creating shortcuts...", 97);
                CreateShortcuts();
            }
            f.Status("Done.", 100);
        };
        form.ShowDialog();
        if (form.Error != null) return "Setup failed: " + form.Error;
        return result;
    }

    static string InstallFfmpeg(SetupForm f)
    {
        string binDir = Path.Combine(InstallDir, "ffmpeg", "bin");
        string zip = Path.Combine(Path.GetTempPath(), "ttc_ffmpeg.zip");
        string local = Env("TTC_FFMPEG_ZIP");   // test hook: use a local zip instead of downloading
        string lastError = "";
        bool have = false;
        if (local != null && File.Exists(local)) { zip = local; have = true; }
        else
        {
            foreach (string[] src in FfmpegSources)
            {
                try
                {
                    f.Status("Downloading FFmpeg...", 8);
                    Download(src[0], zip, delegate (long got, long total)
                    {
                        int pct = total > 0 ? (int)(got * 100 / total) : 0;
                        f.Status("Downloading FFmpeg...  " + (got >> 20) + (total > 0 ? " / " + (total >> 20) : "") + " MB", 8 + pct * 80 / 100);
                    });
                    f.Status("Verifying download...", 89);
                    VerifySha256(zip, src[1], src[2]);
                    have = true; break;
                }
                catch (Exception ex) { lastError = ex.Message; try { File.Delete(zip); } catch { } }
            }
        }
        if (!have)
            return "Could not download FFmpeg (" + lastError + ").\n\nThe app was installed, but you will need FFmpeg once. Check your internet connection and open the app again, or run this in a terminal:\n\nwinget install Gyan.FFmpeg";

        try
        {
            f.Status("Unpacking FFmpeg...", 90);
            Directory.CreateDirectory(binDir);
            using (ZipArchive z = ZipFile.OpenRead(zip))
            {
                foreach (ZipArchiveEntry e in z.Entries)
                {
                    string n = e.FullName.Replace('\\', '/').ToLowerInvariant();
                    if (n.EndsWith("/bin/ffmpeg.exe") || n.EndsWith("/bin/ffprobe.exe"))
                        e.ExtractToFile(Path.Combine(binDir, Path.GetFileName(n)), true);
                }
            }
            if (local == null) { try { File.Delete(zip); } catch { } }
            if (!BothIn(binDir)) return "FFmpeg was downloaded but ffmpeg.exe / ffprobe.exe were not found inside it.";
        }
        catch (Exception ex) { return "Could not unpack FFmpeg: " + ex.Message; }
        return null;
    }

    delegate void ProgressCb(long got, long total);

    // If the publisher's checksum can be fetched it MUST match, otherwise the download is rejected.
    // (If the checksum file itself is unreachable we continue: the zip still came over verified HTTPS.)
    static void VerifySha256(string file, string checksumUrl, string nameInList)
    {
        string text;
        try
        {
            string tmp = Path.Combine(Path.GetTempPath(), "ttc_ffmpeg.sha256");
            Download(checksumUrl, tmp, delegate (long a, long b) { });
            text = File.ReadAllText(tmp);
            try { File.Delete(tmp); } catch { }
        }
        catch { return; }

        string expected = null;
        foreach (string line in text.Split('\n'))
        {
            string l = line.Trim();
            if (l.Length < 64) continue;
            if (nameInList != null && l.IndexOf(nameInList, StringComparison.OrdinalIgnoreCase) < 0) continue;
            expected = l.Substring(0, 64).ToLowerInvariant();
            break;
        }
        if (expected == null) return;

        string actual;
        using (var sha = System.Security.Cryptography.SHA256.Create())
        using (var fs = File.OpenRead(file))
        {
            var sb = new System.Text.StringBuilder();
            foreach (byte b in sha.ComputeHash(fs)) sb.Append(b.ToString("x2"));
            actual = sb.ToString();
        }
        if (actual != expected) throw new Exception("checksum mismatch (the download is corrupted or has been tampered with)");
    }

    static void Download(string url, string dest, ProgressCb cb)
    {
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;   // TLS 1.2
        var req = (HttpWebRequest)WebRequest.Create(url);
        req.UserAgent = "TikTokConverter/1.0";
        req.AllowAutoRedirect = true;
        req.Timeout = 30000; req.ReadWriteTimeout = 30000;
        using (WebResponse resp = req.GetResponse())
        {
            if (resp.ResponseUri.Scheme != Uri.UriSchemeHttps) throw new Exception("download was redirected to a non-HTTPS address");
            using (Stream s = resp.GetResponseStream())
            using (FileStream fs = File.Create(dest))
            {
                long total = resp.ContentLength, got = 0;
                var buf = new byte[81920];
                int n, tick = Environment.TickCount;
                while ((n = s.Read(buf, 0, buf.Length)) > 0)
                {
                    fs.Write(buf, 0, n); got += n;
                    if (Environment.TickCount - tick > 150) { cb(got, total); tick = Environment.TickCount; }
                }
                cb(got, total);
            }
        }
    }

    // ---------- shortcuts / uninstall ----------
    static string[] ShortcutDirs()
    {
        string d = Env("TTC_SHORTCUT_DIR");
        if (d != null) return new[] { d };
        return new[] { Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), Environment.GetFolderPath(Environment.SpecialFolder.Programs) };
    }

    static void MakeLink(string lnkPath, string target, string args, string desc)
    {
        Type t = Type.GetTypeFromProgID("WScript.Shell");
        object sh = Activator.CreateInstance(t);
        object lnk = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, sh, new object[] { lnkPath });
        Type lt = lnk.GetType();
        lt.InvokeMember("TargetPath", BindingFlags.SetProperty, null, lnk, new object[] { target });
        lt.InvokeMember("Arguments", BindingFlags.SetProperty, null, lnk, new object[] { args });
        lt.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, lnk, new object[] { InstallDir });
        lt.InvokeMember("IconLocation", BindingFlags.SetProperty, null, lnk, new object[] { InstalledExe + ",0" });
        lt.InvokeMember("Description", BindingFlags.SetProperty, null, lnk, new object[] { desc });
        lt.InvokeMember("Save", BindingFlags.InvokeMethod, null, lnk, null);
    }

    static void CreateShortcuts()
    {
        string[] dirs = ShortcutDirs();
        for (int i = 0; i < dirs.Length; i++)
        {
            Directory.CreateDirectory(dirs[i]);
            MakeLink(Path.Combine(dirs[i], AppName + ".lnk"), InstalledExe, "", "Convert videos to TikTok format");
            if (i == 1 || dirs.Length == 1)
                MakeLink(Path.Combine(dirs[i], "Uninstall " + AppName + ".lnk"), InstalledExe, "/uninstall", "Remove " + AppName);
        }
        if (!TestMode)
        {
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RegKey))
            {
                k.SetValue("DisplayName", AppName);
                k.SetValue("DisplayVersion", Version);
                k.SetValue("Publisher", "TikTok Converter");
                k.SetValue("DisplayIcon", InstalledExe);
                k.SetValue("InstallLocation", InstallDir);
                k.SetValue("UninstallString", "\"" + InstalledExe + "\" /uninstall");
                k.SetValue("NoModify", 1); k.SetValue("NoRepair", 1);
            }
        }
    }

    static void Uninstall()
    {
        if (Env("TTC_YES") == null &&
            MessageBox.Show("Remove " + AppName + " from this PC?\n\nYour converted videos are not touched.", AppName,
                MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;

        foreach (string d in ShortcutDirs())
        {
            foreach (string n in new[] { AppName + ".lnk", "Uninstall " + AppName + ".lnk" })
                try { File.Delete(Path.Combine(d, n)); } catch { }
        }
        if (!TestMode)
        {
            try { Registry.CurrentUser.DeleteSubKeyTree(RegKey, false); } catch { }
            try
            {
                string settings = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TikTokConverter");
                if (Directory.Exists(settings)) Directory.Delete(settings, true);
            }
            catch { }
        }
        // this exe is running from the folder, so let a helper delete it a moment after we exit.
        // Safety: only ever remove a folder that is really ours.
        if (!string.Equals(Path.GetFileName(InstallDir.TrimEnd('\\', '/')), "TikTokConverter", StringComparison.OrdinalIgnoreCase)
            && !File.Exists(Path.Combine(InstallDir, "TikTokConverter.exe"))) return;
        var psi = new ProcessStartInfo("cmd.exe", "/c ping 127.0.0.1 -n 3 >nul & rmdir /s /q \"" + InstallDir + "\"");
        psi.CreateNoWindow = true; psi.UseShellExecute = false;
        Process.Start(psi);
        if (Env("TTC_YES") == null)
            MessageBox.Show(AppName + " was removed.", AppName);
    }
}

// small dark progress window used during setup
class SetupForm : Form
{
    public Action<SetupForm> Work;
    public string Error;
    Label status;
    Panel track, fill;

    public SetupForm(string title)
    {
        Text = title;
        ClientSize = new Size(470, 150);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false; ControlBox = false;
        BackColor = Color.FromArgb(20, 20, 28);
        ForeColor = Color.FromArgb(238, 238, 248);
        Font = new Font("Segoe UI", 9.5f);
        try { Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location); } catch { }

        var head = new Label { Text = title, Left = 16, Top = 14, Width = 440, Height = 32, ForeColor = Color.White,
            Font = new Font("Segoe UI Semibold", 15f) };
        status = new Label { Text = "Starting...", Left = 16, Top = 62, Width = 440, Height = 24, ForeColor = Color.FromArgb(37, 244, 238) };
        track = new Panel { Left = 16, Top = 96, Width = 438, Height = 14, BackColor = Color.FromArgb(48, 48, 66) };
        fill = new Panel { Left = 0, Top = 0, Width = 0, Height = 14, BackColor = Color.FromArgb(254, 44, 85) };
        track.Controls.Add(fill);
        var note = new Label { Text = "Please keep this window open.", Left = 16, Top = 118, Width = 440, Height = 22, ForeColor = Color.FromArgb(150, 150, 176) };
        Controls.AddRange(new Control[] { head, status, track, note });
        Shown += delegate
        {
            var th = new Thread(delegate ()
            {
                try { Work(this); }
                catch (Exception ex) { Error = ex.Message; }
                try { BeginInvoke(new MethodInvoker(Close)); } catch { }
            });
            th.IsBackground = true;
            th.Start();
        };
    }

    public void Status(string text, int percent)
    {
        if (IsDisposed) return;
        try
        {
            BeginInvoke(new MethodInvoker(delegate
            {
                status.Text = text;
                fill.Width = track.Width * Math.Max(0, Math.Min(100, percent)) / 100;
            }));
        }
        catch { }
    }
}
