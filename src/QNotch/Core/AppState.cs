using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Core;

public enum ShellMode { Collapsed, Expanded, GameBar }
public enum GameModeOverride { Auto, ForceOn, ForceOff }

/// <summary>
/// The single in-memory model. Sub-states live in Core/State/*State.cs; each module owns its own file there
/// (a small partial AppState adding one property). All mutation happens on the UI thread (post via EventBus).
/// </summary>
public sealed partial class AppState : ObservableObject
{
    public StatsState Stats { get; } = new();
    public MediaState Media { get; } = new();
}
