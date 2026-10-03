using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using QNotch.Core;

namespace QNotch.Modules.Notes;

public partial class NoteCard : UserControl
{
    readonly NoteState _s;

    public NoteCard(NoteState state)
    {
        _s = state;
        DataContext = state;
        InitializeComponent();
        _s.PropertyChanged += OnChanged;
        Box.IsKeyboardFocusedChanged += (_, _) => Update();
        Update();
    }

    void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(NoteState.NoteText) or nameof(NoteState.NoteWordsText) or nameof(NoteState.NoteDateText)) Update();
    }

    void Update()
    {
        Hint.Visibility = _s.NoteText.Length == 0 && !Box.IsKeyboardFocused ?Visibility.Visible : Visibility.Collapsed;
        Meta.Text = $"{_s.NoteDateText} · {_s.NoteWordsText}";
    }
}
