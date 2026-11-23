namespace QNotch.Calculator;

/// <summary>One sheet as the tab strip shows it.</summary>
public sealed record SheetTab(Guid Id, string Name);

/// <summary>A sheet the user closed whose delete is still waiting. Position is its place among the visible tabs when it was closed.</summary>
public sealed record ClosedSheet(Guid Id, string Name, int Position, bool WasActive);

public enum CloseVerdict { Allowed, Unknown, LastSheet }

/// <summary>
/// The tab strip's state, without any UI: which sheets show, which is active, and which were closed but not deleted yet.
/// A closed sheet stays in the workspace catalog until its undo window ends, so a crash during the window loses nothing, its name stays
/// taken and it still counts toward the sheet limit. All closes share one deadline, moved on by every close and undo, so a run of closes
/// stays undoable one by one. Not thread safe: the UI thread owns it.
/// </summary>
public sealed class SheetTabList
{
    public static readonly TimeSpan UndoWindow = TimeSpan.FromSeconds(8);
    public const int MaxSheets = 256;

    readonly List<SheetTab> _all = [];
    readonly List<ClosedSheet> _closed = []; // oldest first
    readonly HashSet<Guid> _closedIds = [];
    List<SheetTab>? _visible;

    public Guid ActiveId { get; private set; }

    /// <summary>When the waiting closes become real deletes; null while nothing waits.</summary>
    public DateTimeOffset? DueAt { get; private set; }

    public IReadOnlyList<SheetTab> Visible => _visible ??= _all.Where(tab => !_closedIds.Contains(tab.Id)).ToList();
    public IReadOnlyList<ClosedSheet> Closed => _closed;
    public ClosedSheet? LastClosed => _closed.Count == 0 ? null : _closed[^1];

    /// <summary>Every sheet the catalog still holds, waiting closes included. This is what the sheet limit counts.</summary>
    public int TotalCount => _all.Count;
    public bool CanCreate => _all.Count < MaxSheets;
    public bool IsClosed(Guid id) => _closedIds.Contains(id);
    public bool Contains(Guid id) => _all.Any(tab => tab.Id == id);

    /// <summary>Takes the catalog's sheets and active sheet. A waiting close survives unless its sheet left the catalog.</summary>
    public void Update(IEnumerable<SheetTab> catalog, Guid activeId)
    {
        _all.Clear();
        _all.AddRange(catalog);
        _visible = null;
        var present = _all.Select(tab => tab.Id).ToHashSet();
        if (_closed.RemoveAll(sheet => !present.Contains(sheet.Id)) > 0)
        {
            _closedIds.IntersectWith(present);
            if (_closed.Count == 0) DueAt = null;
        }
        // Sync removed every other sheet while this one waited for its delete: it is now the last sheet, so it stays.
        if (_closed.Count > 0 && Visible.Count == 0)
        {
            _closedIds.Remove(_closed[^1].Id);
            _closed.RemoveAt(_closed.Count - 1);
            _visible = null;
            if (_closed.Count == 0) DueAt = null;
        }
        ActiveId = activeId;
        if (_closedIds.Contains(ActiveId) || !present.Contains(ActiveId))
            ActiveId = Visible.Count > 0 ? Visible[0].Id : activeId;
    }

    public bool SetActive(Guid id)
    {
        if (_closedIds.Contains(id) || !Contains(id)) return false;
        ActiveId = id;
        return true;
    }

    public CloseVerdict CanClose(Guid id)
    {
        if (_closedIds.Contains(id) || !Contains(id)) return CloseVerdict.Unknown;
        return Visible.Count <= 1 ? CloseVerdict.LastSheet : CloseVerdict.Allowed;
    }

    /// <summary>The other visible sheets in the order a close should try them: outward from the sheet, right side first.</summary>
    public IEnumerable<Guid> NeighborsOf(Guid id)
    {
        var tabs = Visible;
        var index = -1;
        for (var i = 0; i < tabs.Count; i++) if (tabs[i].Id == id) { index = i; break; }
        if (index < 0) yield break;
        for (var distance = 1; distance < tabs.Count; distance++)
        {
            if (index + distance < tabs.Count) yield return tabs[index + distance].Id;
            if (index - distance >= 0) yield return tabs[index - distance].Id;
        }
    }

    /// <summary>Hides a sheet and starts or extends the undo window. Closing the active sheet activates <paramref name="next"/>, or its
    /// nearest neighbor when none is given. Null when the sheet cannot be closed.</summary>
    public ClosedSheet? Close(Guid id, DateTimeOffset now, Guid? next = null)
    {
        if (CanClose(id) != CloseVerdict.Allowed) return null;
        var wasActive = id == ActiveId;
        var successor = wasActive ? next ?? NeighborsOf(id).First() : ActiveId;
        if (wasActive && (successor == id || _closedIds.Contains(successor) || !Contains(successor))) return null;
        var position = 0;
        var visible = Visible;
        for (var i = 0; i < visible.Count; i++) if (visible[i].Id == id) { position = i; break; }
        var closed = new ClosedSheet(id, visible[position].Name, position, wasActive);
        _closed.Add(closed);
        _closedIds.Add(id);
        _visible = null;
        ActiveId = successor;
        DueAt = now + UndoWindow;
        return closed;
    }

    /// <summary>Brings back the most recent close at its old place, active again if it was active. Waiting closes get a fresh window.</summary>
    public ClosedSheet? Undo(DateTimeOffset now)
    {
        if (_closed.Count == 0) return null;
        var sheet = _closed[^1];
        _closed.RemoveAt(_closed.Count - 1);
        _closedIds.Remove(sheet.Id);
        _visible = null;
        if (sheet.WasActive) ActiveId = sheet.Id;
        DueAt = _closed.Count == 0 ? null : now + UndoWindow;
        return sheet;
    }

    /// <summary>The closes whose window ended, oldest first. They leave this list; the caller deletes them from the store.</summary>
    public IReadOnlyList<ClosedSheet> TakeExpired(DateTimeOffset now) => DueAt is { } due && now >= due ? TakeAll() : [];

    /// <summary>Every waiting close, for shutdown.</summary>
    public IReadOnlyList<ClosedSheet> TakeAll()
    {
        var taken = _closed.ToArray();
        _closed.Clear();
        _closedIds.Clear();
        DueAt = null;
        if (taken.Length > 0)
        {
            var gone = taken.Select(sheet => sheet.Id).ToHashSet();
            _all.RemoveAll(tab => gone.Contains(tab.Id));
            _visible = null;
        }
        return taken;
    }

    /// <summary>The first numbered name no sheet uses, counting sheets that are waiting to be deleted.</summary>
    public string UniqueName(Func<int, string> format)
    {
        var used = _all.Select(tab => tab.Name).ToHashSet(StringComparer.Ordinal);
        for (var number = 1; ; number++)
        {
            var name = format(number);
            if (!used.Contains(name)) return name;
        }
    }
}
