using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using QNotch.Core;

namespace QNotch.Modules.NoteGithub;

public partial class NoteCard : UserControl
{
    readonly NoteGithubState _s;

    public NoteCard(NoteGithubState state)
    {
        _s = state;
        DataContext = state;
        InitializeComponent();
        _s.PropertyChanged += OnChanged;
        Update();
    }

    void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(NoteGithubState.NoteText) or nameof(NoteGithubState.NoteWordsText) or nameof(NoteGithubState.NoteDateText)) Update();
    }

    void Update()
    {
        Hint.Visibility = _s.NoteText.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Meta.Text = $"{_s.NoteDateText} · {_s.NoteWordsText}";
    }
}
