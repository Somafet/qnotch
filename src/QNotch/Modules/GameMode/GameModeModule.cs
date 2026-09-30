using System.Windows;
using System.Windows.Controls;
using QNotch.Theme;

namespace QNotch.Modules.GameMode;

/// <summary>Stub: registers placeholders so the shell looks complete. The GameMode agent replaces everything in this folder.</summary>
public sealed class GameModeModule : INotchModule
{
    public string Id => "gamemode";

    public void Initialize(ModuleContext ctx)
    {
        // Replace this folder's contents: detection, status bar view, override handling.
        ctx.SettingsSections.Register(new SettingsSectionDescriptor("gamemode", "Game mode", Glyphs.Game, 20,
            () => Pad(Placeholder.Create(Glyphs.Game, "Game mode", "Detection and the status bar are not built yet."))));
    }

    static FrameworkElement Pad(FrameworkElement e) { e.Margin = new Thickness(28, 80, 28, 28); return e; }
}
