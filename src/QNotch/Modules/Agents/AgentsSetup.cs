using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using QNotch.Core;
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
        // The module does not exist yet (the tour runs first): the seen state is the one saved in agents.json. The demo's Claude Code is receiving.
        var config = ctx.Settings.Get<AgentsConfig>(AgentsModule.TabId);
        bool Seen(HookFile h) => ctx.Demo ? h is ClaudeHooks : config.Seen.Contains(h.Kind);

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
            var connected = states.Where(s => s.Item2.Status == HookStatus.Connected).Select(s => s.h).ToList();
            var waiting = connected.Where(h => !Seen(h)).Select(h => h.Kind).Distinct().Order().ToList();
            if (states.FirstOrDefault(s => s.Item2.Status == HookStatus.Error) is { h: not null } bad)
                Status(L.F("Could not read {0}: {1}", bad.h.FileName, bad.Item2.Detail), "DangerBrush");
            else if (waiting.Count > 0) Status(AgentsStatus.Waiting(waiting), "WarningBrush");
            else if (connected.Count == hooks.Count) Status(AgentsStatus.Receiving, "SuccessBrush");
            else if (connected.Count > 0) Status(L.F("{0} connected. Receiving events.", string.Join(", ", connected.Select(h => h.Title))), "SuccessBrush");
            else if (states.Any(s => s.Item2.Status == HookStatus.OtherCopy)) Status(L.T("Connected to another copy of QNotch"), "WarningBrush");
            else Status(L.T("Not connected. Adds hooks to the agent's settings and keeps a backup."), "TextTertiaryBrush");
        }

        foreach (var h in hooks)
        {
            var hook = h;
            var button = new Button { Margin = new Thickness(8, 0, 0, 0) };
            if (detail is not null) button.Margin = new Thickness(0, 4, 8, 0);
            AutomationProperties.SetName(button, L.F("Connect {0}", hook.Title));
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
                    button.ToolTip = L.F("{0} is connected. Disconnect it in Settings, Agents.", hook.Title);
                }
                else
                {
                    button.Content = L.F("Connect {0}", hook.Title);
                    button.Style = (Style)Application.Current.FindResource("AccentButton");
                    button.IsEnabled = true;
                }
            }
            syncs.Add(Sync);

            button.Click += async (_, _) =>
            {
                if (ctx.Demo) return;
                QNotch.Core.Analytics.Track("agents", "connect", "onboarding", AgentsStatus.Target(hook.Kind));
                button.IsEnabled = false;
                string? error = null;
                try { await Task.Run(hook.Connect); }
                catch (Exception ex) { error = ex.Message; Core.Log.Warn($"Changing {hook.Title} hooks failed", ex); }
                Sync();
                if (error is not null) { lastHint = ""; Status(L.F("Could not change {0}: {1}", hook.FileName, error), "DangerBrush"); button.IsEnabled = true; return; }
                // Same message as Settings, Agents: the hooks are added, and no event has arrived yet.
                if (config.MarkSeen(hook.Kind, false)) ctx.Settings.Save(AgentsModule.TabId, config);
                lastHint = AgentsStatus.Waiting([hook.Kind]);
                Status(lastHint, "WarningBrush");
                row?.Success();
            };
        }
        foreach (var s in syncs) s();
        Summary();
        return row = new SetupRow(L.T("Agents"), AgentsModule.Icon, status, action, detail);
    }
}
