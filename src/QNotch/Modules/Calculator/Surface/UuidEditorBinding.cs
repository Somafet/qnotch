using Calc.Documents;
using ICSharpCode.AvalonEdit.Document;

namespace Calc.Windows;

internal sealed class UuidEditorBinding
{
    private readonly SheetEditor editor;
    private TextDocument watched;
    private bool restoring;
    internal GeneratedUuidSession Session { get; }
    private sealed class UuidUndo(GeneratedUuidEdit edit) : IUndoableOperation
    {
        public void Undo() => edit.Undo();
        public void Redo() => edit.Redo();
    }
    internal UuidEditorBinding(SheetEditor editor, GeneratedUuidState? saved)
    {
        this.editor = editor; Session = new(editor.Text, saved); watched = editor.Document;
        watched.Changed += Changed; editor.DocumentChanged += Replaced;
    }
    /// <summary>Replaces the whole source as one undo step that also carries its exact UUID identities and the host's companion state.</summary>
    internal void Restore(string source, GeneratedUuidState? saved, IUndoableOperation companion)
    {
        var document = editor.Document;
        document.BeginUpdate();
        try
        {
            restoring = true;
            document.Replace(0, document.TextLength, source);
            restoring = false;
            document.UndoStack.Push(new UuidUndo(Session.Restore(source, saved)));
            document.UndoStack.Push(companion);
        }
        finally { restoring = false; document.EndUpdate(); }
    }
    private void Changed(object? sender, DocumentChangeEventArgs change)
    {
        if (restoring) return;
        if (!editor.Document.UndoStack.AcceptChanges) { Session.ReplaySource(editor.Text); return; }
        var edit = Session.Apply(editor.Text, change.Offset, change.RemovalLength, change.InsertionLength);
        editor.Document.UndoStack.PushOptional(new UuidUndo(edit));
    }
    private void Replaced(object? sender, EventArgs args)
    {
        watched.Changed -= Changed; watched = editor.Document;
        Session.Apply(editor.Text); watched.Changed += Changed;
    }
}
