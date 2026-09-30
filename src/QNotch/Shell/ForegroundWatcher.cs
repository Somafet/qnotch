using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using QNotch.Interop;

namespace QNotch.Shell;

/// <summary>
/// EVENT_SYSTEM_FOREGROUND via SetWinEventHook (WINEVENT_OUTOFCONTEXT): zero cost until the foreground actually changes.
/// The callback is an unmanaged function pointer to a static method, so there is no delegate to keep rooted.
/// Changed fires on the UI thread (the hook is installed there).
/// </summary>
public sealed unsafe class ForegroundWatcher : IDisposable
{
    static ForegroundWatcher? _instance;
    nint _hook;

    public event Action<nint>? Changed;

    public void Start()
    {
        if (_hook != 0) return;
        _instance = this;
        _hook = Native.SetWinEventHook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND, 0, &Callback, 0, 0, Native.WINEVENT_OUTOFCONTEXT);
    }

    [UnmanagedCallersOnly]
    static void Callback(nint hook, uint evt, nint hwnd, int idObject, int idChild, uint thread, uint time)
    {
        try { _instance?.Changed?.Invoke(hwnd); } catch { /* never throw into native code */ }
    }

    public void Dispose()
    {
        if (_hook == 0) return;
        Native.UnhookWinEvent(_hook);
        _hook = 0;
    }
}
