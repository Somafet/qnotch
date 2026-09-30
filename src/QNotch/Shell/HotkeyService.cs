using System.Windows.Input;
using System.Windows.Interop;
using QNotch.Core;
using QNotch.Interop;

namespace QNotch.Shell;

/// <summary>RegisterHotKey on the notch window. Callbacks run on the UI thread.</summary>
public sealed class HotkeyService
{
    const uint MOD_NOREPEAT = 0x4000;
    readonly nint _hwnd;
    readonly Dictionary<int, Action> _actions = new();
    readonly Dictionary<(ModifierKeys, Key), int> _ids = new();
    int _next = 1;

    public HotkeyService(HwndSource source)
    {
        _hwnd = source.Handle;
        source.AddHook(Hook);
    }

    /// <summary>Returns false if the combination is taken by another app (logged).</summary>
    public bool Register(ModifierKeys mods, Key key, Action action)
    {
        Unregister(mods, key);
        var id = _next++;
        if (!Native.RegisterHotKey(_hwnd, id, (uint)mods | MOD_NOREPEAT, (uint)KeyInterop.VirtualKeyFromKey(key)))
        {
            Log.Warn($"Hotkey {mods}+{key} unavailable");
            return false;
        }
        _actions[id] = action;
        _ids[(mods, key)] = id;
        return true;
    }

    /// <summary>Gesture like "Ctrl+Alt+N".</summary>
    public bool Register(string gesture, Action action) =>
        TryParse(gesture, out var m, out var k) && Register(m, k, action);

    public void Unregister(ModifierKeys mods, Key key)
    {
        if (!_ids.Remove((mods, key), out var id)) return;
        Native.UnregisterHotKey(_hwnd, id);
        _actions.Remove(id);
    }

    public void Unregister(string gesture)
    {
        if (TryParse(gesture, out var m, out var k)) Unregister(m, k);
    }

    public void UnregisterAll()
    {
        foreach (var id in _ids.Values) Native.UnregisterHotKey(_hwnd, id);
        _ids.Clear();
        _actions.Clear();
    }

    public static bool TryParse(string gesture, out ModifierKeys mods, out Key key)
    {
        mods = ModifierKeys.None; key = Key.None;
        try
        {
            if (new KeyGestureConverter().ConvertFromInvariantString(gesture) is not KeyGesture g) return false;
            mods = g.Modifiers; key = g.Key;
            return true;
        }
        catch { return false; }
    }

    nint Hook(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        if (msg == Native.WM_HOTKEY && _actions.TryGetValue((int)wParam, out var a))
        {
            handled = true;
            try { a(); } catch (Exception ex) { Log.Error("Hotkey action failed", ex); }
        }
        return 0;
    }
}
