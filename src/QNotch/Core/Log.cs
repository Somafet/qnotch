using System.Windows;

namespace QNotch.Core;

/// <summary>Tiny file logger (no timers, no background threads). Crashes go to logs\crash.log.</summary>
public static class Log
{
    static readonly object Gate = new();
    static readonly string LogFile = Path.Combine(Paths.LogDir, "qnotch.log");
    static readonly string CrashFile = Path.Combine(Paths.LogDir, "crash.log");

    public static void Info(string msg) => Write(LogFile, "INFO", msg);
    public static void Warn(string msg, Exception? ex = null) => Write(LogFile, "WARN", ex is null ? msg : $"{msg}\n{ex}");
    public static void Error(string msg, Exception? ex = null) => Write(LogFile, "ERROR", ex is null ? msg : $"{msg}\n{ex}");
    public static void Crash(string source, Exception? ex) => Write(CrashFile, "CRASH", $"[{source}]\n{ex}");

    static void Write(string file, string level, string msg)
    {
        try
        {
            lock (Gate)
            {
                if (File.Exists(file) && new FileInfo(file).Length > 512 * 1024) File.Delete(file);
                File.AppendAllText(file, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {level} {msg}{Environment.NewLine}");
            }
        }
        catch { /* logging must never throw */ }
    }

    /// <summary>Installs all unhandled-exception handlers. UI-thread exceptions are logged and swallowed so an overlay never dies.</summary>
    public static void InstallHandlers(Application app)
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Crash("AppDomain", e.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, e) => { Crash("Task", e.Exception); e.SetObserved(); };
        app.DispatcherUnhandledException += (_, e) => { Crash("Dispatcher", e.Exception); e.Handled = true; };
    }
}
