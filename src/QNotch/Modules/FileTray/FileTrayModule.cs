using QNotch.Theme;

namespace QNotch.Modules.FileTray;

/// <summary>
/// File tray: references to files you want within reach. Nothing runs while collapsed: no timers, no watchers. Items are
/// inspected (existence, size, thumbnail) on a short-lived STA thread when the panel opens or files are added. Phone sharing
/// (<see cref="PhoneShareService"/>) listens on the network only while a session the user started is running.
/// </summary>
public sealed class FileTrayModule : INotchModule, ICadenceAware
{
    FileTrayService? _svc;
    PhoneShareService? _share;

    public void Initialize(ModuleContext ctx)
    {
        var state = new FileTrayState();
        var svc = _svc = new FileTrayService(ctx, state);
        var share = _share = new PhoneShareService(ctx, state, svc);
        var shell = ctx.Shell;

        // A running phone session keeps the tab openable even with an empty tray (receive only).
        ctx.Tabs.Register(new TabDescriptor("files", "Files", Glyphs.Folder, 40, () => new FileTrayView(svc, state, shell, share), () => state.IsEmpty && !state.Share.IsActive));
        ctx.Cards.Register(new CardDescriptor("files", "File tray", 80, () => new FileTrayCard(shell) { DataContext = state }));

        ctx.Search.Register(new SearchSource("files", "File tray", Glyphs.Folder, 20, q => state.Items
            .Where(i => i.Name.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Select(i => new SearchHit(i.Name, i.Path, () => { svc.Open(i); shell.ClosePanel(); }))));

        // Files dragged onto the notch: the drop screen offers the tray; a drop adds them and shows the tray.
        ctx.Drops.Register(new DropSourceDescriptor("files", "File tray", Glyphs.Folder, 10, files => [DropTarget(state, files, paths => { svc.Add(paths); shell.SelectTab("files"); })]));
    }

    /// <summary>The tray's one drop target: off when every dragged item is already in the tray.</summary>
    internal static DropTarget DropTarget(FileTrayState state, IReadOnlyList<string> files, Action<string[]> add)
    {
        var all = files.Count > 0 && files.All(f => state.Items.Any(i => string.Equals(i.Path, f, StringComparison.OrdinalIgnoreCase)));
        return new DropTarget("add", "Add to tray", Glyphs.Add, add, all ? "Already in the tray" : "Keep them within reach", Enabled: !all);
    }

    public void SetCadence(Cadence cadence)
    {
        if (cadence == Cadence.Fast) _svc?.Refresh();
        _share?.SetCadence(cadence);
    }
}
