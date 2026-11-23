using Calc.Core;

namespace Calc.Providers;

public static class CurrencyRefreshPolicy
{
    public static DateTimeOffset? Next(bool enabled,bool visible,bool composing,bool needsLatest,bool busy,
        CurrencyRateSnapshot? snapshot,DateTimeOffset now,DateTimeOffset? retryNotBefore)
    {
        if (!enabled || !visible || composing || !needsLatest || busy) return null;
        var next = snapshot is null || snapshot.RetrievedAt > now ? now : snapshot.RetrievedAt.AddDays(1);
        if (retryNotBefore is { } retry && retry > next) next = retry;
        return next < now ? now : next;
    }
    public static DateTimeOffset Failed(DateTimeOffset now,TimeSpan? retryAfter = null)
    {
        var delay = retryAfter ?? TimeSpan.FromMinutes(15);
        if (delay < TimeSpan.FromMinutes(15)) delay = TimeSpan.FromMinutes(15);
        if (delay > TimeSpan.FromDays(1)) delay = TimeSpan.FromDays(1);
        return now + delay;
    }
}
