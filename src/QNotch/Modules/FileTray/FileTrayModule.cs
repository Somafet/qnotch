using QNotch.Theme;

namespace QNotch.Modules.FileTray;

/// <summary>
/// File tray: references to files you want within reach. Nothing runs while collapsed: no timers, no watchers. Items are
/// inspected (existence, size, thumbnail) on a short-lived STA thread when the panel opens or files are added.
/// </summary>
public sealed class FileTrayModule : INotchModule, ICadenceAware
{
    public string Id => "filetray";

    FileTrayService? _svc;

    public void Initialize(ModuleContext ctx)
    {
        var state = new FileTrayState();
        var svc = _svc = new FileTrayService(ctx, state);
        var shell = ctx.Shell;

        ctx.Tabs.Register(new TabDescriptor("files", "Files", Glyphs.Folder, 40, () => new FileTrayView(svc, state, shell)));
        ctx.Cards.Register(new CardDescriptor("files", "File tray", 80, () => new FileTrayCard(shell) { DataContext = state }));

        // Subscribing also makes the notch accept file drops. Dragging files over the notch reveals the drop target on the Files tab.
        shell.FilesDropped += svc.Add;
        shell.FileDragEntered += () => shell.SelectTab("files");
    }

    public void SetCadence(Cadence cadence)
    {
        if (cadence == Cadence.Fast) _svc?.Refresh();
    }
}
