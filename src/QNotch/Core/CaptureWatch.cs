using System.Diagnostics;
using Microsoft.Win32;
using QNotch.Interop;

namespace QNotch.Core;

/// <summary>
/// Which apps use the microphone or the camera right now. Windows records every use in the consent store
/// (HKCU\...\CapabilityAccessManager\ConsentStore\microphone or \webcam, packaged apps directly, desktop apps under NonPackaged):
/// an app is using the device while its LastUsedTimeStart is newer than its LastUsedTimeStop. A desktop app that crashed mid-call never
/// writes its stop time, so a desktop entry also needs a process of that name that started before the use did, and that process is
/// watched so its exit rescans. Event-driven: RegNotifyChangeKeyValue
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
    /// <summary>Processes holding the device, by id, kept so their Exited event fires.</summary>
    readonly Dictionary<int, Process> _holders = new();
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
                if (err != 0) Log.Warn($"Watching {_capability} failed ({err}): changes are not seen until QNotch restarts");
                var apps = InUse();
                var joined = string.Join('\n', apps);
                if (joined == _last) return;
                _last = joined;
                _changed(apps);
            }
            catch (Exception ex) { Log.Warn($"Reading {_capability} use failed", ex); }
        }
    }

    List<string> InUse()
    {
        var apps = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        var held = new HashSet<int>();
        Process[]? procs = null; // one snapshot per scan, taken only when a desktop entry needs it
        void Visit(RegistryKey key, bool desktop)
        {
            foreach (var name in key.GetSubKeyNames())
            {
                using var sub = key.OpenSubKey(name);
                if (sub is null) continue;
                if (!desktop && name == "NonPackaged") { Visit(sub, true); continue; }
                if (sub.GetValue("LastUsedTimeStart") is not long start || start <= (sub.GetValue("LastUsedTimeStop") as long? ?? 0)) continue;
                if (!desktop) { apps.Add(PackagedName(name)); continue; }
                var path = name.Replace('#', '\\');
                var exe = Path.GetFileNameWithoutExtension(path);
                procs ??= Process.GetProcesses();
                if (procs.FirstOrDefault(p => string.Equals(p.ProcessName, exe, StringComparison.OrdinalIgnoreCase) && StartedBy(p, start)) is not { } holder) continue;
                Hold(holder);
                held.Add(holder.Id);
                apps.Add(DesktopName(path, exe));
            }
        }
        Visit(_key!, false);
        foreach (var p in procs ?? []) if (!_holders.ContainsValue(p)) p.Dispose();
        foreach (var id in _holders.Keys.Where(id => !held.Contains(id)).ToList()) { _holders[id].Dispose(); _holders.Remove(id); }
        return apps.ToList();
    }

    /// <summary>A start time from before this process existed was written by an earlier instance that never wrote its stop.</summary>
    static bool StartedBy(Process p, long start)
    {
        try { return p.StartTime.ToFileTimeUtc() <= start; }
        catch { return true; } // another user's or an elevated process: give it the benefit of the doubt
    }

    void Hold(Process p)
    {
        if (_holders.ContainsKey(p.Id)) return;
        try
        {
            p.EnableRaisingEvents = true;
            p.Exited += (_, _) => ThreadPool.QueueUserWorkItem(_ => Scan());
        }
        catch { /* cannot watch it: the next registry change still rescans */ }
        _holders[p.Id] = p;
    }

    /// <summary>The file description ("Google Chrome"), or the exe name when it has none.</summary>
    static string DesktopName(string path, string exe)
    {
        try { return FileVersionInfo.GetVersionInfo(path).FileDescription is { Length: > 0 and <= 40 } d ? d.Trim() : exe; }
        catch { return exe; }
    }

    /// <summary>"MSTeams_8wekyb3d8bbwe" becomes "MSTeams", "com.tinyspeck.slackdesktop_..." becomes "slackdesktop".</summary>
    static string PackagedName(string key)
    {
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
            foreach (var p in _holders.Values) p.Dispose();
            _holders.Clear();
            _signal.Dispose();
        }
    }
}
