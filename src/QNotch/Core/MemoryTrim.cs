using System.Runtime;
using System.Windows.Threading;
using QNotch.Interop;

namespace QNotch.Core;

/// <summary>
/// Overlay apps sit idle for hours. The working set is emptied only once after startup and after a long collapsed idle
/// (<see cref="IdleMs"/>); emptying it after every close would make each hover-open fault ~80 MB back in during the first frames.
/// After a close only the GC heap is compacted. One-shot timer, nothing recurring.
/// </summary>
public static class MemoryTrim
{
    const int IdleMs = 10 * 60 * 1000;
    static DispatcherTimer? _timer;
    static bool _trimWorkingSet;

    /// <summary>Startup: compact and empty the working set once after <paramref name="delayMs"/>.</summary>
    public static void Schedule(int delayMs) => Arm(delayMs, true);

    /// <summary>After a panel close or a big allocation: compact the heap soon, then empty the working set after a long idle.</summary>
    public static void AfterActivity(int delayMs = 3000) => Arm(delayMs, false);

    /// <summary>The panel opened: drop any pending working-set trim.</summary>
    public static void Cancel() => _timer?.Stop();

    static void Arm(int delayMs, bool trimWorkingSet)
    {
        if (_timer is null)
        {
            _timer = new DispatcherTimer(DispatcherPriority.ApplicationIdle);
            _timer.Tick += (_, _) =>
            {
                _timer.Stop();
                var ws = _trimWorkingSet;
                Compact();
                if (ws) Native.SetProcessWorkingSetSize(-1, -1, -1);
                else Arm(IdleMs, true);
            };
        }
        _timer.Stop();
        _trimWorkingSet = trimWorkingSet;
        _timer.Interval = TimeSpan.FromMilliseconds(delayMs);
        _timer.Start();
    }

    static void Compact()
    {
        GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(2, GCCollectionMode.Forced, true, true);
        GC.WaitForPendingFinalizers(); // WPF bitmaps free their native pixel copies in finalizers
        GC.Collect(2, GCCollectionMode.Aggressive, true, true); // also decommits the freed regions
    }
}
