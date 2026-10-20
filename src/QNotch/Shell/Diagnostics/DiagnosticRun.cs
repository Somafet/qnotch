using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Media;
using System.Windows.Threading;
using QNotch.Core;
using QNotch.Modules;

namespace QNotch.Shell.Diagnostics;

/// <summary>What App hands a diagnostic run: the live shell, its registries and modules, and the snapshot writer.</summary>
/// <param name="Snapshot">Writes everything <c>--snapshot</c> writes into a folder and adds its report lines (views, free-form lines, <c>done</c>).</param>
internal sealed record DiagnosticHost(NotchWindow Window, ShellController Shell, GeneralSettings Settings, SettingsStore Store, Shortcuts Shortcuts,
    CardLayout Layout, Registry<TabDescriptor> Tabs, Registry<CardDescriptor> Cards, Registry<SettingsSectionDescriptor> Sections,
    Registry<SegmentDescriptor> Segments, Registry<SearchSource> Search, IReadOnlyList<(string Id, INotchModule Module)> Modules,
    Func<string, List<string>, Task> Snapshot);

/// <summary>
/// Starts <c>--smoke-test</c> and <c>--measure</c> once App booted the shell (spec/diagnostics.md), and the smoke test's module probe: a child
/// <c>--smoke-test &lt;dir&gt; --smoke-probe &lt;module id&gt;</c> boots with that module off and lists what got registered and built.
/// </summary>
internal static class DiagnosticRun
{
    const string ProbeFlag = "--smoke-probe";

    /// <summary>The module a probe child boots without, else null.</summary>
    static string? ProbeModule(DiagnosticOptions o)
    {
        if (o.Mode != DiagnosticMode.SmokeTest) return null;
        var args = Environment.GetCommandLineArgs();
        var i = Array.IndexOf(args, ProbeFlag);
        return i > 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    /// <summary>DisabledModules for a diagnostic boot: none (every module loads), or the probe's one.</summary>
    public static List<string> BootDisabled(DiagnosticOptions o) => ProbeModule(o) is { } id ? [id] : [];

    public static void Start(DiagnosticOptions o, DiagnosticHost host, Action<int> exit)
    {
        if (ProbeModule(o) is { } probe) Probe(o.Dir!, host, probe, exit);
        else if (o.Mode == DiagnosticMode.Measure) Measure.Run(o, host, exit);
        else SmokeTest.Run(o, host, exit);
    }

    /// <summary>Command line of a probe child that boots without <paramref name="moduleId"/> and writes <c>probe.log</c> into <paramref name="dir"/>.</summary>
    public static string[] ProbeArgs(string dir, string dataDir, string moduleId) => ["--smoke-test", dir, "--data-dir", dataDir, ProbeFlag, moduleId];

    /// <summary>Once the shell is idle (late registrations done, panel prebuilt): every created module, registry id and visual AutomationId.</summary>
    static async void Probe(string dir, DiagnosticHost h, string off, Action<int> exit)
    {
        var code = 1;
        try
        {
            Directory.CreateDirectory(dir);
            for (var i = 0; i < 3; i++) await h.Window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            await Task.Delay(800); // the idle prebuild builds one tab per idle slot
            for (var i = 0; i < 3; i++) await h.Window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            var sb = new StringBuilder($"off {off}\n");
            foreach (var (id, m) in h.Modules) sb.Append($"module {id} {m.GetType().FullName}\n");
            foreach (var t in h.Tabs.Items) sb.Append($"tab {t.Id}\n");
            foreach (var c in h.Cards.Items) sb.Append($"card {c.Id}\n");
            foreach (var s in h.Sections.Items) sb.Append($"section {s.Id}\n");
            foreach (var s in h.Segments.Items) sb.Append($"segment {s.Id}\n");
            foreach (var s in h.Search.Items) sb.Append($"search {s.Id}\n");
            foreach (var id in AutomationIds(h.Window.RootElement)) sb.Append($"id {id}\n");
            File.WriteAllText(Path.Combine(dir, "probe.log"), sb.ToString());
            code = 0;
        }
        catch (Exception ex) { Log.Error("Smoke probe failed", ex); }
        finally { exit(code); }
    }

    /// <summary>Every AutomationId in the visual tree, hidden and collapsed parts included.</summary>
    public static IEnumerable<string> AutomationIds(DependencyObject root)
    {
        var stack = new Stack<DependencyObject>([root]);
        while (stack.Count > 0)
        {
            var o = stack.Pop();
            if (AutomationProperties.GetAutomationId(o) is { Length: > 0 } id) yield return id;
            for (int i = 0, n = VisualTreeHelper.GetChildrenCount(o); i < n; i++) stack.Push(VisualTreeHelper.GetChild(o, i));
        }
    }
}
