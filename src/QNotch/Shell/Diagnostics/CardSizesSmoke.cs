using System.Text.Json;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using QNotch.Core;
using QNotch.Modules;

namespace QNotch.Shell.Diagnostics;

internal sealed partial class SmokeTest
{
    async Task<string?> CardSizesCheck()
    {
        var layout = _h.Layout;
        var sizes = new Dictionary<string, string>(_h.Settings.CardSizes);
        var visible = new Dictionary<string, bool>(_h.Settings.CardVisible);
        var order = _h.Settings.CardOrder.ToList();
        string? saved = null;
        void Saved(string id, string json) { if (id == "general") saved = json; }
        _h.Store.Saved += Saved;
        try
        {
            S.OpenPanel();
            S.SelectTab("home");
            S.IsEditMode = true;
            if (!S.IsEditMode) return "layout editing is unavailable";
            foreach (var card in layout.Ordered) layout.SetVisible(card.Id, true);
            W.RootElement.UpdateLayout();
            var bodies = layout.Hosts.ToDictionary(h => h.CardId, h => h.Content);
            foreach (var card in layout.Ordered.ToArray())
            {
                if (!card.SupportedSizes.Contains(CardSize.Small)) return $"{card.Id} has no Small size";
                var host = layout.Hosts.Single(h => h.CardId == card.Id);
                foreach (var side in new[] { "left", "right" })
                foreach (var size in card.SupportedSizes.Concat(card.SupportedSizes.Reverse()))
                {
                    if (card.SupportedSizes.Count > 1)
                    {
                        var id = $"card-resize-{card.Id}-{side}";
                        if (Find(host, id) is not CardResizeHandle handle) return $"missing {id}";
                        var peer = UIElementAutomationPeer.CreatePeerForElement(handle);
                        if (peer?.GetPattern(PatternInterface.RangeValue) is not IRangeValueProvider range) return $"{id} is not accessible";
                        var before = layout.SizeOf(card.Id);
                        var delta = ((int)size - (int)before) * (HomeView.Unit + HomeView.Gap) * (side == "left" ? -1 : 1);
                        handle.RaiseEvent(new DragStartedEventArgs(0, 0));
                        for (var step = 0; step < 10; step++) handle.RaiseEvent(new DragDeltaEventArgs(delta / 4, 0));
                        if (layout.SizeOf(card.Id) != before) return $"{id} snapped before crossing the midpoint";
                        handle.RaiseEvent(new DragDeltaEventArgs(delta, 0));
                        handle.RaiseEvent(new DragCompletedEventArgs(delta, 0, false));
                        if (layout.SizeOf(card.Id) != size) return $"{id} did not resize";
                        if (range.Value != (int)size) return $"{id} reports the wrong accessible size";
                        // A cancelled drag restores the original supported size, even after crossing a snap point.
                        handle.RaiseEvent(new DragStartedEventArgs(0, 0));
                        handle.RaiseEvent(new DragDeltaEventArgs(10000, 0));
                        handle.RaiseEvent(new DragCompletedEventArgs(10000, 0, true));
                        if (layout.SizeOf(card.Id) != size) return $"{id} did not cancel its drag";
                        Press(handle, System.Windows.Input.Key.Home);
                        if (layout.SizeOf(card.Id) != card.SupportedSizes[0]) return $"{id} did not resize with Home";
                        Press(handle, System.Windows.Input.Key.End);
                        if (layout.SizeOf(card.Id) != card.SupportedSizes[^1]) return $"{id} did not resize with End";
                        // Assistive technology can reach either supported size as well.
                        range.SetValue((int)size);
                    }
                    W.RootElement.UpdateLayout();
                    if (Math.Abs(host.ActualWidth - ((int)size * (HomeView.Unit + HomeView.Gap) - HomeView.Gap)) > 0.1
                        || Math.Abs(host.ActualHeight - HomeView.RowHeight) > 0.1) return $"{card.Id} has wrong {size} dimensions";
                    if (!ReferenceEquals(host.Content, bodies[card.Id])) return $"resizing {card.Id} recreated its body";
                    if (saved is null) return "no general settings were saved";
                    var reloaded = new CardLayout(_h.Cards, JsonSerializer.Deserialize<GeneralSettings>(saved, SettingsStore.Json)!);
                    if (reloaded.SizeOf(card.Id) != size) return $"{card.Id} size did not survive serialization";
                    Log($"{card.Id}: {size}, {host.ActualWidth} x {host.ActualHeight}, body reused, saved size restored");
                }
                var outline = Outline.Of(host);
                foreach (var side in new[] { "left", "right" })
                    if (outline.Contains($"#card-resize-{card.Id}-{side}", StringComparison.Ordinal)
                        != (card.SupportedSizes.Count > 1)) return $"{card.Id} offers incorrect resize handles";
            }
            foreach (var card in layout.Ordered) layout.SetSize(card.Id, CardSize.Small);
            W.RootElement.UpdateLayout();
            var frames = layout.Hosts.Select(h => (h.CardId, Rect: new Rect(h.TranslatePoint(new Point(), W.RootElement), h.RenderSize))).ToArray();
            for (var i = 0; i < frames.Length; i++)
                for (var j = i + 1; j < frames.Length; j++)
                    if (frames[i].Rect.IntersectsWith(frames[j].Rect)) return $"{frames[i].CardId} overlaps {frames[j].CardId}";
            S.IsEditMode = false;
            await Task.Delay(50);
            if (Outline.Of(W.RootElement).Contains("#card-resize-", StringComparison.Ordinal)) return "resize handles remain visible outside edit mode";
            return null;
        }
        finally
        {
            _h.Store.Saved -= Saved;
            S.IsEditMode = false;
            _h.Settings.CardSizes = sizes;
            foreach (var card in layout.Ordered)
            {
                layout.SetVisible(card.Id, visible.GetValueOrDefault(card.Id, card.DefaultVisible));
            }
            _h.Settings.CardVisible = visible;
            _h.Settings.CardOrder = order;
        }
    }
}
