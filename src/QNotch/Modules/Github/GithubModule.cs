using QNotch.Theme;

namespace QNotch.Modules.Github;

/// <summary>GitHub contribution card plus its settings section (token in Credential Manager).</summary>
public sealed class GithubModule : INotchModule, ICadenceAware
{
    GithubService? _github;

    public void Initialize(ModuleContext ctx)
    {
        var s = new GithubState();
        var github = _github = new GithubService(ctx, s);

        ctx.Cards.Register(new CardDescriptor("github", "GitHub", 50, () => new GithubCard(s, github, ctx.Shell), ColumnSpan: 2));
        ctx.SettingsSections.Register(new SettingsSectionDescriptor("github", "GitHub", Glyphs.Github, 50, () => GithubSection.Create(s, github)));

        github.Start();
    }

    /// <summary>Fast means the panel opened: refresh the relative "updated" text. Nothing else runs on a cadence.</summary>
    public void SetCadence(Cadence cadence)
    {
        if (cadence == Cadence.Fast) _github?.RefreshTexts();
    }
}
