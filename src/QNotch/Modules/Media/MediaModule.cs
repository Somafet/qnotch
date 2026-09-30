using System.Windows;
using System.Windows.Controls;
using QNotch.Theme;

namespace QNotch.Modules.Media;

/// <summary>Stub: registers placeholders so the shell looks complete. The Media agent replaces everything in this folder.</summary>
public sealed class MediaModule : INotchModule
{
    public string Id => "media";

    public void Initialize(ModuleContext ctx)
    {
        ctx.Tabs.Register(new TabDescriptor("media", "Media", Glyphs.Music, 10,
            () => Placeholder.Create(Glyphs.Music, "Nothing playing", "Start music or a video and it shows up here.")));
        ctx.Cards.Register(new CardDescriptor("media", "Now playing", 20,
            () => Placeholder.Create(Glyphs.Music, "Nothing playing", "Media controls appear when an app plays audio."), ColumnSpan: 2));
    }
}
