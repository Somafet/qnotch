using System.Windows;
using System.Windows.Interop;
using QNotch.Core;

namespace QNotch.Shell;

/// <summary>The shell as seen by modules. Modules never read shell internals or window state directly.</summary>
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
    void OpenSettings(string? sectionId = null);

    bool IsPinned { get; set; }
    /// <summary>Edit mode for the Home grid (toggled by the header pencil). Implemented by the EditMode module via CardHost + CardLayout.</summary>
    bool IsEditMode { get; set; }
    event Action? EditModeChanged;

    /// <summary>Call before focusing a text input (TextBox/PasswordBox do it automatically on mouse down). Activates the window until it loses focus or collapses.</summary>
    void RequestKeyboardFocus();

    /// <summary>Game mode module: enter or leave the game bar. While active: hover and hotkey opening are disabled, the window is click-through, the pill/panel are replaced by the game bar view.</summary>
    void SetGameBarActive(bool active);
    /// <summary>The view shown in GameBar mode. Size it with its own content; the shell measures it (natural width) and calls SetGameBarLayout height.</summary>
    void SetGameBarView(UIElement? view);
    void SetClickThrough(bool on);
    /// <summary>Height in DIPs, opacity 0..1, offset in DIPs from the top-center anchor (positive = right / down).</summary>
    void SetGameBarLayout(double height, double opacity, double offsetX, double offsetY);

    /// <summary>Raises Changed(hwnd) on every foreground window change (SetWinEventHook, no polling).</summary>
    ForegroundWatcher Foreground { get; }
    /// <summary>Notch window handle (for clipboard listeners, message hooks).</summary>
    nint Hwnd { get; }
    /// <summary>Add a message hook on the notch window (WM_CLIPBOARDUPDATE etc.). Set handled=true only if you consumed the message.</summary>
    void AddHwndHook(HwndSourceHook hook);

    /// <summary>Live general settings (hover delays, accent, pinned, ...).</summary>
    GeneralSettings General { get; }
}
