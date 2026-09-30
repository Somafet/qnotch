using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Core;

/// <summary>Owned by the GameMode module agent: add observable properties here. Do not touch other files in Core.</summary>
public sealed partial class GameModeState : ObservableObject
{
}

public sealed partial class AppState
{
    public GameModeState GameMode { get; } = new();
}
