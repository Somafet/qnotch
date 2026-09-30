using System.Text.Json.Serialization;
using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Core;

public enum ThemeChoice { System, Dark, Light }

/// <summary>Shell settings (general.json). Live object: bind to it, mutate it; the shell persists changes automatically.</summary>
public sealed partial class GeneralSettings : ObservableObject
{
    /// <summary>Index into <c>Monitors.List()</c> (primary is always 0).</summary>
    [ObservableProperty] int _monitorIndex;
    [ObservableProperty] int _hoverDwellMs = 120;
    [ObservableProperty] int _leaveDelayMs = 400;
    [ObservableProperty] bool _pinned;
    [ObservableProperty] string _toggleHotkey = "Ctrl+Alt+N";
    [ObservableProperty] string _gameModeHotkey = "Ctrl+Alt+G";
    [ObservableProperty] string _accentColor = "#5B9DFF";
    [ObservableProperty] ThemeChoice _theme = ThemeChoice.System;
    [ObservableProperty] bool _reduceMotion;
    [ObservableProperty] string _profileName = Environment.UserName;
    [ObservableProperty] string _profileImagePath = "";
    [ObservableProperty] bool _startWithWindows;
    [ObservableProperty] string _lastTab = "home";

    // Runtime only (never saved): the hotkey recorder in Settings suspends global hotkeys while it listens, and shows failed registrations.
    [ObservableProperty] [property: JsonIgnore] bool _recordingHotkey;
    [ObservableProperty] [property: JsonIgnore] bool _toggleHotkeyTaken;
    [ObservableProperty] [property: JsonIgnore] bool _gameModeHotkeyTaken;

    /// <summary>Ids of modules the user turned off (Settings, Features). They are never created; a change applies on restart.</summary>
    public List<string> DisabledModules { get; set; } = new();

    /// <summary>Card ids in display order, including hidden ones (hidden cards keep their slot).</summary>
    public List<string> CardOrder { get; set; } = new();

    /// <summary>Explicit visibility overrides by card id; missing means the descriptor default.</summary>
    public Dictionary<string, bool> CardVisible { get; set; } = new();
}
