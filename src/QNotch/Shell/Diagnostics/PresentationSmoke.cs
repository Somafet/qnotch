using System.Windows;
using System.Windows.Controls;
using QNotch.Modules;

namespace QNotch.Shell.Diagnostics;

internal sealed partial class SmokeTest
{
    /// <summary>A tab shortcut opens its tab even when empty, closes on a second press, and is released while the tab is hidden.</summary>
    async Task<string?> HotkeyTab()
    {
        var keys = _h.Shortcuts.Items.Where(s => s.Id.StartsWith("tab.", StringComparison.Ordinal)).ToList();
        if (keys.Count == 0) return "no tab shortcuts are declared";
        if (keys.Any(k => k.Default.Length != 0)) return "a tab shortcut has a default key";
        var empty = _h.Tabs.Items.FirstOrDefault(t => t.Id != "home" && S.IsTabVisible(t.Id) && _h.Shortcuts.Find($"tab.{t.Id}") is not null && t.IsEmpty?.Invoke() == true);
        var tab = empty ?? _h.Tabs.Items.FirstOrDefault(t => t.Id != "home" && S.IsTabVisible(t.Id) && _h.Shortcuts.Find($"tab.{t.Id}") is not null);
        if (tab is null) return "skip: no tab other than Home is visible";
        var key = _h.Shortcuts.Find($"tab.{tab.Id}")!;
        var shown = new Dictionary<string, bool>(S.Presentation.Tabs);
        try
        {
            S.ClosePanel();
            key.Action();
            await Task.Delay(50);
            if (S.Mode != ShellMode.Expanded || S.ActiveTab != tab.Id) return $"{key.Id} did not open {tab.Id} (mode {S.Mode}, tab {S.ActiveTab})";
            key.Action();
            await Task.Delay(50);
            if (S.Mode != ShellMode.Collapsed) return $"second press of {key.Id} did not close the panel";
            S.Presentation.SetTab(tab.Id, false);
            if (key.Enabled) return $"hidden {tab.Id} kept its shortcut";
            S.Presentation.SetTab(tab.Id, true);
            if (!key.Enabled) return $"showing {tab.Id} did not restore its shortcut";
            Log($"{key.Id}: opened {(empty is null ? "a" : "an empty")} tab, closed on the second press, released while hidden.");
            return null;
        }
        finally { S.Presentation.Tabs = shown; }
    }

    async Task<string?> PresentationCheck()
    {
        var p = S.Presentation;
        var tabs = new Dictionary<string, bool>(p.Tabs);
        var segments = new Dictionary<string, bool>(p.Segments);
        var cards = new Dictionary<string, bool>(_h.Settings.CardVisible);
        var cardOrder = _h.Settings.CardOrder.ToList();
        var tabOrder = _h.Settings.TabOrder.ToList();
        var modules = _h.Modules.Select(x => x.Module).ToArray();
        var legacySegments = _h.Segments.Items.Where(s => s.Presented is not null && s.SetPresented is not null).ToDictionary(s => s, s => s.Presented!());
        try
        {
            S.OpenPanel();
            foreach (var t in _h.Tabs.Items.Where(t => t.Id != "home"))
            {
                p.SetTab(t.Id, true);
                S.SelectTab(t.Id);
                p.SetTab(t.Id, false);
                if (S.ActiveTab != "home" || _h.Settings.LastTab != "home") return $"hiding {t.Id} did not recover Home";
                S.SelectTab(t.Id);
                if (S.ActiveTab != "home" || S.OpenPanelWithKeyboard(t.Id)) return $"hidden {t.Id} accepted navigation";
                if (W.TabStrip.Children.OfType<RadioButton>().Single(b => (string)b.Tag == t.Id).Visibility != Visibility.Collapsed)
                    return $"hidden {t.Id} remains in the strip";
                var hits = _h.Search.Find("tabs")?.Find(t.Title).ToList() ?? [];
                if (hits.Any(h => h.Title == t.Title)) return $"hidden {t.Id} remains searchable";
            }
            if (_h.Shortcuts.Find("search")?.Enabled == true) return "hidden Search kept its shortcut";
            p.SetTab("search", true);
            if (_h.Shortcuts.Find("search")?.Enabled != true) return "showing Search did not restore its shortcut";
            foreach (var c in _h.Cards.Items) _h.Layout.SetVisible(c.Id, false);
            if (_h.Layout.Hosts.Count != 0) return "hiding cards left Home hosts";
            var home = W.TabHost.Children.OfType<Border>().First(b => b.Child is HomeView);
            W.RootElement.UpdateLayout();
            if (Outline.Of(home).Contains("Open Features", StringComparison.Ordinal) == false) return "empty Home has no recovery action";
            p.SetSegments(_h.Segments.Items.Where(s => s.Slot != SegmentSlot.GameBar).Select(s => s.Id), false);
            foreach (var (segment, _) in legacySegments) segment.SetPresented!(false);
            await Task.Delay(50);
            if (W.PillStrip.Children.OfType<FrameworkElement>().Any(e => e.Visibility == Visibility.Visible)
                || W.GlanceStrip.Children.OfType<FrameworkElement>().Any(e => e.Visibility == Visibility.Visible))
                return "hidden notch contributions remain visible";
            if (!modules.SequenceEqual(_h.Modules.Select(x => x.Module))) return "presentation recreated modules";
            if (!tabOrder.SequenceEqual(_h.Settings.TabOrder)) return "hiding changed tab ordering";
            Log("All module tabs: selected/last tab fallback, direct/keyboard/search blocking, Search shortcut release/restore; empty Home recovery; module identities retained.");
            return null;
        }
        finally
        {
            p.Tabs = tabs;
            p.Segments = segments;
            foreach (var (segment, visible) in legacySegments) segment.SetPresented!(visible);
            p.SetSegments([], true);
            foreach (var c in _h.Cards.Items) _h.Layout.SetVisible(c.Id, cards.GetValueOrDefault(c.Id, c.DefaultVisible));
            _h.Settings.CardVisible = cards;
            _h.Settings.CardOrder = cardOrder;
            _h.Settings.TabOrder = tabOrder;
        }
    }
}
