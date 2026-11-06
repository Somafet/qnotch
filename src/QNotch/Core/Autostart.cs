using Microsoft.Win32;
using Windows.ApplicationModel;

namespace QNotch.Core;

public static class Autostart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static void Set(bool on)
    {
        if (AppPackage.IsPackaged) { _ = SetStartupTaskAsync(on); return; }
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey, true);
            if (k is null) return;
            if (on) k.SetValue("QNotch", $"\"{Environment.ProcessPath}\"");
            else k.DeleteValue("QNotch", false);
        }
        catch (Exception ex) { Log.Warn("Autostart failed", ex); }
    }

    /// <summary>
    /// The Store package starts at sign-in through its startup task, not the Run key. A user who turned it off in Task Manager or Settings,
    /// Apps, Startup keeps that choice: Windows reports DisabledByUser and only they can turn it back on there.
    /// </summary>
    static async Task SetStartupTaskAsync(bool on)
    {
        try
        {
            var task = await StartupTask.GetAsync(AppPackage.StartupTaskId);
            if (!on) { task.Disable(); return; }
            var state = await task.RequestEnableAsync();
            if (state is not (StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy))
                Log.Info($"Start with Windows stays off: the startup task is {state}. Turn it on in Settings, Apps, Startup.");
        }
        catch (Exception ex) { Log.Warn("Autostart (startup task) failed", ex); }
    }
}
