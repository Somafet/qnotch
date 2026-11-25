using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Calc.Core;

namespace Calc.Windows;

public partial class CalculatorSurface
{
    private bool usesCurrentDate;
    private bool usesCurrentInstant;
    private bool usesLocalTimeZone;
    private bool requiresSecondRefresh;
    private DateOnly? evaluatedDate;
    private DateTimeOffset? evaluatedInstant;
    private TimeZoneInfo? localZoneSource;
    private LocalZoneSnapshot? localZoneSnapshot;
    private string? evaluatedLocalZoneVersion;
    private DispatcherTimer? dateTimer;
    private HwndSource? dateMessageSource;
    private bool dateClockQueued;
    private bool DateVisible => IsVisible;
    private (DateOnly Date, DateTimeOffset Instant, LocalZoneSnapshot LocalZone) ReadTemporalSnapshot()
    {
        // Settings may have changed while no date hook was attached (hidden/static/composing).
        TimeZoneInfo.ClearCachedData();
        var now = TimeProvider.System.GetUtcNow().ToUniversalTime();
        var snapshot = new DateTimeOffset(now.Ticks - now.Ticks % TimeSpan.TicksPerSecond, TimeSpan.Zero);
        var zone = TimeZoneInfo.Local;
        if (localZoneSource is null || localZoneSource.Id != zone.Id || !localZoneSource.HasSameRules(zone))
        { localZoneSource = zone; localZoneSnapshot = LocalZoneSnapshot.FromTimeZoneInfo(zone); }
        var local = localZoneSnapshot!;
        var date = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(snapshot, zone).DateTime);
        return (date, snapshot, local);
    }
    private void StopDateSchedule()
    {
        dateTimer?.Stop();
        dateMessageSource?.RemoveHook(DateMessage);
        dateMessageSource = null;
    }
    private void RefreshDateSchedule()
    {
        StopDateSchedule();
        if (!ready || !(usesCurrentDate || usesCurrentInstant || usesLocalTimeZone) || !DateVisible || compositionActive) return;
        if (requiresSecondRefresh || usesCurrentDate)
        {
            if (dateTimer is null)
            {
                dateTimer = new DispatcherTimer(DispatcherPriority.Background);
                dateTimer.Tick += (_, _) => { dateTimer.Stop(); DateClockChanged(); };
            }
            var now = TimeProvider.System.GetUtcNow();
            dateTimer.Interval = requiresSecondRefresh ? TimeSpan.FromTicks(TimeSpan.TicksPerSecond - now.Ticks % TimeSpan.TicksPerSecond) : DateRefreshSchedule.Delay(now, TimeZoneInfo.Local);
            dateTimer.Start();
        }
        dateMessageSource = PresentationSource.FromVisual(this) as HwndSource;
        dateMessageSource?.AddHook(DateMessage);
    }
    private nint DateMessage(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        // OS clock/settings/resume events; optional currency work checks its due deadline without polling.
        if (message is 0x001E or 0x001A || message == 0x0218 && wParam is 6 or 7 or 18)
        {
            if (!dateClockQueued)
            {
                dateClockQueued = true;
                Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
                {
                    dateClockQueued = false; TimeZoneInfo.ClearCachedData(); DateClockChanged();
                });
            }
        }
        return 0;
    }
    private void DateClockChanged()
    {
        RefreshCurrencySchedule(); UpdateCurrencyStatus();
        StopDateSchedule();
        if (!ready || !(usesCurrentDate || usesCurrentInstant || usesLocalTimeZone) || !DateVisible) return;
        if (compositionActive) { evaluationDeferred = true; return; }
        var snapshot = ReadTemporalSnapshot();
        if (usesCurrentDate && evaluatedDate != snapshot.Date || usesCurrentInstant && evaluatedInstant != snapshot.Instant ||
            usesLocalTimeZone && evaluatedLocalZoneVersion != snapshot.LocalZone.Version) pending = Evaluate();
        else RefreshDateSchedule();
    }
    private void DateVisibilityChanged()
    {
        // The panel hides all the time: a download the user asked for keeps going, only the automatic one stops.
        if (!DateVisible) StopCurrencySchedule(cancelAutomatic: true); else RefreshCurrencySchedule();
        if (!DateVisible) StopDateSchedule();
        else if (ratesChangedWhileHidden && ready && !compositionActive) { ratesChangedWhileHidden = false; pending = Evaluate(); }
        else DateClockChanged();
    }
}
