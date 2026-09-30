using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows.Data;
using System.Windows.Media;
using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Core;

public enum ClipKind { Text, Code, Link, Image }
public enum ClipFilter { All, Text, Code, Images }

/// <summary>One clipboard history entry. Content is immutable; only pin, copy feedback and the subtitle change.</summary>
public sealed partial class ClipEntry : ObservableObject
{
    public ClipKind Kind { get; init; }
    /// <summary>Dedupe key: the text itself, or a content hash for images.</summary>
    public string Key { get; init; } = "";
    public string Text { get; init; } = "";
    /// <summary>Short, pre-formatted text for the list (two lines at most).</summary>
    public string Preview { get; init; } = "";
    /// <summary>Single line for the Home card.</summary>
    public string Line { get; init; } = "";
    /// <summary>For example "Code · 14 lines". The age is appended by the module while the tab is visible.</summary>
    public string Meta { get; init; } = "";
    public DateTime Created { get; set; } = DateTime.Now;
    public ImageSource? Thumb { get; init; }
    /// <summary>PNG bytes of an image entry (used for copy again).</summary>
    public byte[]? Png { get; init; }

    public bool IsImage => Kind == ClipKind.Image;
    public bool IsCode => Kind == ClipKind.Code;
    public bool IsLink => Kind == ClipKind.Link;
    public bool IsPlain => Kind is ClipKind.Text or ClipKind.Link;
    public string Glyph => Kind switch { ClipKind.Code => "", ClipKind.Link => "", ClipKind.Image => "", _ => "" };

    [ObservableProperty] bool _pinned;
    [ObservableProperty] bool _justCopied;
    [ObservableProperty] string _subtitle = "";
}

/// <summary>Clipboard history model. Only touched on the UI thread; the Clipboard module mutates it.</summary>
public sealed partial class ClipboardState : ObservableObject
{
    public ObservableCollection<ClipEntry> Entries { get; } = new();
    public ICollectionView View { get; }

    [ObservableProperty] ClipFilter _filter = ClipFilter.All;
    [ObservableProperty] bool _isAvailable = true;
    [ObservableProperty] bool _hasUnpinned;
    [ObservableProperty] string _countText = "";
    [ObservableProperty] bool _showList;
    [ObservableProperty] bool _showEmpty;
    [ObservableProperty] bool _showUnavailable;
    [ObservableProperty] string _emptyTitle = "";
    [ObservableProperty] string _emptyMessage = "";
    /// <summary>Incremented when an entry's copy feedback flips, so the Home card can redraw.</summary>
    [ObservableProperty] int _flash;

    public ClipboardState()
    {
        View = CollectionViewSource.GetDefaultView(Entries);
        View.Filter = o => o is ClipEntry e && Matches(e);
        Recount();
    }

    bool Matches(ClipEntry e) => Filter switch
    {
        ClipFilter.Text => e.IsPlain,
        ClipFilter.Code => e.IsCode,
        ClipFilter.Images => e.IsImage,
        _ => true,
    };

    partial void OnFilterChanged(ClipFilter value) { View.Refresh(); Recount(); }
    partial void OnIsAvailableChanged(bool value) => Recount();

    /// <summary>Call after any change to Entries. Every write is set-if-changed.</summary>
    public void Recount()
    {
        int n = Entries.Count;
        HasUnpinned = Entries.Any(e => !e.Pinned);
        CountText = n == 1 ? "1 item" : $"{n} items";
        bool empty = n == 0 || View.IsEmpty;
        ShowUnavailable = !IsAvailable;
        ShowEmpty = IsAvailable && empty;
        ShowList = IsAvailable && !empty;
        if (n == 0) { EmptyTitle = "Nothing copied yet"; EmptyMessage = "Text and images you copy will show up here."; }
        else
        {
            EmptyTitle = "No matches";
            EmptyMessage = Filter switch
            {
                ClipFilter.Code => "Code snippets you copy will show up here.",
                ClipFilter.Images => "Images you copy will show up here.",
                _ => "Text you copy will show up here.",
            };
        }
    }

    public void NotifyFlash() => Flash++;
}

public sealed partial class AppState
{
    public ClipboardState Clipboard { get; } = new();
}
