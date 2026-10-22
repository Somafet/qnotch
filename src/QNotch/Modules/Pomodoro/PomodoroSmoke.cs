using QNotch.Core;

namespace QNotch.Modules.Pomodoro;

public sealed partial class PomodoroModule : ISmokeChecks
{
    public IEnumerable<SmokeCheck> SmokeChecks(SmokeContext ctx)
    {
        yield return new("timer-presentation", async () =>
        {
            var presentation = _ctx.Settings.Get<WindowsPresentationSettings>("windows-presentation");
            var visible = presentation.SegmentVisible("timer.pill");
            var fast = _fast;
            SetCadence(Cadence.Fast);
            var undo = Demo(running: true);
            try
            {
                var deadline = _end;
                var before = _st.Text;
                presentation.SetSegments(["timer.pill"], false);
                await Task.Delay(1100);
                if (!_st.IsRunning || !_st.IsActive || _end != deadline) return "hiding the timer indicator changed its running deadline";
                presentation.SetSegments(["timer.pill"], true);
                if (!_st.IsRunning || _end != deadline || _st.Text == before) return "showing the timer did not retain its advancing countdown";
                ctx.Log("Active timer kept its instance and exact wall-clock deadline while its indicator was hidden/shown; time continued advancing.");
                return null;
            }
            finally { presentation.SetSegments(["timer.pill"], visible); undo(); SetCadence(fast ? Cadence.Fast : Cadence.Slow); }
        });
    }
}
