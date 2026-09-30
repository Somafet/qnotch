using QNotch.Theme;

namespace QNotch.Modules.NoteGithub;

/// <summary>Personal note card and GitHub contribution card (plus the GitHub settings section).</summary>
public sealed class NoteGithubModule : INotchModule, ICadenceAware
{
    GithubService? _github;

    public void Initialize(ModuleContext ctx)
    {
        var s = new NoteGithubState();
        var note = new NoteStore(ctx, s);
        var github = _github = new GithubService(ctx, s);

        ctx.Cards.Register(new CardDescriptor("note", "Note", 45, () => new NoteCard(s)));
        ctx.Cards.Register(new CardDescriptor("github", "GitHub", 50, () => new GithubCard(s, github, ctx.Shell), ColumnSpan: 2));
        ctx.SettingsSections.Register(new SettingsSectionDescriptor("github", "GitHub", Glyphs.Github, 50, () => GithubSection.Create(s, github)));

        note.Start();
        github.Start();
    }

    /// <summary>Fast means the panel opened: refresh the relative "updated" text. Nothing else runs on a cadence.</summary>
    public void SetCadence(Cadence cadence)
    {
        if (cadence == Cadence.Fast) _github?.RefreshTexts();
    }
}
