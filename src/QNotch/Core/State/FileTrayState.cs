using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Core;

/// <summary>Owned by the FileTray module agent: add observable properties here. Do not touch other files in Core.</summary>
public sealed partial class FileTrayState : ObservableObject
{
}

public sealed partial class AppState
{
    public FileTrayState FileTray { get; } = new();
}
