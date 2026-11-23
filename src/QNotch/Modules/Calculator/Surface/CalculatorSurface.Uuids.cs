using Calc.Core;
using Calc.Documents;

namespace Calc.Windows;

public partial class CalculatorSurface
{
    private readonly Dictionary<SheetEditor, UuidEditorBinding> uuidSessions = [];
    private void RegisterUuidState(SheetEditor editor, GeneratedUuidState? saved) => uuidSessions.Add(editor, new(editor, saved));
    private StableUuidContext? ReadUuidContext(string source)
    {
        var session = uuidSessions[Editor].Session;
        if (session.Source != source) throw new InvalidOperationException("UUID document revision does not match editor source");
        if (!session.Enabled && UuidSyntax.RequiresState(source, functions) && session.Enable())
        { dirty = true; if (!compositionActive) { saveTimer.Stop(); saveTimer.Start(); } }
        if (!source.Contains("uuid", StringComparison.OrdinalIgnoreCase) && !source.Contains('(') && !session.HasDice) return null;
        return session.Context;
    }
}
