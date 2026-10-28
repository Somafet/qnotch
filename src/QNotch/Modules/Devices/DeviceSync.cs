namespace QNotch.Modules.Devices;

/// <summary>Causal, multi-value note register. No timestamps, last-writer data loss or unbounded history.</summary>
public sealed record NoteRevision(string Id, Dictionary<string, long> Clock, string Text);
public sealed record ClipboardRevision(long Counter, string Author, string Text);
public sealed record SyncBundle(bool NotesEnabled, bool ClipboardEnabled, List<NoteRevision> Notes, ClipboardRevision? Clipboard);
public sealed class SyncJournal
{
    public List<NoteRevision> Notes { get; set; } = [];
    public Dictionary<string, long> ActiveClock { get; set; } = [];
    // Clipboard text is deliberately excluded from persistence.
    public long ClipboardCounter { get; set; }
    public string ClipboardAuthor { get; set; } = "";
}

public sealed class DeviceSync(string deviceId, SyncJournal journal)
{
    public const int MaxNoteChars = 100000, MaxBranches = 8, MaxAuthors = 64;
    ClipboardRevision? clipboard;
    public SyncJournal Journal => journal;
    public IReadOnlyList<NoteRevision> Notes => journal.Notes;
    public ClipboardRevision? Clipboard => clipboard;
    public static void ValidateJournal(SyncJournal value)
    {
        Merge(value.Notes, []);
        if (value.ActiveClock is null || value.ActiveClock.Count > MaxAuthors || value.ActiveClock.Any(p => !DeviceProtocol.ValidId(p.Key) || p.Value is <= 0 or >= 9007199254740991) ||
            value.ClipboardCounter is < 0 or >= 9007199254740991 || value.ClipboardCounter > 0 && !DeviceProtocol.ValidId(value.ClipboardAuthor))
            throw new IOException("Invalid sync journal.");
    }
    public DeviceSync Clone()
    {
        var copy = new DeviceSync(deviceId, new SyncJournal
        {
            Notes = journal.Notes.Select(i => i with { Clock = new(i.Clock) }).ToList(), ActiveClock = new(journal.ActiveClock),
            ClipboardCounter = journal.ClipboardCounter, ClipboardAuthor = journal.ClipboardAuthor,
        });
        copy.clipboard = clipboard; return copy;
    }
    public bool ReconcileEditor(string text)
    {
        if (text.Length > MaxNoteChars) throw new IOException("Note exceeds the sync limit.");
        if (journal.Notes.FirstOrDefault(i => i.Text == text) is { } existing) { journal.ActiveClock = new(existing.Clock); return false; }
        if (journal.Notes.Count == 0) return text.Length > 0 && EditNote(text);
        // A crash between two atomic files, or an external edit while stopped, must not discard
        // either copy. Recover as an independent branch, never pretend it observed the journal.
        var recovered = new NoteRevision(DeviceProtocol.Id(), new() { [DeviceProtocol.Id()] = 1 }, text);
        journal.Notes = Merge(journal.Notes, [recovered]); journal.ActiveClock = new(recovered.Clock); return true;
    }
    static bool Includes(IReadOnlyDictionary<string, long> a, IReadOnlyDictionary<string, long> b) => b.All(p => a.GetValueOrDefault(p.Key) >= p.Value);
    static bool SameClock(IReadOnlyDictionary<string, long> a, IReadOnlyDictionary<string, long> b) => Includes(a, b) && Includes(b, a);
    public static void Validate(NoteRevision item)
    {
        if (item is null || !DeviceProtocol.ValidId(item.Id) || item.Text is null || item.Text.Length > MaxNoteChars ||
            item.Clock is null || item.Clock.Count is < 1 or > MaxAuthors || item.Clock.Any(p => !DeviceProtocol.ValidId(p.Key) || p.Value <= 0 || p.Value >= 9007199254740991))
            throw new IOException("Invalid note revision.");
    }
    public static List<NoteRevision> Merge(IEnumerable<NoteRevision> left, IEnumerable<NoteRevision> right)
    {
        var all = left.Concat(right).ToList();
        if (all.Count > MaxBranches * 2) throw new IOException("Too many note versions. Resolve the current conflicts first.");
        foreach (var item in all) Validate(item);
        foreach (var group in all.GroupBy(i => i.Id))
            if (group.Any(i => i.Text != group.First().Text || !SameClock(i.Clock, group.First().Clock))) throw new IOException("A note revision changed its identity.");
        all = all.DistinctBy(i => i.Id).ToList();
        for (int i = 0; i < all.Count; i++)
            for (int j = i + 1; j < all.Count; j++)
                if (SameClock(all[i].Clock, all[j].Clock)) throw new IOException("Conflicting note identities.");
        var result = all.Where(i => !all.Any(other => other.Id != i.Id && Includes(other.Clock, i.Clock)))
            .OrderBy(i => i.Id, StringComparer.Ordinal).ToList();
        if (result.Count > MaxBranches) throw new IOException("Too many note versions. Resolve the current conflicts first.");
        return result;
    }
    static Dictionary<string, long> Join(IEnumerable<IReadOnlyDictionary<string, long>> clocks)
    {
        var result = new Dictionary<string, long>();
        foreach (var clock in clocks) foreach (var (key, value) in clock) result[key] = Math.Max(result.GetValueOrDefault(key), value);
        return result;
    }
    public bool EditNote(string text, bool resolveAll = false)
    {
        if (text.Length > MaxNoteChars) throw new IOException("Note exceeds the sync limit.");
        if (!resolveAll && journal.Notes.Count == 1 && journal.Notes[0].Text == text)
        { journal.ActiveClock = new(journal.Notes[0].Clock); return false; }
        var clock = resolveAll ? Join(journal.Notes.Select(i => (IReadOnlyDictionary<string, long>)i.Clock).Append(journal.ActiveClock)) : new(journal.ActiveClock);
        // A device's own counter never goes backwards, even after a remote merge.
        var own = journal.Notes.Select(i => i.Clock.GetValueOrDefault(deviceId)).Append(clock.GetValueOrDefault(deviceId)).Max();
        clock[deviceId] = checked(own + 1);
        var next = new NoteRevision(DeviceProtocol.Id(), clock, text); Validate(next);
        var merged = Merge(journal.Notes, [next]);
        journal.Notes = merged; journal.ActiveClock = new(clock); return true;
    }
    public string? ReceiveNotes(IEnumerable<NoteRevision> remote)
    {
        journal.Notes = Merge(journal.Notes, remote);
        if (journal.Notes.Count != 1) return null; // Keep the editor's local text until the user resolves conflicts.
        journal.ActiveClock = new(journal.Notes[0].Clock); return journal.Notes[0].Text;
    }
    public void CopyText(string text)
    {
        if (text.Length > 16000 || journal.ClipboardCounter >= 9007199254740990) throw new IOException("Clipboard text or revision exceeds the sync limit.");
        journal.ClipboardCounter = checked(journal.ClipboardCounter + 1); journal.ClipboardAuthor = deviceId;
        clipboard = new(journal.ClipboardCounter, deviceId, text);
    }
    public string? ReceiveClipboard(ClipboardRevision? incoming)
    {
        if (incoming is null) return null;
        if (incoming.Counter is <= 0 or >= 9007199254740991 || !DeviceProtocol.ValidId(incoming.Author) || incoming.Text is null || incoming.Text.Length > 16000)
            throw new IOException("Invalid clipboard revision.");
        if (incoming.Counter < journal.ClipboardCounter || incoming.Counter == journal.ClipboardCounter && string.CompareOrdinal(incoming.Author, journal.ClipboardAuthor) <= 0) return null;
        journal.ClipboardCounter = incoming.Counter; journal.ClipboardAuthor = incoming.Author; clipboard = incoming;
        return incoming.Text;
    }
    public SyncBundle Bundle(bool notes, bool clips) => new(notes, clips, notes ? journal.Notes : [], clips ? clipboard : null);
}
