using System.Runtime;
using System.Windows.Threading;
using QNotch.Interop;

namespace QNotch.Core;

/// <summary>
/// Overlay apps sit idle for hours: after startup and after each panel close, compact the GC heap and drop the working set once
/// (one-shot timer, nothing recurring). Pages fault back in on demand.
/// </summary>
public static class MemoryTrim
{
    static DispatcherTimer? _timer;

    public static void Schedule(int delayMs = 3000)
    {
        if (_timer is null)
        {
            _timer = new DispatcherTimer(DispatcherPriority.ApplicationIdle);
            _timer.Tick += (_, _) => { _timer.Stop(); TrimNow(); };
        }
        _timer.Stop();
        _timer.Interval = TimeSpan.FromMilliseconds(delayMs);
        _timer.Start();
    }

    public static void TrimNow()
    {
        GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(2, GCCollectionMode.Forced, true, true);
        Native.SetProcessWorkingSetSize(-1, -1, -1);
    }
}
