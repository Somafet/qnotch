using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using QNotch.Core;
using QNotch.Shell;

namespace QNotch.Modules.FileTray;

public partial class FileTrayView : UserControl
{
    readonly FileTrayService _svc;
    readonly FileTrayState _state;
    readonly IShell _shell;
    IDisposable? _menuHold;
    Point? _dragStart;

    public FileTrayView(FileTrayService svc, FileTrayState state, IShell shell)
    {
        _svc = svc;
        _state = state;
        _shell = shell;
        DataContext = state;
        InitializeComponent();
    }

    // ---------- drop target (events stay unhandled so the shell keeps its own drop logic) ----------

    void OnDrag(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop)) DropOverlay.Visibility = Visibility.Visible;
    }

    void OnDragLeave(object sender, DragEventArgs e) => DropOverlay.Visibility = Visibility.Collapsed;

    // ---------- drag out ----------

    void OnTileDown(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject d && FindParent<Button>(d) is not null) return; // action buttons keep their clicks
        if (Item(sender) is not { } it) return;
        if (e.ClickCount == 2) { _dragStart = null; if (!it.IsMissing) _svc.Open(it); return; }
        _dragStart = e.GetPosition(this);
    }

    void OnTileMove(object sender, MouseEventArgs e)
    {
        if (_dragStart is not { } start || e.LeftButton != MouseButtonState.Pressed) return;
        var p = e.GetPosition(this);
        if (Math.Abs(p.X - start.X) < SystemParameters.MinimumHorizontalDragDistance
            && Math.Abs(p.Y - start.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _dragStart = null;
        if (Item(sender) is not { IsMissing: false } it) return;
        // Copy and Link only: a drop target can never move the original out of its folder.
        var data = new DataObject(DataFormats.FileDrop, new[] { it.Path });
        using (_shell.HoldOpen()) DragDrop.DoDragDrop((DependencyObject)sender, data, DragDropEffects.Copy | DragDropEffects.Link);
    }

    void OnTileLeave(object sender, MouseEventArgs e) => _dragStart = null;

    // ---------- header actions ----------

    void OnAdd(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog { Multiselect = true, Title = "Add files to the tray" };
        bool ok;
        using (_shell.HoldOpen()) ok = dlg.ShowDialog() == true;
        if (ok) _svc.Add(dlg.FileNames);
    }

    void OnExportAll(object sender, RoutedEventArgs e) => ExportTo(_state.Items.ToArray());
    void OnClear(object sender, RoutedEventArgs e) => _svc.Clear();

    // ---------- per item actions (buttons and context menu share the handlers) ----------

    void OnOpen(object sender, RoutedEventArgs e) { if (Item(sender) is { IsMissing: false } it) _svc.Open(it); }
    void OnReveal(object sender, RoutedEventArgs e) { if (Item(sender) is { IsMissing: false } it) _svc.Reveal(it); }
    void OnExport(object sender, RoutedEventArgs e) { if (Item(sender) is { IsMissing: false } it) ExportTo([it]); }
    void OnRemove(object sender, RoutedEventArgs e) { if (Item(sender) is { } it) _svc.Remove(it); }

    void OnCopyPath(object sender, RoutedEventArgs e)
    {
        if (Item(sender) is not { } it) return;
        try { System.Windows.Clipboard.SetText(it.Path); _svc.SetStatus("Path copied"); }
        catch (Exception ex) { Log.Warn("FileTray: copy path failed", ex); _svc.SetStatus("Could not copy the path"); }
    }

    void OnMenuOpened(object sender, RoutedEventArgs e) => _menuHold ??= _shell.HoldOpen();
    void OnMenuClosed(object sender, RoutedEventArgs e) { _menuHold?.Dispose(); _menuHold = null; }

    void ExportTo(IReadOnlyList<TrayItem> items)
    {
        if (items.Count == 0) return;
        var dlg = new OpenFolderDialog { Title = "Export to folder" };
        bool ok;
        using (_shell.HoldOpen()) ok = dlg.ShowDialog() == true;
        if (ok) _svc.Export(items, dlg.FolderName);
    }

    static TrayItem? Item(object sender) => (sender as FrameworkElement)?.DataContext as TrayItem;

    static T? FindParent<T>(DependencyObject d) where T : DependencyObject
    {
        for (; d is not null; d = System.Windows.Media.VisualTreeHelper.GetParent(d) ?? LogicalTreeHelper.GetParent(d))
            if (d is T t) return t;
        return null;
    }
}
