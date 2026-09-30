using System.Windows.Media;
using Microsoft.Win32;
using QNotch.Core;

namespace QNotch.Modules.Ai;

internal sealed record DetectedApp(string Id, string Name, string Target, bool IsCustom, ImageSource? Icon);

/// <summary>
/// Finds the AI desktop apps. Order per app: registry uninstall keys, Start menu shortcuts, known install paths, Store (MSIX) packages.
/// Blocking and COM-heavy: run it on a background STA thread (see <see cref="ScanAsync"/>).
/// </summary>
internal static class AppDetector
{
    sealed record Known(string Id, string Name, string[] Exes, string[] Dirs, string[] Packages);

    static readonly string Local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    static readonly string ProgramFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);

    static readonly Known[] KnownApps =
    [
        new("chatgpt", "ChatGPT", ["ChatGPT.exe"], [Path.Combine(Local, "Programs", "ChatGPT"), Path.Combine(ProgramFiles, "ChatGPT")], ["OpenAI.ChatGPT-Desktop"]),
        new("claude", "Claude", ["claude.exe"], [Path.Combine(Local, "AnthropicClaude"), Path.Combine(Local, "Programs", "Claude"), Path.Combine(ProgramFiles, "Claude")], ["Claude", "AnthropicPBC.Claude"]),
        new("cursor", "Cursor", ["Cursor.exe"], [Path.Combine(Local, "Programs", "cursor"), Path.Combine(ProgramFiles, "cursor")], []),
        new("codex", "Codex", ["Codex.exe"], [Path.Combine(Local, "Programs", "Codex"), Path.Combine(ProgramFiles, "Codex")], ["OpenAI.Codex"]),
        new("antigravity", "Antigravity", ["Antigravity.exe"], [Path.Combine(Local, "Programs", "Antigravity"), Path.Combine(ProgramFiles, "Antigravity")], []),
    ];

    /// <summary>Scans on a short-lived STA thread (shell icons and WinRT need it) and returns known apps plus the given custom ones, all with icons.</summary>
    public static Task<List<DetectedApp>> ScanAsync(IReadOnlyList<CustomApp> custom)
    {
        var tcs = new TaskCompletionSource<List<DetectedApp>>();
        var t = new Thread(() =>
        {
            try { tcs.SetResult(Scan(custom)); }
            catch (Exception ex) { Log.Warn("AI app scan failed", ex); tcs.SetResult([]); }
        }) { IsBackground = true, Name = "AiScan", Priority = ThreadPriority.BelowNormal };
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        return tcs.Task;
    }

    static List<DetectedApp> Scan(IReadOnlyList<CustomApp> custom)
    {
        var found = new Dictionary<string, string>(); // id -> launch target
        var entries = Safe(UninstallEntries);
        var lnks = Safe(StartMenuShortcuts);

        foreach (var k in KnownApps)
        {
            var target = FromRegistry(k, entries) ?? FromShortcuts(k, lnks) ?? FromKnownPaths(k);
            if (target is not null) found[k.Id] = target;
        }
        if (found.Count < KnownApps.Length) FromStore(found);

        var result = new List<DetectedApp>();
        foreach (var k in KnownApps)
            if (found.TryGetValue(k.Id, out var target)) result.Add(new(k.Id, k.Name, target, false, ShellIcons.Load(target)));
        foreach (var c in custom)
            result.Add(new(c.Id, c.Name, c.Path, true, ShellIcons.Load(c.Path)));
        return result;
    }

    static T Safe<T>(Func<T> f) where T : new()
    {
        try { return f(); } catch (Exception ex) { Log.Warn("AI app detection step failed", ex); return new T(); }
    }

    // ---------- matching ----------

    /// <summary>"Cursor", "Cursor (User)" and "Claude 1.2.3" match "Cursor" / "Claude"; "Claude Code" does not.</summary>
    static bool NameMatches(string display, string known)
    {
        if (display.Equals(known, StringComparison.OrdinalIgnoreCase)) return true;
        if (!display.StartsWith(known + " ", StringComparison.OrdinalIgnoreCase)) return false;
        var rest = display[(known.Length + 1)..].TrimStart();
        return rest.Length > 0 && (char.IsDigit(rest[0]) || rest[0] == '(' || (rest[0] == 'v' && rest.Length > 1 && char.IsDigit(rest[1])));
    }

    // ---------- 1. registry ----------

    sealed record Entry(string Name, string? Icon, string? Location);

    static List<Entry> UninstallEntries()
    {
        const string sub = @"Software\Microsoft\Windows\CurrentVersion\Uninstall";
        var list = new List<Entry>();
        foreach (var (hive, path) in new[] { (Registry.CurrentUser, sub), (Registry.LocalMachine, sub), (Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall") })
        {
            using var root = hive.OpenSubKey(path);
            if (root is null) continue;
            foreach (var name in root.GetSubKeyNames())
            {
                try
                {
                    using var k = root.OpenSubKey(name);
                    if (k?.GetValue("DisplayName") is string dn)
                        list.Add(new(dn, k.GetValue("DisplayIcon") as string, k.GetValue("InstallLocation") as string));
                }
                catch { /* unreadable key */ }
            }
        }
        return list;
    }

    static string? FromRegistry(Known k, List<Entry> entries)
    {
        foreach (var e in entries.Where(e => NameMatches(e.Name, k.Name)))
        {
            if (e.Icon is { Length: > 0 })
            {
                var icon = e.Icon.Trim().Trim('"');
                var comma = icon.LastIndexOf(',');
                if (comma > 1 && int.TryParse(icon[(comma + 1)..], out _)) icon = icon[..comma].Trim('"');
                if (icon.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && File.Exists(icon)) return icon;
            }
            if (e.Location is { Length: > 0 } loc && FindExe(k, loc) is { } exe) return exe;
        }
        return null;
    }

    // ---------- 2. Start menu ----------

    static List<string> StartMenuShortcuts()
    {
        var list = new List<string>();
        foreach (var root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.Programs), Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms) })
        {
            if (!Directory.Exists(root)) continue;
            try { list.AddRange(Directory.EnumerateFiles(root, "*.lnk", SearchOption.AllDirectories)); } catch { /* access denied */ }
        }
        return list;
    }

    // The .lnk itself is launched (and iconned): Windows resolves the target and arguments, which is what the user expects.
    static string? FromShortcuts(Known k, List<string> lnks) =>
        lnks.FirstOrDefault(p => NameMatches(Path.GetFileNameWithoutExtension(p), k.Name));

    // ---------- 3. known paths ----------

    static string? FromKnownPaths(Known k)
    {
        foreach (var dir in k.Dirs)
            if (FindExe(k, dir) is { } exe) return exe;
        return null;
    }

    /// <summary>Exe in the folder itself, or in the newest app-x.y.z subfolder (Squirrel installs).</summary>
    static string? FindExe(Known k, string dir)
    {
        if (!Directory.Exists(dir)) return null;
        foreach (var exe in k.Exes)
        {
            var p = Path.Combine(dir, exe);
            if (File.Exists(p)) return p;
        }
        try
        {
            foreach (var sub in Directory.GetDirectories(dir, "app-*").OrderByDescending(d => d, StringComparer.OrdinalIgnoreCase))
                foreach (var exe in k.Exes)
                    if (File.Exists(Path.Combine(sub, exe))) return Path.Combine(sub, exe);
        }
        catch { /* ignore */ }
        return null;
    }

    // ---------- 4. Store / MSIX ----------

    static void FromStore(Dictionary<string, string> found)
    {
        try
        {
            var pm = new Windows.Management.Deployment.PackageManager();
            foreach (var p in pm.FindPackagesForUser(""))
            {
                if (p.IsFramework || p.IsResourcePackage) continue;
                var k = KnownApps.FirstOrDefault(x => !found.ContainsKey(x.Id) && x.Packages.Contains(p.Id.Name, StringComparer.OrdinalIgnoreCase));
                if (k is null) continue;
                var entries = p.GetAppListEntriesAsync().AsTask().GetAwaiter().GetResult();
                if (entries.Count > 0) found[k.Id] = @"shell:AppsFolder\" + entries[0].AppUserModelId;
            }
        }
        catch (Exception ex) { Log.Warn("Store package scan failed", ex); }
    }
}
