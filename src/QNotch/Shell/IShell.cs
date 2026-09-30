using System.Windows.Interop;

namespace QNotch.Shell;

/// <summary>The shell as seen by modules. Modules never read shell internals or window state directly. All members: UI thread only.</summary>
public interface IShell
{
    /// <summary>Notch window handle (for clipboard listeners, message hooks). Never the foreground window unless a text box has focus.</summary>
    nint Hwnd { get; }
    /// <summary>Add a message hook on the notch window (WM_CLIPBOARDUPDATE, WM_DISPLAYCHANGE, ...). Set handled=true only if you consumed the message. Keep the delegate if you want to remove it.</summary>
    void AddHwndHook(HwndSourceHook hook);
    void RemoveHwndHook(HwndSourceHook hook);

    /// <summary>Id of the selected tab ("home", "media", ...), and its change event.</summary>
    string ActiveTab { get; }
    event Action<string>? TabChanged;
    /// <summary>Switch the panel to a tab id (opens nothing by itself).</summary>
    void SelectTab(string tabId);
    void ClosePanel();
    void OpenSettings(string? sectionId = null);

    /// <summary>The panel is pinned open (Settings, General).</summary>
    bool IsPinned { get; }
    /// <summary>Home edit mode is on (the panel never auto-closes while it is).</summary>
    bool IsEditMode { get; }

    /// <summary>Keeps the panel open (no auto close on pointer leave or focus loss) until the returned handle is disposed.
    /// Use it around drag-out (DoDragDrop), file dialogs, menus and card drags.</summary>
    IDisposable HoldOpen();

    /// <summary>Files are being dragged over the notch. The shell opens the panel itself; a module may switch to its tab here.</summary>
    event Action? FileDragEntered;
    /// <summary>Files dropped anywhere on the panel that no element handled. Absolute paths. While nobody subscribes, the panel refuses file drops.</summary>
    event Action<string[]>? FilesDropped;
}
