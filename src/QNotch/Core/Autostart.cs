using Microsoft.Win32;

namespace QNotch.Core;

public static class Autostart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static void Set(bool on)
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey, true);
            if (k is null) return;
            if (on) k.SetValue("QNotch", $"\"{Environment.ProcessPath}\"");
            else k.DeleteValue("QNotch", false);
        }
        catch (Exception ex) { Log.Warn("Autostart failed", ex); }
    }
}
