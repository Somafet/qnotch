using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Input;

namespace QNotch.Modules.Terminal;

public sealed partial class TerminalModule : ISmokeChecks
{
    public IEnumerable<SmokeCheck> SmokeChecks(SmokeContext ctx)
    {
        yield return new("terminal-fixture", async () =>
        {
            if (!Demo) return "this check requires read-only fixtures";
            if (!_ctx.Shell.OpenPanelWithKeyboard(Id)) return "Terminal did not open";
            await Task.Delay(200);
            var input = _view!.Input;
            if (!input.IsKeyboardFocused) return "keyboard summon did not focus terminal input";
            if (!_ctx.Shortcuts.InputCaptured) return "terminal focus did not capture module shortcuts";
            var peer = UIElementAutomationPeer.CreatePeerForElement(input)!;
            if (AutomationProperties.GetName(input).Length == 0 || peer.GetPattern(PatternInterface.Value) is not IValueProvider value || !value.Value.Contains("Get-Date", StringComparison.Ordinal))
                return "Terminal output is not exposed to accessibility";
            var before = input.Text;
            input.InsertText("DO NOT EXECUTE FIXTURE\r");
            if (_session is not null || _starting is not null || input.Text != before) return "read-only fixture executed input or started a session";
            var key = new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(input)!, Environment.TickCount, Key.Escape) { RoutedEvent = Keyboard.PreviewKeyDownEvent };
            input.RaiseEvent(key);
            if (!key.Handled) return "Terminal Escape escaped to shell navigation";
            var toggle = _ctx.Shortcuts.Find("toggle")!;
            toggle.Action(); // close, then global panel summon must restore input, even when tab selection did not change
            if (_ctx.Shortcuts.InputCaptured) return "closed Terminal kept shortcuts captured";
            toggle.Action();
            await Task.Delay(250);
            if (!input.IsKeyboardFocused || !_ctx.Shortcuts.InputCaptured) return "global panel hotkey lost terminal focus on reopen";
            _ctx.Shell.SelectTab("home");
            if (_ctx.Shortcuts.InputCaptured) return "leaving Terminal did not restore shortcuts";
            if (_session is not null || _starting is not null) return "fixture created a real shell";
            ctx.Log("Deterministic VT fixture, accessibility value, retained input focus after global summon, Escape ownership and module-shortcut capture/restoration; zero shell creations.");
            return null;
        });
    }
}
