using QNotch.Theme;

namespace QNotch.Modules.Notes;

/// <summary>Personal note card, saved to note.txt. Nothing runs on a cadence.</summary>
public sealed class NoteModule : INotchModule
{
    public void Initialize(ModuleContext ctx)
    {
        var s = new NoteState();
        var note = new NoteStore(ctx, s);

        ctx.Cards.Register(new CardDescriptor("note", "Note", 45, () => new NoteCard(s)));

        ctx.Search.Register(new SearchSource("note", "Note", Glyphs.Note, 30, q => s.NoteText.Split('\n')
            .Where(l => l.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Select(l => new SearchHit(SearchHit.Snippet(l, q), "", () => ctx.Shell.SelectTab("home")))));

        note.Start();
    }
}
