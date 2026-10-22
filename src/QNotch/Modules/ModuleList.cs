using QNotch.Modules.Agents;
using QNotch.Modules.Ai;
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
using QNotch.Modules.Terminal;
using QNotch.Modules.Volume;
using QNotch.Modules.Weather;
using QNotch.Theme;

namespace QNotch.Modules;

/// <summary>The ONE place that names modules. A module the user turned off (general.json, DisabledModules) is never created.</summary>
public static class ModuleList
{
    public static readonly IReadOnlyList<ModuleInfo> All =
    [
        new("stats", "System stats", "CPU, memory, network, battery and clock in the pill, the System card and the game bar.", () => new StatsModule(), Early: true,
            Glyph: ""),
        new("media", "Now playing", "Track, artwork and controls for anything that plays media.", () => new MediaModule(), Early: true, Glyph: Glyphs.Music),
        new("clipboard", "Clipboard history", "Text and images you copy, kept in memory.", () => new ClipboardModule(), Glyph: Glyphs.Clipboard),
        new("ai", "AI apps and usage", "Alt+1 to Alt+6 shortcuts and usage limits for Claude Code and Codex.", () => new AiModule(), Shared: new(typeof(AiSettings), "RefreshMinutes:5..60"),
            Glyph: Glyphs.Robot),
        new("agents", "Agents", "Live Claude Code sessions: working, needs you or done, in the pill and the Agents tab.", () => new AgentsModule(), Early: true,
            Shared: new(typeof(AgentsConfig), "SoundNeedsYou", "SoundDone"), Glyph: AgentsModule.Icon, Setup: c => AgentsSetup.Create(c)),
        new("note", "Note", "A quick note on a Home card, saved as you type.", () => new NoteModule(), Glyph: Glyphs.Note),
        new("github", "GitHub", "Your GitHub contribution graph, with a token you add in Settings.", () => new GithubModule(), Glyph: Glyphs.Github, Setup: c => GithubSetup.Create(c)),
        new("filetray", "File tray", "Drop files on the notch to keep them within reach.", () => new FileTrayModule(), Glyph: Glyphs.Folder,
            Tip: _ => "Drag files onto the notch to keep them within reach."),
        new("notifications", "Notifications", "Lets apps and scripts post notifications to the notch: QNotch.exe notify, a named pipe or local HTTP.", () => new NotificationsModule(), Early: true,
            Shared: new(typeof(NotificationSettings), "ToastSeconds:0..60", "RetentionDays:1..30", "OpenOnError", "Sound", "QuietDuringCalls"), Glyph: NotifyIcons.Bell),
        new("capture", "Mic and camera", "A glyph in the pill and the game bar while an app uses your microphone or camera.", () => new CaptureModule(), Early: true, Glyph: ""),
        new("scheduled", "Scheduled tasks", "Your Windows scheduled tasks (scripts and agents on a timer), with pause and delete.", () => new ScheduledModule(), Glyph: ScheduledModule.Icon),
        new("volume", "Volume", "System volume and mute on a Home card.", () => new VolumeModule(), Glyph: Glyphs.Volume),
        new("timer", "Timer", "Countdown with Pomodoro presets on a Home card, in the pill and in the game bar.", () => new PomodoroModule(), Early: true, Shared: new(typeof(TimerSettings), "Minutes:1..180"),
            Glyph: ""),
        new("colorpicker", "Color picker", "Pick a color anywhere on screen and copy its hex code.", () => new ColorPickerModule(), Glyph: ""),
        new("weather", "Weather", "The yr.no forecast for a place you pick, on a Home card, in the pill and in the game bar.", () => new WeatherModule(), Early: true,
            Shared: new(typeof(WeatherSettings), "Units", "ShowInPill"), Glyph: WeatherModule.Sun, Setup: c => WeatherSetup.Create(c)),
        new("search", "Search", "One search box for clipboard history, files, notes, notifications, tasks, tabs and settings, with its own hotkey.", () => new SearchModule(),
            Glyph: "", Tip: ctx => ctx.Shortcuts.GestureOf("search", SearchModule.DefaultKey) is { Length: > 0 } g ? $"Press {g} to search clipboard, files, notes and settings." : null),
        new("terminal", "Terminal", "An interactive Windows shell in your home folder. Sessions stay open when the panel closes. Local opt-in; off by default.",
            () => new TerminalModule(), Glyph: "", DefaultEnabled: false),
    ];

    /// <summary>The welcome tour's Features step: groups in order, each with module ids in order. A module missing here joins the last group.</summary>
    public static readonly IReadOnlyList<(string Title, string[] Ids)> TourGroups =
    [
        ("At a glance", ["stats", "media", "weather", "capture", "timer", "volume"]),
        ("Get things done", ["clipboard", "search", "note", "filetray", "colorpicker", "scheduled"]),
        ("For developers", ["agents", "ai", "github", "notifications", "terminal"]),
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
    };
}
