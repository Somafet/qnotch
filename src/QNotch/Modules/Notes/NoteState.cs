using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Modules.Notes;

public enum NoteStatus { Saved, Editing, Failed }

/// <summary>Note state. Only touch on the UI thread; NoteStore posts results through the bus.</summary>
public sealed partial class NoteState : ObservableObject
{
    [ObservableProperty] string _noteText = "";
    [ObservableProperty] string _noteWordsText = "0 words";
    [ObservableProperty] string _noteDateText = "";
    [ObservableProperty] NoteStatus _noteStatus = NoteStatus.Saved;
}
