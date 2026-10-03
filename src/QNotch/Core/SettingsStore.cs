using System.Text.Json;
using System.Text.Json.Serialization;

namespace QNotch.Core;

/// <summary>
/// One JSON file per module id (%APPDATA%\QNotch\{id}.json). Get returns a cached live instance; Save serializes immediately
/// and writes to disk after a 500 ms debounce (temp file then atomic move). Thread-safe.
/// </summary>
public sealed class SettingsStore
{
    public static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        AllowTrailingCommas = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        Converters = { new JsonStringEnumConverter() },
    };

    readonly object _gate = new();
    readonly Dictionary<string, object> _cache = new();
    readonly Dictionary<string, string> _pending = new();
    readonly HashSet<string> _sealed = new();
    readonly Timer _timer;

    public SettingsStore() => _timer = new Timer(_ => Flush(), null, Timeout.Infinite, Timeout.Infinite);

    /// <summary>Snapshot mode: keep changes in memory only, never write.</summary>
    public bool ReadOnly { get; set; }

    static string PathFor(string id) => Path.Combine(Paths.DataDir, id + ".json");

    public T Get<T>(string moduleId) where T : class, new() => (T)Get(typeof(T), moduleId);

    /// <summary>Get for a type known only at run time (setup codes). The type needs a public parameterless constructor.</summary>
    public object Get(Type type, string moduleId)
    {
        lock (_gate)
        {
            if (_cache.TryGetValue(moduleId, out var o) && type.IsInstanceOfType(o)) return o;
            object value;
            try
            {
                var p = PathFor(moduleId);
                value = (File.Exists(p) ? JsonSerializer.Deserialize(File.ReadAllText(p), type, Json) : null) ?? Activator.CreateInstance(type)!;
            }
            catch (Exception ex) { Log.Warn($"Settings '{moduleId}' unreadable, using defaults", ex); value = Activator.CreateInstance(type)!; }
            _cache[moduleId] = value;
            return value;
        }
    }

    public void Save<T>(string moduleId, T value) where T : class
    {
        var json = JsonSerializer.Serialize(value, Json);
        lock (_gate)
        {
            if (_sealed.Contains(moduleId)) return;
            _cache[moduleId] = value;
            _pending[moduleId] = json;
            _timer.Change(500, Timeout.Infinite);
        }
    }

    /// <summary>Writes everything pending now. Called on exit.</summary>
    public void Flush()
    {
        KeyValuePair<string, string>[] items;
        lock (_gate) { items = ReadOnly ? [] : _pending.ToArray(); _pending.Clear(); }
        foreach (var (id, json) in items) Write(id, json);
    }

    /// <summary>
    /// Replaces whole files now (a setup code, applied right before a restart). Every later Save of them is ignored, so the live
    /// objects of this run cannot write the old values back before it exits.
    /// </summary>
    /// <returns>False when a file could not be written (logged).</returns>
    public bool Replace(IReadOnlyDictionary<string, string> files)
    {
        lock (_gate)
            foreach (var id in files.Keys) { _pending.Remove(id); _sealed.Add(id); }
        if (ReadOnly) return true;
        var ok = true;
        foreach (var (id, json) in files) ok &= Write(id, json);
        return ok;
    }

    static bool Write(string id, string json)
    {
        try
        {
            var p = PathFor(id);
            var tmp = p + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, p, true);
            return true;
        }
        catch (Exception ex) { Log.Error($"Saving settings '{id}' failed", ex); return false; }
    }
}
