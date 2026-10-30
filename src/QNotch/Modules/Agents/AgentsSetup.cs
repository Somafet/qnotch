using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using QNotch.Theme;

namespace QNotch.Modules.Agents;

/// <summary>
/// The Agents row of the welcome tour's Connect step: Connect Claude Code and Connect Codex for each installed agent, with the same hook
/// file changes, backup and messages as Settings, Agents. Hooks need no running module: they call this exe. No row without an installed agent.
/// </summary>
internal static class AgentsSetup
{
    public static SetupRow? Create(SetupContext ctx)
    {
        // Installed: the config folder exists. A snapshot shows the default Claude Code folder and Codex either way.
        var hooks = (ctx.Demo ? ClaudeHooks.Discover().Take(1) : ClaudeHooks.Discover().Where(h => Directory.Exists(h.Dir)))
            .Append<HookFile?>(CodexHooks.Find(always: ctx.Demo)).OfType<HookFile>().ToList();
        if (hooks.Count == 0) return null;
        if (ctx.Demo) foreach (var h in hooks) h.Demo = h is CodexHooks ? HookStatus.NotInstalled : HookStatus.Connected; // never reads the files

        var status = new TextBlock();
        void Status(string text, string brush)
        {
            status.Text = text;
            status.SetResourceReference(TextBlock.ForegroundProperty, brush);
        }

        // Up to two agents fit on the right; more (several Claude Code accounts) wrap under the row.
        var buttons = new WrapPanel { Orientation = Orientation.Horizontal };
        FrameworkElement action = hooks.Count <= 2 ? buttons : new FrameworkElement();
        FrameworkElement? detail = hooks.Count <= 2 ? null : buttons;
        if (detail is not null) buttons.Margin = new Thickness(0, 6, 0, 0);
        var syncs = new List<Action>();
        SetupRow? row = null;
        string? lastHint = null;

        void Summary()
        {
            if (lastHint is not null) return;
            var states = hooks.Select(h => (h, h.Check())).ToList();
            var connected = states.Where(s => s.Item2.Status == HookStatus.Connected).Select(s => s.h.Title).ToList();
            if (states.FirstOrDefault(s => s.Item2.Status == HookStatus.Error) is { h: not null } bad)
                Status($"Could not read {bad.h.FileName}: {bad.Item2.Detail}", "DangerBrush");
            else if (connected.Count == hooks.Count) Status("Connected", "SuccessBrush");
            else if (connected.Count > 0) Status($"{string.Join(", ", connected)} connected", "SuccessBrush");
            else if (states.Any(s => s.Item2.Status == HookStatus.OtherCopy)) Status("Connected to another copy of QNotch", "WarningBrush");
            else Status("Not connected. Adds hooks to the agent's settings and keeps a backup.", "TextTertiaryBrush");
        }

        foreach (var h in hooks)
        {
            var hook = h;
            var button = new Button { Margin = new Thickness(8, 0, 0, 0) };
            if (detail is not null) button.Margin = new Thickness(0, 4, 8, 0);
            AutomationProperties.SetName(button, $"Connect {hook.Title}");
            buttons.Children.Add(button);

            void Sync()
            {
                var (s, _) = hook.Check();
                var on = s == HookStatus.Connected;
                if (on)
                {
                    var chip = new StackPanel { Orientation = Orientation.Horizontal };
                    var check = UiKit.Glyph(Glyphs.Accept, 12, "SuccessBrush");
                    check.Margin = new Thickness(0, 0, 6, 0);
                    check.VerticalAlignment = VerticalAlignment.Center;
                    chip.Children.Add(check);
                    chip.Children.Add(new TextBlock { Text = hook.Title, VerticalAlignment = VerticalAlignment.Center });
                    button.Content = chip;
                    button.ClearValue(FrameworkElement.StyleProperty);
                    button.IsEnabled = false;
                    button.ToolTip = $"{hook.Title} is connected. Disconnect it in Settings, Agents.";
                }
                else
                {
                    button.Content = $"Connect {hook.Title}";
                    button.Style = (Style)Application.Current.FindResource("AccentButton");
                    button.IsEnabled = true;
                }
            }
            syncs.Add(Sync);

            button.Click += async (_, _) =>
            {
                if (ctx.Demo) return;
                QNotch.Core.Analytics.Track("agents", "connect");
                button.IsEnabled = false;
                string? error = null;
                try { await Task.Run(hook.Connect); }
                catch (Exception ex) { error = ex.Message; Core.Log.Warn($"Changing {hook.Title} hooks failed", ex); }
                Sync();
                if (error is not null) { lastHint = ""; Status($"Could not change {hook.FileName}: {error}", "DangerBrush"); button.IsEnabled = true; return; }
                // Same message as Settings, Agents (Codex: trust the hooks once).
                lastHint = hook.ConnectedHint;
                Status(hook.ConnectedHint, "SuccessBrush");
                row?.Success();
            };
        }
        foreach (var s in syncs) s();
        Summary();
        return row = new SetupRow("Agents", AgentsModule.Icon, status, action, detail);
    }
}
