using System.Windows;
using System.Windows.Controls;
using QNotch.Theme;

namespace QNotch.Modules.FileTray;

/// <summary>Stub: registers placeholders so the shell looks complete. The FileTray agent replaces everything in this folder.</summary>
public sealed class FileTrayModule : INotchModule
{
    public string Id => "filetray";

    public void Initialize(ModuleContext ctx)
    {
        ctx.Tabs.Register(new TabDescriptor("files", "Files", Glyphs.Folder, 40,
            () => Placeholder.Create(Glyphs.Folder, "File tray", "Drop files here to keep them within reach.")));
        ctx.Cards.Register(new CardDescriptor("files", "File tray", 80,
            () => Placeholder.Create(Glyphs.Folder, "", "Drop files here.")));
    }
}
