using System.Windows;
using System.Windows.Interop;
using QNotch.Core;

namespace QNotch.Shell;

/// <summary>The shell as seen by modules. Modules never read shell internals or window state directly. All members: UI thread only.</summary>
public interface IShell
{
    ShellMode Mode { get; }
    event Action<ShellMode>? ModeChanged;

    /// <summary>Auto / ForceOn / ForceOff. Driven by the tray menu and hotkey; the Game mode module reacts to changes.</summary>
    GameModeOverride GameModeOverride { get; set; }
    event Action<GameModeOverride>? GameModeOverrideChanged;

    void OpenPanel();
    void ClosePanel();
    void TogglePanel();
    /// <summary>Switch the panel to a tab id (opens nothing by itself).</summary>
    void SelectTab(string tabId);
    /// <summary>Id of the selected tab ("home", "media", ...), and its change event.</summary>
    string ActiveTab { get; }
    event Action<string>? TabChanged;
    void OpenSettings(string? sectionId = null);

    bool IsPinned { get; set; }
    /// <summary>Edit mode for the Home grid (toggled by the header pencil). Implemented by the EditMode module via CardHost + CardLayout. The panel never auto-closes while it is on.</summary>
    bool IsEditMode { get; set; }
    event Action? EditModeChanged;

    /// <summary>Keeps the panel open (no auto close on pointer leave or focus loss) until the returned handle is disposed.
    /// Use it around drag-out (DoDragDrop), file dialogs, menus and card drags.</summary>
    IDisposable HoldOpen();

    /// <summary>Call before focusing a text input (TextBox/PasswordBox do it automatically on mouse down). Activates the window until it loses focus or collapses.</summary>
    void RequestKeyboardFocus();

    /// <summary>Files are being dragged over the notch. The shell opens the panel itself; a module may switch to its tab here.</summary>
    event Action? FileDragEntered;
    /// <summary>Files dropped anywhere on the panel that no element handled. Absolute paths. While nobody subscribes, the panel refuses file drops.</summary>
    event Action<string[]>? FilesDropped;

    /// <summary>Game mode module: enter or leave the game bar. While active: hover and hotkey opening are disabled, the window is click-through, the pill/panel are replaced by the game bar view.</summary>
    void SetGameBarActive(bool active);
    /// <summary>The view shown in GameBar mode. It sizes itself (natural width); the shell centers it and applies SetGameBarLayout.</summary>
    void SetGameBarView(UIElement? view);
    void SetClickThrough(bool on);
    /// <summary>Height in DIPs, opacity 0..1, offset in DIPs of the bar center from the monitor's top-center (positive = right / down). The bar is kept on screen, so large offsets reach the corners.</summary>
    void SetGameBarLayout(double height, double opacity, double offsetX, double offsetY);

    /// <summary>Raises Changed(hwnd) on every foreground window change (SetWinEventHook, no polling).</summary>
    ForegroundWatcher Foreground { get; }
    /// <summary>Notch window handle (for clipboard listeners, message hooks). Never the foreground window unless a text box has focus.</summary>
    nint Hwnd { get; }
    /// <summary>HMONITOR of the display hosting the notch (changes with the Monitor setting).</summary>
    nint Monitor { get; }
    /// <summary>Add a message hook on the notch window (WM_CLIPBOARDUPDATE, WM_DISPLAYCHANGE, ...). Set handled=true only if you consumed the message. Keep the delegate if you want to remove it.</summary>
    void AddHwndHook(HwndSourceHook hook);
    void RemoveHwndHook(HwndSourceHook hook);

    /// <summary>Live general settings (hover delays, accent, pinned, ...).</summary>
    GeneralSettings General { get; }
}
