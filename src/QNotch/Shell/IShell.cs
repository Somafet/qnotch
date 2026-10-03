using System.Windows.Interop;

namespace QNotch.Shell;

/// <summary>The shell as seen by modules. Modules never read shell internals or window state directly. All members: UI thread only.</summary>
public interface IShell
{
    /// <summary>Notch window handle (for clipboard listeners, message hooks). Never the foreground window unless a text box has focus.</summary>
    nint Hwnd { get; }
    /// <summary>Add a message hook on the notch window (WM_CLIPBOARDUPDATE, WM_DISPLAYCHANGE, ...). Set handled=true only if you consumed the message.</summary>
    void AddHwndHook(HwndSourceHook hook);

    /// <summary>Id of the selected tab ("home", "media", ...), and its change event.</summary>
    string ActiveTab { get; }
    event Action<string>? TabChanged;
    /// <summary>Switch the panel to a tab id (opens nothing by itself).</summary>
    void SelectTab(string tabId);
    /// <summary>Opens the panel without taking the keyboard, optionally on a tab. Returns false in game mode (nothing opens).
    /// When the pointer is elsewhere the panel closes again after <paramref name="lingerMs"/> (at least the leave delay).</summary>
    bool TryOpenPanel(string? tabId = null, int lingerMs = 0);
    /// <summary>Opens the panel, optionally on a tab, and takes the keyboard like the toggle hotkey does: Esc or a click elsewhere
    /// closes it. Returns false in game mode. Only for an explicit summon by the user (a module hotkey).</summary>
    bool OpenPanelWithKeyboard(string? tabId = null);
    void ClosePanel();
    void OpenSettings(string? sectionId = null);

    /// <summary>Widens the collapsed pill for a moment to show one line in place of its segments ("api: Needs you"), for something the
    /// user should notice whatever app is in front. A newer peek replaces the shown one; disposing the handle ends it early. Shows
    /// nothing while the panel is open. Returns null in game mode, where the caller should stay quiet too (no sound).</summary>
    IDisposable? Peek(string glyph, string text, string brushKey, int ms = 4000);

    /// <summary>The panel is pinned open (Settings, General).</summary>
    bool IsPinned { get; }

    /// <summary>Keeps the panel open (no auto close on pointer leave or focus loss) until the returned handle is disposed.
    /// Use it around drag-out (DoDragDrop), file dialogs, menus and card drags.</summary>
    IDisposable HoldOpen();

    /// <summary>Files are being dragged over the notch. The shell opens the panel itself; a module may switch to its tab here.</summary>
    event Action? FileDragEntered;
    /// <summary>Files dropped anywhere on the panel that no element handled. Absolute paths. While nobody subscribes, the panel refuses file drops.</summary>
    event Action<string[]>? FilesDropped;
}
