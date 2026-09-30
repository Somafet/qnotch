using System.Windows;
using System.Windows.Controls;
using QNotch.Theme;

namespace QNotch.Modules.Ai;

/// <summary>Stub: registers placeholders so the shell looks complete. The Ai agent replaces everything in this folder.</summary>
public sealed class AiModule : INotchModule
{
    public string Id => "ai";

    public void Initialize(ModuleContext ctx)
    {
        ctx.Tabs.Register(new TabDescriptor("ai", "AI", Glyphs.Chat, 30,
            () => Placeholder.Create(Glyphs.Chat, "AI usage", "Usage per signed-in tool will appear here.")));
        ctx.Cards.Register(new CardDescriptor("ai-usage", "AI usage", 40,
            () => Placeholder.Create(Glyphs.Chat, "", "No providers connected.")));
        ctx.Cards.Register(new CardDescriptor("ai-apps", "AI apps", 70,
            () => Placeholder.Create(Glyphs.Chat, "", "No AI apps detected yet.")));
        ctx.SettingsSections.Register(new SettingsSectionDescriptor("ai", "AI", Glyphs.Chat, 40,
            () => Pad(Placeholder.Create(Glyphs.Chat, "AI", "Provider toggles are not built yet."))));
    }

    static FrameworkElement Pad(FrameworkElement e) { e.Margin = new Thickness(28, 80, 28, 28); return e; }
}
