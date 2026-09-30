using System.Collections.ObjectModel;
using System.Windows.Input;
using CommunityToolkit.Mvvm.ComponentModel;
using QNotch.Modules.Ai;

namespace QNotch.Core;

/// <summary>Observable model for the AI module: detected apps, slot bindings and per-provider usage. UI thread only.</summary>
public sealed partial class AiState : ObservableObject
{
    /// <summary>Every detected and custom app.</summary>
    public ObservableCollection<AiAppItem> Apps { get; } = new();
    /// <summary>Apps bound to a slot 1..6, ordered by slot.</summary>
    public ObservableCollection<AiAppItem> Slotted { get; } = new();
    /// <summary>Enabled usage providers.</summary>
    public ObservableCollection<AiProviderItem> Providers { get; } = new();

    [ObservableProperty] private bool _hasApps;
    [ObservableProperty] private bool _noApps;
    [ObservableProperty] private bool _isScanning;
    [ObservableProperty] private string _appsEmptyText = "Looking for AI apps...";
    [ObservableProperty] private bool _hasProviders;
    [ObservableProperty] private bool _noProviders;
    [ObservableProperty] private bool _isRefreshing;
    [ObservableProperty] private string _lastUpdatedText = "";
    [ObservableProperty] private string _hotkeyWarning = "";

    public ICommand? RefreshCommand { get; set; }
    public ICommand? LaunchCommand { get; set; }
    public ICommand? RescanCommand { get; set; }
    public ICommand? OpenSettingsCommand { get; set; }
}

public sealed partial class AppState
{
    public AiState Ai { get; } = new();
}
