namespace QNotch.Core;

public static class Paths
{
    public static readonly string DataDir = Directory.CreateDirectory(
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QNotch")).FullName;

    public static readonly string LogDir = Directory.CreateDirectory(Path.Combine(DataDir, "logs")).FullName;
}
