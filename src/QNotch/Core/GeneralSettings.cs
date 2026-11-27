using System.Text.Json.Serialization;
using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Core;

public enum ThemeChoice { System, Dark, Light }

/// <summary>What opens the panel from the pill: resting the pointer on it (with <see cref="GeneralSettings.HoverDwellMs"/>) or a click.</summary>
public enum PanelOpenTrigger { Hover, Click }

/// <summary>Where a moved pill stays (spec/notch-position.md): one spot whatever app is in front, or a spot per app.</summary>
public enum NotchPositionMode { Everywhere, PerApp }

/// <summary>Shell settings (general.json). Live object: bind to it, mutate it; the shell persists changes automatically.</summary>
public sealed partial class GeneralSettings : ObservableObject
{
    /// <summary>Index into <c>Monitors.List()</c> (primary is always 0).</summary>
    [ObservableProperty] int _monitorIndex;
    [ObservableProperty] int _hoverDwellMs = 120;
    [ObservableProperty] int _leaveDelayMs = 400;
    /// <summary>Click: only a click on the pill opens the panel, with the keyboard; the pointer leaving never closes it.</summary>
    [ObservableProperty] PanelOpenTrigger _openOn = PanelOpenTrigger.Hover;
    [ObservableProperty] bool _pinned;
    // Only the defaults of the "toggle" and "gamemode" shortcuts now (a value saved here before hotkeys.json existed still counts).
    [ObservableProperty] string _toggleHotkey = "Ctrl+Alt+N";
    [ObservableProperty] string _gameModeHotkey = "Ctrl+Alt+G";
    [ObservableProperty] string _accentColor = "#5B9DFF";
    [ObservableProperty] ThemeChoice _theme = ThemeChoice.System;
    [ObservableProperty] bool _reduceMotion;
    [ObservableProperty] string _profileName = Environment.UserName;
    [ObservableProperty] string _profileImagePath = "";
    [ObservableProperty] bool _startWithWindows;
    // Local preferences only: setup codes never carry update choices or notification history.
    [ObservableProperty] bool _shareUsageData = true;
    [ObservableProperty] bool _checkForUpdates = true;
    [ObservableProperty] bool _updateChecksChoiceMade;
    [ObservableProperty] string _lastNotifiedUpdateVersion = "";
    /// <summary>The welcome tour finished, was skipped or closed (or the settings predate it). A local preference: never in setup codes.</summary>
    [ObservableProperty] bool _onboardingDone;
    /// <summary>When a fresh install first ran (UTC). Empty for installs from before it existed, which are never asked the quit question. A local value: never in setup codes.</summary>
    [ObservableProperty] DateTimeOffset? _firstRunAt;
    /// <summary>The first-week quit question was shown to this install, once. A local value: never in setup codes.</summary>
    [ObservableProperty] bool _quitQuestionAsked;
    [ObservableProperty] string _lastTab = "home";
    /// <summary>Interface language code (spec/localization.md); "" follows the Windows display language. Applies on restart. A local preference: never in setup codes.</summary>
    [ObservableProperty] string _language = "";

    /// <summary>Ids of modules the user turned off (Settings, Features). They are never created; a change applies on restart.</summary>
    public List<string> DisabledModules { get; set; } = new();
    /// <summary>Explicit local opt-ins for default-off modules. Never included in setup codes.</summary>
    [ObservableProperty] List<string> _localEnabledModules = new();

    /// <summary>Card ids in display order, including hidden ones (hidden cards keep their slot).</summary>
    public List<string> CardOrder { get; set; } = new();

    /// <summary>Tab ids in strip order (Edit mode). Tabs not listed follow in their default order; ids of tabs that are gone keep their slot.</summary>
    public List<string> TabOrder { get; set; } = new();

    /// <summary>Where the notch sits while an app is in front: process name ("chrome.exe") to DIPs from the monitor center
    /// (+-10000 means flush with that edge). Missing means centered. Saved by NotchNudge, not through PropertyChanged.</summary>
    public Dictionary<string, double> NotchSpots { get; set; } = new();

    /// <summary>Settings, General, Notch position. Null only until startup decides it (<see cref="NotchPlacement.Resolve"/>). A local preference: never in setup codes.</summary>
    [ObservableProperty] NotchPositionMode? _notchPosition;

    /// <summary>The one spot used with <see cref="NotchPositionMode.Everywhere"/>, stored like a <see cref="NotchSpots"/> value. Saved by NotchNudge.</summary>
    public double NotchX { get; set; }

    /// <summary>The one-time "Each app keeps its own pill spot" peek was shown, or the user changed Notch position. Saved by NotchNudge.</summary>
    public bool NotchSpotHintShown { get; set; }

    /// <summary>Explicit visibility overrides by card id; missing means the descriptor default.</summary>
    public Dictionary<string, bool> CardVisible { get; set; } = new();

    /// <summary>Home card size names by id. Unknown or unsupported sizes fall back to the descriptor default.</summary>
    public Dictionary<string, string> CardSizes { get; set; } = new();
}
