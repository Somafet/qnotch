using System.Windows;
using System.Windows.Controls;
using QNotch.Theme;

namespace QNotch.Modules.NoteGithub;

/// <summary>Stub: registers placeholders so the shell looks complete. The NoteGithub agent replaces everything in this folder.</summary>
public sealed class NoteGithubModule : INotchModule
{
    public string Id => "notegithub";

    public void Initialize(ModuleContext ctx)
    {
        ctx.Cards.Register(new CardDescriptor("note", "Note", 60,
            () => Placeholder.Create(Glyphs.Note, "", "Your note will live here.")));
        ctx.Cards.Register(new CardDescriptor("github", "GitHub", 50,
            () => Placeholder.Create(Glyphs.Github, "", "Add a token in Settings to see your activity.")));
        ctx.SettingsSections.Register(new SettingsSectionDescriptor("github", "GitHub", Glyphs.Github, 50,
            () => Pad(Placeholder.Create(Glyphs.Github, "GitHub", "Token setup is not built yet."))));
    }

    static FrameworkElement Pad(FrameworkElement e) { e.Margin = new Thickness(28, 80, 28, 28); return e; }
}
