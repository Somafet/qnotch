using System.Diagnostics;
using System.Text;

namespace QNotch.Modules;

/// <summary>
/// Optional for a module: its own <c>--smoke-test</c> checks (spec/diagnostics.md, Smoke checks), so the shell runs them without naming the
/// module. Asked only in a smoke run, on the UI thread, after every view was written. A check may start what the read-only run left off
/// (a pipe), but never the network, the credential store or anything the user would notice beyond the notch.
/// </summary>
public interface ISmokeChecks
{
    IEnumerable<SmokeCheck> SmokeChecks(SmokeContext ctx);
}

/// <summary>One named check. <see cref="Run"/> returns null when it passed, <c>"skip: reason"</c> when this machine cannot run it, else why it failed.</summary>
public sealed record SmokeCheck(string Name, Func<Task<string?>> Run);

/// <summary>What a module check may use: its log and the app's own command line verbs.</summary>
public sealed class SmokeContext(Action<string> log)
{
    /// <summary>A detail line for the smoke log (<c>smoke.log</c>, never the report).</summary>
    public void Log(string line) => log(line);

    /// <summary>Runs <c>QNotch.exe &lt;args&gt;</c> (same instance and data root), optionally with <paramref name="stdin"/>; null when it did not exit in time (it is stopped).</summary>
    public Task<(int Code, string Out, string Err)?> RunVerb(IEnumerable<string> args, string? stdin = null, int timeoutMs = 15000) => Task.Run<(int, string, string)?>(() =>
    {
        var psi = new ProcessStartInfo(Environment.ProcessPath!)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = stdin is not null,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        if (stdin is not null) { p.StandardInput.Write(stdin); p.StandardInput.Close(); }
        if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } return null; }
        return (p.ExitCode, stdout.Result, stderr.Result);
    });
}
