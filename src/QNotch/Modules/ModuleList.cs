using QNotch.Modules.Ai;
using QNotch.Modules.Clipboard;
using QNotch.Modules.EditMode;
using QNotch.Modules.FileTray;
using QNotch.Modules.GameMode;
using QNotch.Modules.Media;
using QNotch.Modules.NoteGithub;
using QNotch.Modules.Stats;

namespace QNotch.Modules;

/// <summary>The ONE place that lists modules. Pre-populated: feature agents never edit this file, they replace the contents of their own folder.</summary>
public static class ModuleList
{
    public static IEnumerable<INotchModule> Create() =>
    [
        new StatsModule(),
        new GameModeModule(),
        new MediaModule(),
        new ClipboardModule(),
        new AiModule(),
        new NoteGithubModule(),
        new FileTrayModule(),
        new EditModeModule(),
    ];
}
