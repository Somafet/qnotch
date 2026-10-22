using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Modules.Terminal;
using QNotch.Shell.Onboarding;
using QNotch.Shell.Settings;

internal static class TerminalChecks
{
    internal static void Deterministic()
    {
        var terminal = ModuleList.All.Single(m => m.Id == "terminal");
        var settings = new GeneralSettings();
        Require(!terminal.DefaultEnabled && !terminal.IsEnabled(settings), "fresh default");
        settings.DisabledModules.Clear();
        Require(!terminal.IsEnabled(settings), "old settings default");
        terminal.SetEnabled(settings, true);
        Require(terminal.IsEnabled(settings) && !settings.DisabledModules.Contains("terminal"), "local opt-in");
        Require(!SetupCode.ShellSections.Single(s => s.Id == "general").Shared.Fields.Contains("LocalEnabledModules"), "setup exclusion");
        var choices = new TourChoices(TourMode.FirstRun, new GeneralSettings(), ModuleList.All.Select(m => m.Id), ["terminal"]);
        Require(!choices.IsOn("terminal"), "tour default");
        choices.SetOn("terminal", true);
        var selected = new GeneralSettings(); choices.Apply(selected, TourEnd.Finished);
        Require(terminal.IsEnabled(selected) && !selected.DisabledModules.Contains("terminal"), "tour local opt-in");

        var b = new TerminalBuffer(40, 5);
        foreach (var c in "abc\u001b[2DXY\r\n\u001b[31mred\u001b[0m\u001b[3;4H!") b.Feed(c.ToString());
        var frame = b.Capture();
        Require(Text(frame.Lines[0]).StartsWith("aXY"), "cursor overwrite");
        Require(Text(frame.Lines[1]).StartsWith("red") && frame.Lines[1][0].Foreground != TerminalBuffer.DefaultColor, "SGR color");
        Require(frame.Lines[2][3].Text == "!", "cursor positioning");
        b.Feed("\u001b[?1049hALT\u001b[?1049l");
        Require(Text(b.Capture().Lines[0]).StartsWith("aXY"), "alternate screen restore");
        var replies = new List<string>();
        b.Feed("\u001b[6n", replies.Add);
        Require(replies.Single() == "\u001b[3;5R", "cursor report");
        b.Feed("\u001b[?1h\u001b[?2004h");
        Require(b.ApplicationCursor && b.BracketedPaste, "input modes");
        b.Feed("\u001bc");
        for (var i = 0; i < 10000; i++) b.Feed("bounded\r\n");
        Require(b.Capture().HistoryCount == TerminalBuffer.HistoryLimit, "bounded history");
        b.Resize(92, 24);
        Require(b.Columns == 92 && b.Rows == 24 && b.Capture().Lines.Length == 24, "resize");
        b.Feed("\u001b[" + new string('9', 100000) + "m\u001b]" + new string('x', 100000) + "\a\u001b[2J\u001b[Hsafe");
        Require(Text(b.Capture().Lines[0]).StartsWith("safe"), "bounded hostile sequences");
        Require(TerminalInput.KeyText(Key.C, ModifierKeys.Control, false) == "\u0003", "Ctrl+C");
        Require(TerminalInput.KeyText(Key.Left, ModifierKeys.None, false) == "\u001b[D", "left arrow");
        Require(TerminalInput.KeyText(Key.Up, ModifierKeys.None, true) == "\u001bOA", "application cursor");
        Require(TerminalInput.KeyText(Key.Back, ModifierKeys.None, false) == "\u007f", "backspace");
        Require(TerminalInput.KeyText(Key.V, ModifierKeys.Control | ModifierKeys.Alt, false) is null, "AltGr must reach Windows text composition");
    }

    internal static async Task ConPty()
    {
        var directory = Path.Combine(Path.GetTempPath(), "qnotch-conpty-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var raw = new StringBuilder();
        var gate = new object();
        var buffer = new TerminalBuffer(80, 20);
        void Output(string chunk, Action<string> reply)
        {
            buffer.Feed(chunk, reply);
            lock (gate) { raw.Append(chunk); if (raw.Length > 65536) raw.Remove(0, raw.Length - 65536); }
        }
        string Raw() { lock (gate) return raw.ToString(); }
        async Task Wait(string marker)
        {
            var timer = Stopwatch.StartNew();
            while (!Raw().Contains(marker, StringComparison.Ordinal) && timer.Elapsed < TimeSpan.FromSeconds(15)) await Task.Delay(25);
            Require(Raw().Contains(marker, StringComparison.Ordinal), "ConPTY output missing " + marker + ": " + Raw()[Math.Max(0, Raw().Length - 1000)..]);
        }
        var shell = TerminalModule.Shell();
        var environment = new Dictionary<string, string>
        {
            ["APPDATA"] = Path.Combine(directory, "roaming"),
            ["LOCALAPPDATA"] = Path.Combine(directory, "local"),
            ["PSModulePath"] = Path.Combine(Path.GetDirectoryName(shell.Executable)!, "Modules") + Path.PathSeparator
                + Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "Modules"),
        };
        Directory.CreateDirectory(environment["APPDATA"]);
        Directory.CreateDirectory(environment["LOCALAPPDATA"]);
        var sentinelPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
        using var unrelated = Process.Start(new ProcessStartInfo(sentinelPath, "-NoLogo -NoProfile -Command Start-Sleep -Seconds 120") { UseShellExecute = false, CreateNoWindow = true })!;
        ConPtySession? session = null;
        try
        {
            session = ConPtySession.Start(shell.Executable, shell.Arguments, directory, 80, 20, Output, () => { }, environment);
            session.Send("$m='QNOTCH'\r");
            session.Send("Write-Output ($m+'_READY')\r");
            await Wait("QNOTCH_READY");
            await Wait(directory);
            session.Send("$m+'_BACX\u007fK'\r");
            await Wait("QNOTCH_BACK");
            session.Send("$m+'_ABX'\u001b[D\u001b[D\u001b[3~C\u001b[F\r");
            await Wait("QNOTCH_ABC");
            session.Resize(92, 24);
            session.Send("$m+'_SIZE='+$Host.UI.RawUI.WindowSize.Width+'x'+$Host.UI.RawUI.WindowSize.Height\r");
            await Wait("QNOTCH_SIZE=92x24");
            session.Send("Start-Sleep -Seconds 30\r");
            await Task.Delay(300);
            var beforeInterrupt = Raw().Length;
            session.Send("\u0003");
            var interrupted = Stopwatch.StartNew();
            while (!Raw()[Math.Min(beforeInterrupt, Raw().Length)..].Contains("PS ", StringComparison.Ordinal) && interrupted.Elapsed < TimeSpan.FromSeconds(5)) await Task.Delay(25);
            Require(interrupted.Elapsed < TimeSpan.FromSeconds(5), "Ctrl+C did not return a prompt");
            session.Send("$m+'_INTERRUPTED'\r");
            await Wait("QNOTCH_INTERRUPTED");
            session.Send("$child=Start-Process (Join-Path $env:WINDIR 'System32\\WindowsPowerShell\\v1.0\\powershell.exe') -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 120' -WindowStyle Hidden -PassThru; $m+'_CHILD='+$child.Id\r");
            var timer = Stopwatch.StartNew();
            Match child;
            do { await Task.Delay(25); child = Regex.Match(Raw(), @"QNOTCH_CHILD=(\d+)"); } while (!child.Success && timer.Elapsed < TimeSpan.FromSeconds(15));
            Require(child.Success, "owned descendant PID not reported");
            using var descendant = Process.GetProcessById(int.Parse(child.Groups[1].Value));
            var pid = session.ProcessId;
            await session.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(10));
            Require(descendant.WaitForExit(5000), "owned detached descendant survived job close");
            Require(!unrelated.HasExited, "session cleanup stopped an unrelated process");
            Require(!Alive(pid), "shell survived disposal");
            Console.WriteLine("PASS real ConPTY PowerShell I/O, cwd, backspace, arrows/delete, resize, Ctrl+C, owned detached-child reap and unrelated-process survival");
            for (var i = 0; i < 3; i++)
            {
                await using var exited = ConPtySession.Start(Path.Combine(Environment.SystemDirectory, "cmd.exe"), "/d /q", directory, 80, 20, (_, _) => { }, () => { });
                exited.Send("exit\r");
                await exited.Completion.WaitAsync(TimeSpan.FromSeconds(10));
                Require(!Alive(exited.ProcessId), "natural exit was not reaped");
            }
            var failed = false;
            try { await using var bad = ConPtySession.Start(shell.Executable, shell.Arguments, Path.Combine(directory, "missing"), 80, 20, (_, _) => { }, () => { }); }
            catch (System.ComponentModel.Win32Exception) { failed = true; }
            Require(failed, "invalid working-directory creation did not fail");
            Console.WriteLine("PASS repeated ConPTY natural exit and failed-creation cleanup");
        }
        finally
        {
            if (session is not null) await session.DisposeAsync();
            if (!unrelated.HasExited) { unrelated.Kill(); await unrelated.WaitForExitAsync(); }
            Directory.Delete(directory, true);
        }
    }
    static string Text(IEnumerable<TerminalBuffer.Cell> cells) => string.Concat(cells.Select(c => c.Text));
    static bool Alive(int pid) { try { using var p = Process.GetProcessById(pid); return !p.HasExited; } catch (ArgumentException) { return false; } }
    static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
