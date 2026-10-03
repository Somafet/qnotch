using QNotch.Modules.Ai;
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
using QNotch.Modules.Volume;

namespace QNotch.Modules;

/// <summary>The ONE place that names modules. A module the user turned off (general.json, DisabledModules) is never created.</summary>
public static class ModuleList
{
    public static readonly IReadOnlyList<ModuleInfo> All =
    [
        new("stats", "System stats", "CPU, memory, network, battery and clock in the pill, the System card and the game bar.", () => new StatsModule(), Early: true),
        new("media", "Now playing", "Track, artwork and controls for anything that plays media.", () => new MediaModule(), Early: true),
        new("clipboard", "Clipboard history", "Text and images you copy, kept in memory.", () => new ClipboardModule()),
        new("ai", "AI apps and usage", "Alt+1 to Alt+6 shortcuts and usage limits for Claude Code and Codex.", () => new AiModule()),
        new("note", "Note", "A quick note on a Home card, saved as you type.", () => new NoteModule()),
        new("github", "GitHub", "Your GitHub contribution graph, with a token you add in Settings.", () => new GithubModule()),
        new("filetray", "File tray", "Drop files on the notch to keep them within reach.", () => new FileTrayModule()),
        new("notifications", "Notifications", "Lets apps and scripts post notifications to the notch: QNotch.exe notify, a named pipe or local HTTP.", () => new NotificationsModule(), Early: true),
        new("scheduled", "Scheduled tasks", "Your Windows scheduled tasks (scripts and agents on a timer), with pause and delete.", () => new ScheduledModule()),
        new("volume", "Volume", "System volume and mute on a Home card.", () => new VolumeModule()),
        new("timer", "Timer", "Countdown with Pomodoro presets on a Home card, in the pill and in the game bar.", () => new PomodoroModule(), Early: true),
        new("colorpicker", "Color picker", "Pick a color anywhere on screen and copy its hex code.", () => new ColorPickerModule()),
        new("search", "Search", "One search box for clipboard history, files, notes, notifications, tasks, tabs and settings, with its own hotkey.", () => new SearchModule()),
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
    };
}
