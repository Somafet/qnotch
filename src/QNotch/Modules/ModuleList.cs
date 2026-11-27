using QNotch.Modules.Agents;
using QNotch.Modules.Ai;
using QNotch.Modules.Calculator;
using QNotch.Modules.Capture;
using QNotch.Modules.Clipboard;
using QNotch.Modules.ColorPicker;
using QNotch.Modules.FileTray;
using QNotch.Modules.Github;
using QNotch.Modules.Media;
using QNotch.Modules.Notes;
using QNotch.Modules.Notifications;
using QNotch.Modules.Pomodoro;
using QNotch.Modules.Scheduled;
using QNotch.Modules.Search;
using QNotch.Modules.Stats;
using QNotch.Modules.Taildrop;
using QNotch.Modules.Terminal;
using QNotch.Modules.Volume;
using QNotch.Modules.Weather;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules;

/// <summary>The ONE place that names modules. A module the user turned off (general.json, DisabledModules) is never created.</summary>
public static class ModuleList
{
    public static readonly IReadOnlyList<ModuleInfo> All =
    [
        new("stats", L.N("System stats"), L.N("CPU, memory, network, battery and clock in the pill, the System card and the game bar."), () => new StatsModule(), Early: true,
            Glyph: ""),
        new("media", L.N("Now playing"), L.N("Track, artwork and controls for anything that plays media."), () => new MediaModule(), Early: true, Glyph: Glyphs.Music),
        new("clipboard", L.N("Clipboard history"), L.N("Text and images you copy, kept in memory."), () => new ClipboardModule(), Glyph: Glyphs.Clipboard),
        new("ai", L.N("AI apps and usage"), L.N("Alt+1 to Alt+6 shortcuts and usage limits for Claude Code and Codex."), () => new AiModule(), Shared: new(typeof(AiSettings), "RefreshMinutes:5..60"),
            Glyph: Glyphs.Robot),
        new("agents", L.N("Agents"), L.N("Live Claude Code sessions: working, needs you or done, in the pill and the Agents tab."), () => new AgentsModule(), Early: true,
            Shared: new(typeof(AgentsConfig), "SoundNeedsYou", "SoundDone"), Glyph: AgentsModule.Icon, Setup: c => AgentsSetup.Create(c)),
        new("calculator", L.N("Calculator"), L.N("A notepad calculator with live answers, units, dates and currencies. Answers also appear in Search."), () => new CalculatorModule(),
            Glyph: CalculatorModule.Icon, Tip: _ => L.T("Type a calculation like 250 km in miles in Search, or open the Calculator tab.")),
        new("note", L.N("Note"), L.N("A quick note on a Home card, saved as you type."), () => new NoteModule(), Glyph: Glyphs.Note),
        new("github", L.N("GitHub"), L.N("Your GitHub contribution graph, with a token you add in Settings."), () => new GithubModule(), Glyph: Glyphs.Github, Setup: c => GithubSetup.Create(c)),
        new("filetray", L.N("File tray"), L.N("Drop files on the notch to keep them within reach."), () => new FileTrayModule(), Glyph: Glyphs.Folder,
            Tip: _ => L.T("Drag files onto the notch to keep them within reach.")),
        new("taildrop", L.N("Taildrop"), L.N("Send files to your devices on Tailscale: drag them onto the notch and drop them on a device. Needs Tailscale; off by default."), () => new TaildropModule(),
            Glyph: TaildropModule.Icon, Tip: _ => L.T("Drag files onto the notch and drop them on a Taildrop device to send them over Tailscale."), DefaultEnabled: false),
        new("notifications", L.N("Notifications"), L.N("Lets apps and scripts post notifications to the notch: QNotch.exe notify, a named pipe or local HTTP."), () => new NotificationsModule(), Early: true,
            Shared: new(typeof(NotificationSettings), "ToastSeconds:0..60", "RetentionDays:1..30", "OpenOnError", "Sound", "QuietDuringCalls"), Glyph: NotifyIcons.Bell),
        new("capture", L.N("Mic and camera"), L.N("A glyph in the pill and the game bar while an app uses your microphone or camera."), () => new CaptureModule(), Early: true, Glyph: ""),
        new("scheduled", L.N("Scheduled tasks"), L.N("Your Windows scheduled tasks (scripts and agents on a timer), with pause and delete."), () => new ScheduledModule(), Glyph: ScheduledModule.Icon),
        new("volume", L.N("Volume"), L.N("System volume and mute on a Home card."), () => new VolumeModule(), Glyph: Glyphs.Volume),
        new("timer", L.N("Timer"), L.N("Countdown with Pomodoro presets on a Home card, in the pill and in the game bar."), () => new PomodoroModule(), Early: true, Shared: new(typeof(TimerSettings), "Minutes:1..180"),
            Glyph: ""),
        new("colorpicker", L.N("Color picker"), L.N("Pick a color anywhere on screen and copy its hex code."), () => new ColorPickerModule(), Glyph: ""),
        new("weather", L.N("Weather"), L.N("The yr.no forecast for a place you pick, on a Home card, in the pill and in the game bar."), () => new WeatherModule(), Early: true,
            Shared: new(typeof(WeatherSettings), "Units", "ShowInPill"), Glyph: WeatherModule.Sun, Setup: c => WeatherSetup.Create(c)),
        new("search", L.N("Search"), L.N("One search box for clipboard history, files, notes, notifications, tasks, tabs and settings, with its own hotkey."), () => new SearchModule(),
            Glyph: "", Tip: ctx => ctx.Shortcuts.GestureOf("search", SearchModule.DefaultKey) is { Length: > 0 } g ? L.F("Press {0} to search clipboard, files, notes and settings.", g) : null),
        new("terminal", L.N("Terminal"), L.N("An interactive Windows shell in your home folder. Sessions stay open when the panel closes. Local opt-in; off by default."),
            () => new TerminalModule(), Glyph: "", DefaultEnabled: false),
    ];

    /// <summary>The welcome tour's Features step: groups in order, each with module ids in order. A module missing here joins the last group.</summary>
    public static readonly IReadOnlyList<(string Title, string[] Ids)> TourGroups =
    [
        (L.N("At a glance"), ["stats", "media", "weather", "capture", "timer", "volume"]),
        (L.N("Get things done"), ["clipboard", "search", "calculator", "note", "filetray", "colorpicker", "scheduled"]),
        (L.N("For developers"), ["agents", "ai", "github", "notifications", "taildrop", "terminal"]),
    ];

    /// <summary>Old module id to the ids it was split into. An old id in DisabledModules turns all of them off.</summary>
    public static readonly IReadOnlyDictionary<string, string[]> Renamed = new Dictionary<string, string[]>
    {
        ["notegithub"] = ["note", "github"],
    };

    /// <summary>Command line verbs (<c>QNotch.exe &lt;verb&gt; ...</c>). They run in Program.Main before WPF starts and return the exit code.</summary>
    public static readonly IReadOnlyDictionary<string, Func<string[], int>> Verbs = new Dictionary<string, Func<string[], int>>
    {
        ["notify"] = NotifyCli.Run,
        ["agent"] = AgentHook.Run,
        ["usage"] = UsageCli.Run,
        ["agents"] = AgentsCli.Run,
    };

    public static readonly IReadOnlyDictionary<string, (string Module, Action<Core.Consumers.ConsumerRequest> Validate)> ConsumerModules = new Dictionary<string, (string, Action<Core.Consumers.ConsumerRequest>)>
    {
        ["usage"] = ("ai", UsageCli.Validate), ["agents"] = ("agents", AgentsCli.Validate),
    };
}
