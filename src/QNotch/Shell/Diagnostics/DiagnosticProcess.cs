namespace QNotch.Shell.Diagnostics;

/// <summary>
/// Process setup for <c>--smoke-test</c> and <c>--measure</c>, run by <c>Program.Main</c> before WPF loads: a fresh temporary data root
/// unless <c>--data-dir</c> or <c>QNOTCH_DATA_DIR</c> names one (deleted when disposed), and for a smoke run its own <c>QNOTCH_INSTANCE</c>
/// if none is set, so its pipes and child processes never reach a normal instance.
/// </summary>
internal sealed class DiagnosticProcess : IDisposable
{
    string? _temp;

    public static DiagnosticProcess Prepare(DiagnosticOptions o)
    {
        var p = new DiagnosticProcess();
        if (o.Mode is not (DiagnosticMode.SmokeTest or DiagnosticMode.Measure)) return p;
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("QNOTCH_DATA_DIR")))
        {
            p._temp = Path.Combine(Path.GetTempPath(), $"qnotch-{(o.Mode == DiagnosticMode.Measure ? "measure" : "smoke")}-{Guid.NewGuid():N}");
            Directory.CreateDirectory(p._temp);
            Environment.SetEnvironmentVariable("QNOTCH_DATA_DIR", p._temp);
        }
        if (o.Mode == DiagnosticMode.SmokeTest && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("QNOTCH_INSTANCE")))
            Environment.SetEnvironmentVariable("QNOTCH_INSTANCE", $"smoke-{Environment.ProcessId}");
        return p;
    }

    public void Dispose()
    {
        if (_temp is null) return;
        try { Directory.Delete(_temp, true); } catch { /* a log still open: the temp folder is the OS's to clean */ }
        _temp = null;
    }
}
