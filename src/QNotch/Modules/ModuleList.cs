using QNotch.Modules.Ai;
using QNotch.Modules.Clipboard;
using QNotch.Modules.FileTray;
using QNotch.Modules.Media;
using QNotch.Modules.NoteGithub;
using QNotch.Modules.Stats;

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
        new("notegithub", "Note and GitHub", "A quick note and your GitHub contribution graph.", () => new NoteGithubModule()),
        new("filetray", "File tray", "Drop files on the notch to keep them within reach.", () => new FileTrayModule()),
    ];
}
