using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Core;

/// <summary>Owned by the NoteGithub module agent: add observable properties here. Do not touch other files in Core.</summary>
public sealed partial class NoteGithubState : ObservableObject
{
}

public sealed partial class AppState
{
    public NoteGithubState NoteGithub { get; } = new();
}
