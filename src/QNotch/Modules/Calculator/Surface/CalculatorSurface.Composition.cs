using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;

namespace Calc.Windows;

public partial class CalculatorSurface
{
    private bool compositionActive;
    private bool evaluationDeferred;
    private void RegisterComposition(SheetEditor editor)
    {
        editor.AddHandler(TextCompositionManager.PreviewTextInputStartEvent,
            new TextCompositionEventHandler((_, _) => CompositionStarted(editor)), true);
        editor.AddHandler(TextCompositionManager.PreviewTextInputUpdateEvent,
            new TextCompositionEventHandler((_, _) => CompositionStarted(editor)), true);
        editor.AddHandler(TextCompositionManager.PreviewTextInputEvent,
            new TextCompositionEventHandler((_, _) => CompositionCompleted(editor)), true);
    }
    private void CompositionStarted(SheetEditor editor)
    {
        if (!ready || !ReferenceEquals(Editor, editor)) return;
        compositionActive = true; evaluationDeferred = true;
        StopDateSchedule();
        StopCurrencySchedule(true);
        saveTimer.Stop(); evaluation?.Cancel(); revision++;
        CarryResults();
    }
    private void CompositionCompleted(SheetEditor editor)
    {
        if (!ReferenceEquals(Editor, editor)) return;
        compositionActive = false;
        // Completion precedes the control's final TextChanged in some input paths.
        // Defer until native input processing has finished; never rewrite the document.
        Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
        {
            if (!ready || !ReferenceEquals(Editor, editor) || compositionActive || !evaluationDeferred) return;
            evaluationDeferred = false;
            if (dirty) { saveTimer.Stop(); saveTimer.Start(); }
            pending = Evaluate();
        });
    }
}
