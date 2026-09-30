using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Core;

/// <summary>Owned by the Ai module agent: add observable properties here. Do not touch other files in Core.</summary>
public sealed partial class AiState : ObservableObject
{
}

public sealed partial class AppState
{
    public AiState Ai { get; } = new();
}
