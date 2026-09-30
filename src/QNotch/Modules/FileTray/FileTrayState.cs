using System.Collections.ObjectModel;
using System.Windows.Media;
using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Modules.FileTray;

/// <summary>One file or folder referenced by the tray. The tray never owns the file. Written on the UI thread by the FileTray module.</summary>
public sealed partial class TrayItem : ObservableObject
{
    public TrayItem(string path)
    {
        Path = path;
        var n = System.IO.Path.GetFileName(path.TrimEnd('\\', '/'));
        Name = n.Length > 0 ? n : path;
    }

    public string Path { get; }
    public string Name { get; }

    [ObservableProperty, NotifyPropertyChangedFor(nameof(FallbackGlyph))] bool _isFolder;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(FallbackGlyph))] bool _isMissing;
    /// <summary>Empty until inspected, "Folder" for directories, "Missing" for stale entries.</summary>
    [ObservableProperty] string _sizeText = "";
    /// <summary>Frozen shell thumbnail; null until loaded (the view shows <see cref="FallbackGlyph"/>).</summary>
    [ObservableProperty] ImageSource? _thumbnail;

    public string FallbackGlyph => IsMissing ? "" : IsFolder ? "" : "";
}

/// <summary>File tray model: newest first, persisted by the module as a list of paths.</summary>
public sealed partial class FileTrayState : ObservableObject
{
    public ObservableCollection<TrayItem> Items { get; } = new();
    /// <summary>Latest few items for the Home card.</summary>
    public ObservableCollection<TrayItem> Recent { get; } = new();

    [ObservableProperty] int _count;
    [ObservableProperty] string _countText = "No files";
    [ObservableProperty] string _missingText = "";
    [ObservableProperty, NotifyPropertyChangedFor(nameof(HasItems))] bool _isEmpty = true;
    /// <summary>Transient feedback line ("Added 2 files", "Exported to ..."). Empty when idle.</summary>
    [ObservableProperty] string _status = "";

    public bool HasItems => !IsEmpty;
}
