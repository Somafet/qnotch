using System.Runtime.CompilerServices;
using QNotch.Modules;
using QNotch.Shell.Diagnostics;

namespace QNotch;

/// <summary>
/// Entry point. A command line verb (<see cref="ModuleList.Verbs"/>, for example <c>QNotch.exe notify</c>) runs and exits before any
/// WPF type loads, so scripts and hooks pay only the runtime start. Everything else starts the app.
/// </summary>
static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length > 0 && ModuleList.Verbs.TryGetValue(args[0], out var verb)) return verb(args[1..]);
        // Set before Paths loads. --data-dir replaces the data root and wins over QNOTCH_DATA_DIR (inherited by --restart); without either,
        // --snapshot, --smoke-test and --measure get a fresh temporary root, deleted when they exit.
        var diag = DiagnosticOptions.Parse(args);
        string? temp = null;
        if (diag.DataDir is { } dataDir) Environment.SetEnvironmentVariable("QNOTCH_DATA_DIR", dataDir);
        else if (diag.RunsOnce && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("QNOTCH_DATA_DIR")))
            Environment.SetEnvironmentVariable("QNOTCH_DATA_DIR", temp = Path.Combine(Path.GetTempPath(), $"qnotch-{diag.Mode.ToString().ToLowerInvariant()}-{Guid.NewGuid():N}"));
        try { return RunApp(); }
        finally { if (temp is not null) DeleteTemp(temp); }
    }

    [MethodImpl(MethodImplOptions.NoInlining)] // keeps App (and WPF) out of Main's JIT
    static int RunApp()
    {
        var app = new App();
        app.InitializeComponent();
        return app.Run();
    }

    /// <summary>A pool thread may still be finishing a log line: a few tries.</summary>
    static void DeleteTemp(string dir)
    {
        for (var i = 0; i < 5 && Directory.Exists(dir); i++)
        {
            try { Directory.Delete(dir, recursive: true); }
            catch (IOException) { Thread.Sleep(200); }
            catch (UnauthorizedAccessException) { Thread.Sleep(200); }
        }
    }
}
