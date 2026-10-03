using Microsoft.Win32;
using QNotch.Interop;

namespace QNotch.Core;

/// <summary>
/// Which apps use the microphone or the camera right now. Windows records every use in the consent store
/// (HKCU\...\CapabilityAccessManager\ConsentStore\microphone or \webcam, packaged apps directly, desktop apps under NonPackaged):
/// an app is using the device while its LastUsedTimeStart is newer than its LastUsedTimeStop. A desktop app that crashed mid-call never
/// writes its stop time, so a desktop entry also needs a running process of that name. Event-driven: RegNotifyChangeKeyValue
/// signals an event the thread pool waits on, so nothing runs while nothing changes. No permission needed, nothing leaves the machine.
/// </summary>
public sealed class CaptureWatch : IDisposable
{
    public const string Microphone = "microphone", Camera = "webcam";
    const string Store = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\";

    readonly string _capability;
    readonly Action<IReadOnlyList<string>> _changed;
    readonly RegistryKey? _key;
    readonly AutoResetEvent _signal = new(false);
    readonly RegisteredWaitHandle? _wait;
    readonly object _gate = new();
    string? _last;
    bool _disposed;

    /// <summary>Calls <paramref name="changed"/> on the thread pool with the names of the apps using the device: once soon, then on every change.</summary>
    public CaptureWatch(string capability, Action<IReadOnlyList<string>> changed)
    {
        _capability = capability;
        _changed = changed;
        _key = Registry.CurrentUser.OpenSubKey(Store + capability);
        if (_key is null) { Log.Info($"No consent store for {capability}: nothing to watch"); return; }
        _wait = ThreadPool.RegisterWaitForSingleObject(_signal, (_, _) => Scan(), null, Timeout.Infinite, executeOnlyOnce: false);
        ThreadPool.QueueUserWorkItem(_ => Scan());
    }

    void Scan()
    {
        lock (_gate)
        {
            if (_disposed) return;
            try
            {
                // Armed before reading, so a change during the read signals again.
                var err = Native.RegNotifyChangeKeyValue(_key!.Handle, true,
                    Native.REG_NOTIFY_CHANGE_NAME | Native.REG_NOTIFY_CHANGE_LAST_SET | Native.REG_NOTIFY_THREAD_AGNOSTIC, _signal.SafeWaitHandle, true);
                if (err != 0) Log.Warn($"Watching {_capability} failed ({err})");
                var apps = InUse(_key);
                var joined = string.Join('\n', apps);
                if (joined == _last) return;
                _last = joined;
                _changed(apps);
            }
            catch (Exception ex) { Log.Warn($"Reading {_capability} use failed", ex); }
        }
    }

    static List<string> InUse(RegistryKey store)
    {
        var apps = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        void Visit(RegistryKey key, bool desktop)
        {
            foreach (var name in key.GetSubKeyNames())
            {
                using var sub = key.OpenSubKey(name);
                if (sub is null) continue;
                if (!desktop && name == "NonPackaged") { Visit(sub, true); continue; }
                if (sub.GetValue("LastUsedTimeStart") is not long start || start <= (sub.GetValue("LastUsedTimeStop") as long? ?? 0)) continue;
                var app = DisplayName(name, desktop);
                if (!desktop || IsRunning(app)) apps.Add(app);
            }
        }
        Visit(store, false);
        return apps.ToList();
    }

    static bool IsRunning(string exeName)
    {
        var found = System.Diagnostics.Process.GetProcessesByName(exeName);
        foreach (var p in found) p.Dispose();
        return found.Length > 0;
    }

    /// <summary>"C:#Program Files#Zoom#Zoom.exe" becomes "Zoom", "MSTeams_8wekyb3d8bbwe" becomes "MSTeams", "com.tinyspeck.slackdesktop_..." becomes "slackdesktop".</summary>
    internal static string DisplayName(string key, bool desktop)
    {
        if (desktop) return Path.GetFileNameWithoutExtension(key.Replace('#', '\\'));
        var family = key.Split('_')[0];
        return family[(family.LastIndexOf('.') + 1)..];
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            _wait?.Unregister(null);
            _key?.Dispose();
            _signal.Dispose();
        }
    }
}
