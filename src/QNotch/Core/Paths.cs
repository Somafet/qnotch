namespace QNotch.Core;

public static class Paths
{
    /// <summary>%APPDATA%\QNotch, or the full path in QNOTCH_DATA_DIR (parallel test runs).</summary>
    public static readonly string DataDir = Directory.CreateDirectory(
        Environment.GetEnvironmentVariable("QNOTCH_DATA_DIR") is { Length: > 0 } d
            ? Path.GetFullPath(d)
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QNotch")).FullName;

    public static readonly string LogDir = Directory.CreateDirectory(Path.Combine(DataDir, "logs")).FullName;
}
