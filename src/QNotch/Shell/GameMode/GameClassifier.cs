using QNotch.Interop;

namespace QNotch.Shell.GameMode;

public enum GameVerdict
{
    /// <summary>Not a game: leave the bar.</summary>
    NotGame,
    /// <summary>Fullscreen (or listed) app: show the bar.</summary>
    Game,
    /// <summary>Transient UI (Alt-Tab, Start, QNotch itself): keep whatever state we are in.</summary>
    Ignore,
}

/// <summary>Everything the classifier looks at (SameMonitor: the window is on the display hosting the notch), gathered by the module from Win32. Pure data so the rules can be checked without a desktop.</summary>
public readonly record struct WindowFacts(string ClassName, string Process, bool IsSelf, bool Visible, bool Iconic, bool HasCaption, RECT Window, RECT Monitor, int NotifyState, bool SameMonitor = true);

/// <summary>The fullscreen rules of SPEC section 3 as one pure function, plus a tiny self-test.</summary>
public static class GameClassifier
{
    static readonly HashSet<string> ShellClasses = new(StringComparer.OrdinalIgnoreCase)
        { "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd" };

    // Short-lived shell surfaces that briefly own the foreground (Alt-Tab, Start, search, tray flyouts): they must not flip the mode.
    static readonly HashSet<string> TransientClasses = new(StringComparer.OrdinalIgnoreCase)
        { "MultitaskingViewFrame", "XamlExplorerHostIslandWindow", "ForegroundStaging", "TaskSwitcherWnd", "Windows.UI.Core.CoreWindow",
          "Shell_InputSwitchTopLevelWindow", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland" };

    public static GameVerdict Classify(in WindowFacts w, IReadOnlyCollection<string> allow, IReadOnlyCollection<string> deny, out string reason)
    {
        reason = "";
        if (w.IsSelf || TransientClasses.Contains(w.ClassName)) return GameVerdict.Ignore;
        if (ShellClasses.Contains(w.ClassName) || !w.Visible || w.Iconic) return GameVerdict.NotGame;
        if (Matches(deny, w.Process)) return GameVerdict.NotGame;
        if (Matches(allow, w.Process)) { reason = $"Listed: {w.Process}"; return GameVerdict.Game; }
        // A normal maximized window also covers the monitor when the taskbar auto-hides, but it keeps its caption. Games and video players do not.
        // Only a window on the notch's own display counts: fullscreen video on monitor 2 must not silence the bar on monitor 1.
        if (!w.SameMonitor) return GameVerdict.NotGame;
        if (!w.HasCaption && Covers(w.Window, w.Monitor)) { reason = $"Fullscreen: {w.Process}"; return GameVerdict.Game; }
        // Exclusive fullscreen D3D may not report a rect at all: ask the shell (value read on foreground change only).
        if (!w.HasCaption && w.NotifyState is Native.QUNS_BUSY or Native.QUNS_RUNNING_D3D_FULL_SCREEN or Native.QUNS_PRESENTATION_MODE)
        { reason = $"Fullscreen: {w.Process}"; return GameVerdict.Game; }
        return GameVerdict.NotGame;
    }

    public static bool Covers(RECT w, RECT m) =>
        m.Width > 0 && m.Height > 0 && w.Left <= m.Left && w.Top <= m.Top && w.Right >= m.Right && w.Bottom >= m.Bottom;

    /// <summary>"Game.EXE", " game " and "game" are the same entry.</summary>
    public static string Normalize(string name)
    {
        var n = name.Trim().ToLowerInvariant();
        return n.EndsWith(".exe", StringComparison.Ordinal) ? n[..^4] : n;
    }

    static bool Matches(IReadOnlyCollection<string> list, string process)
    {
        if (list.Count == 0 || process.Length == 0) return false;
        var p = Normalize(process);
        foreach (var e in list) if (Normalize(e) == p) return true;
        return false;
    }

    // ---------- self-test (debug builds, or start with --selftest-gamemode; failures go to the log) ----------

    /// <summary>Returns the failed case names; empty means all pass.</summary>
    public static List<string> SelfTest()
    {
        var failed = new List<string>();
        RECT R(int l, int t, int r, int b) => new() { Left = l, Top = t, Right = r, Bottom = b };
        var mon = R(0, 0, 1920, 1080);
        WindowFacts F(string cls = "Game", string proc = "game.exe", bool self = false, bool vis = true, bool icon = false, bool cap = false,
            RECT? win = null, int notify = Native.QUNS_ACCEPTS_NOTIFICATIONS, bool same = true) => new(cls, proc, self, vis, icon, cap, win ?? mon, mon, notify, same);
        string[] none = [], game = ["Game"], other = ["other.exe"];

        void Check(string name, GameVerdict expect, WindowFacts f, IReadOnlyCollection<string>? allow = null, IReadOnlyCollection<string>? deny = null)
        { if (Classify(f, allow ?? none, deny ?? none, out _) != expect) failed.Add(name); }

        Check("borderless fullscreen", GameVerdict.Game, F());
        Check("maximized window with caption", GameVerdict.NotGame, F(cap: true, win: R(-8, -8, 1928, 1088)));
        Check("windowed", GameVerdict.NotGame, F(win: R(100, 100, 900, 700)));
        Check("desktop", GameVerdict.NotGame, F(cls: "Progman"));
        Check("taskbar", GameVerdict.NotGame, F(cls: "Shell_TrayWnd"));
        Check("self", GameVerdict.Ignore, F(self: true));
        Check("alt-tab", GameVerdict.Ignore, F(cls: "MultitaskingViewFrame"));
        Check("minimized", GameVerdict.NotGame, F(icon: true));
        Check("invisible", GameVerdict.NotGame, F(vis: false));
        Check("denied fullscreen", GameVerdict.NotGame, F(), deny: game);
        Check("allowed small window", GameVerdict.Game, F(win: R(10, 10, 400, 300)), allow: game);
        Check("deny beats allow", GameVerdict.NotGame, F(), allow: game, deny: game);
        Check("other list entry ignored", GameVerdict.Game, F(), allow: other, deny: other);
        Check("d3d exclusive, no rect", GameVerdict.Game, F(win: R(0, 0, 0, 0), notify: Native.QUNS_RUNNING_D3D_FULL_SCREEN));
        Check("presentation mode", GameVerdict.Game, F(win: R(50, 50, 800, 600), notify: Native.QUNS_PRESENTATION_MODE));
        Check("busy but captioned", GameVerdict.NotGame, F(cap: true, win: R(0, 0, 800, 600), notify: Native.QUNS_BUSY));
        Check("second monitor", GameVerdict.NotGame, F(win: R(1920, 0, 3840, 1080)));
        Check("fullscreen on other monitor", GameVerdict.NotGame, F(same: false));
        Check("captionless window while QUNS_BUSY elsewhere", GameVerdict.NotGame, F(win: R(100, 100, 500, 400), notify: Native.QUNS_BUSY, same: false));
        Check("allow list ignores monitor", GameVerdict.Game, F(win: R(10, 10, 400, 300), same: false), allow: game);
        if (Normalize("Game.EXE ") != Normalize("game")) failed.Add("normalize");
        return failed;
    }
}
