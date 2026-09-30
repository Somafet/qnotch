using System.Collections.Concurrent;
using System.Windows.Threading;

namespace QNotch.Core;

/// <summary>
/// Providers <see cref="Post{T}"/> typed events from ANY thread; handlers registered with <see cref="Subscribe{T}"/>
/// run on the UI thread. Posts are coalesced into a single dispatcher callback (no polling, no timers).
/// </summary>
public sealed class EventBus
{
    readonly Dispatcher _ui;
    readonly ConcurrentQueue<object> _queue = new();
    readonly Dictionary<Type, List<Action<object>>> _handlers = new();
    int _scheduled;

    public EventBus(Dispatcher ui) => _ui = ui;

    /// <summary>Thread-safe. Never blocks.</summary>
    public void Post<T>(T evt) where T : notnull
    {
        _queue.Enqueue(evt);
        if (Interlocked.Exchange(ref _scheduled, 1) == 0) _ui.BeginInvoke(DispatcherPriority.Normal, Drain);
    }

    /// <summary>Thread-safe. Runs <paramref name="action"/> on the UI thread via the same queue.</summary>
    public void Run(Action action) => Post(new UiAction(action));

    /// <summary>UI thread only. Handler is invoked on the UI thread for events of exactly type T.</summary>
    public IDisposable Subscribe<T>(Action<T> handler) where T : notnull
    {
        Action<object> wrapper = o => handler((T)o);
        if (!_handlers.TryGetValue(typeof(T), out var list)) _handlers[typeof(T)] = list = new();
        list.Add(wrapper);
        return new Sub(() => list.Remove(wrapper));
    }

    void Drain()
    {
        Volatile.Write(ref _scheduled, 0);
        while (_queue.TryDequeue(out var e))
        {
            try
            {
                if (e is UiAction a) { a.Action(); continue; }
                if (_handlers.TryGetValue(e.GetType(), out var list))
                    foreach (var h in list.ToArray()) h(e);
            }
            catch (Exception ex) { Log.Error($"EventBus handler for {e.GetType().Name} failed", ex); }
        }
    }

    sealed record UiAction(Action Action);
    sealed class Sub(Action dispose) : IDisposable { public void Dispose() => dispose(); }
}
