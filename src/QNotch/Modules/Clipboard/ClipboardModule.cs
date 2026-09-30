using System.Windows;
using System.Windows.Controls;
using QNotch.Theme;

namespace QNotch.Modules.Clipboard;

/// <summary>Stub: registers placeholders so the shell looks complete. The Clipboard agent replaces everything in this folder.</summary>
public sealed class ClipboardModule : INotchModule
{
    public string Id => "clipboard";

    public void Initialize(ModuleContext ctx)
    {
        ctx.Tabs.Register(new TabDescriptor("clipboard", "Clipboard", Glyphs.Clipboard, 20,
            () => Placeholder.Create(Glyphs.Clipboard, "Clipboard history", "Copied text and images will appear here.")));
        ctx.Cards.Register(new CardDescriptor("clipboard", "Clipboard", 30,
            () => Placeholder.Create(Glyphs.Clipboard, "", "Nothing copied yet.")));
        ctx.SettingsSections.Register(new SettingsSectionDescriptor("clipboard", "Clipboard", Glyphs.Clipboard, 30,
            () => Pad(Placeholder.Create(Glyphs.Clipboard, "Clipboard", "History options are not built yet."))));
    }

    static FrameworkElement Pad(FrameworkElement e) { e.Margin = new Thickness(28, 80, 28, 28); return e; }
}
