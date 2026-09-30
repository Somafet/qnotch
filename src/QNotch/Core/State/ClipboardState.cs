using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Core;

/// <summary>Owned by the Clipboard module agent: add observable properties here. Do not touch other files in Core.</summary>
public sealed partial class ClipboardState : ObservableObject
{
}

public sealed partial class AppState
{
    public ClipboardState Clipboard { get; } = new();
}
