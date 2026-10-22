using System.Windows;

namespace QNotch.Shell.Diagnostics;

internal sealed partial class SmokeTest
{
    async Task<string?> PlacementDisplays()
    {
        var monitors = Monitors.List();
        try
        {
            for (var i = 0; i < monitors.Count; i++)
            {
                var monitor = monitors[i];
                W.SetMonitor(i);
                foreach (var offset in new[] { -10000d, 0, 10000d })
                {
                    S.ClosePanel();
                    W.SetNotchX(offset);
                    await Task.Delay(250);
                    var top = W.Surface.PointToScreen(new Point(0, 0));
                    var right = W.Surface.PointToScreen(new Point(W.Surface.ActualWidth, 0));
                    if (Math.Abs(top.Y - monitor.Bounds.Top) > 1) return $"display {i} offset {offset}: pill detached from full monitor top";
                    if (top.X < monitor.Bounds.Left - 1 || right.X > monitor.Bounds.Right + 1) return $"display {i}: nudged pill outside monitor";
                    S.OpenPanel();
                    await Task.Delay(300);
                    var panel = W.Surface.PointToScreen(new Point(0, 0));
                    var panelRight = W.Surface.PointToScreen(new Point(W.Surface.ActualWidth, 0));
                    if (Math.Abs(panel.Y - monitor.Bounds.Top) > 1 || panel.X < monitor.Bounds.Left - 1 || panelRight.X > monitor.Bounds.Right + 1)
                        return $"display {i}: nudged panel detached or outside monitor";
                }
                Log($"display {i}: bounds ({monitor.Bounds.Left},{monitor.Bounds.Top}) {monitor.Bounds.Width}x{monitor.Bounds.Height}, scale {monitor.Scale}; full-top attachment and +/-10000 DIP nudge clamping passed collapsed/expanded");
            }
            if (!monitors.Any(m => m.Bounds.Left < 0 || m.Bounds.Top < 0)) Log("No attached negative-origin display was available; that physical arrangement remains manual.");
            if (monitors.Select(m => m.Scale).Distinct().Count() < 2) Log("No mixed-DPI display pair was available; physical mixed-DPI/reconnect remains manual.");
            return null;
        }
        finally { S.ClosePanel(); W.SetMonitor(_h.Settings.MonitorIndex); W.SetNotchX(0); await Task.Delay(250); }
    }
}
