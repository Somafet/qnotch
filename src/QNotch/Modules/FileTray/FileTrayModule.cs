using QNotch.Theme;

namespace QNotch.Modules.FileTray;

/// <summary>
/// File tray: references to files you want within reach. Nothing runs while collapsed: no timers, no watchers. Items are
/// inspected (existence, size, thumbnail) on a short-lived STA thread when the panel opens or files are added.
/// </summary>
public sealed class FileTrayModule : INotchModule, ICadenceAware
{
    FileTrayService? _svc;

    public void Initialize(ModuleContext ctx)
    {
        var state = new FileTrayState();
        var svc = _svc = new FileTrayService(ctx, state);
        var shell = ctx.Shell;

        ctx.Tabs.Register(new TabDescriptor("files", "Files", Glyphs.Folder, 40, () => new FileTrayView(svc, state, shell), () => state.IsEmpty));
        ctx.Cards.Register(new CardDescriptor("files", "File tray", 80, () => new FileTrayCard(shell) { DataContext = state }));

        ctx.Search.Register(new SearchSource("files", "File tray", Glyphs.Folder, 20, q => state.Items
            .Where(i => i.Name.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Select(i => new SearchHit(i.Name, i.Path, () => { svc.Open(i); shell.ClosePanel(); }))));

        // Subscribing also makes the notch accept file drops. Dragging files over the notch reveals the drop target on the Files tab.
        shell.FilesDropped += svc.Add;
        shell.FileDragEntered += () => shell.SelectTab("files");
    }

    public void SetCadence(Cadence cadence)
    {
        if (cadence == Cadence.Fast) _svc?.Refresh();
    }
}
