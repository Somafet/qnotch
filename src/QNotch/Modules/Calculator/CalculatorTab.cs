using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Calc.Windows;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Calculator;

/// <summary>
/// The tab's cheap host. The shell builds tabs at startup, so the editor, the engine and the saved sheets wait until it is first shown.
/// </summary>
internal sealed class CalculatorTab : Grid, IPanelKeyboardInput
{
    readonly CalculatorModule _module;
    CalculatorSurface? _surface;
    bool _loading, _failed, _focusWhenReady;

    public CalculatorTab(CalculatorModule module)
    {
        _module = module;
        Margin = PanelMetrics.Page with { Top = 2 };
        IsVisibleChanged += (_, _) => ShowIfOpen();
        module.PanelOpened += ShowIfOpen;
    }

    /// <summary>The shell lays out the remembered tab once while collapsed. That pass must not load the calculator.</summary>
    void ShowIfOpen()
    {
        if (IsVisible && (_module.Demo || _module.PanelOpen)) Show();
    }

    public void FocusInput()
    {
        if (_surface is null) _focusWhenReady = true;
        else _surface.FocusInput();
    }

    async void Show()
    {
        if (_surface is not null || _loading || _failed) return;
        _loading = true;
        try
        {
            // A snapshot renders this tab right away, so demo data must be there before this returns.
            var surface = _module.Demo ? _module.GetSurface().GetAwaiter().GetResult() : await _module.GetSurface();
            _surface = surface;
            Children.Add(surface);
            if (_focusWhenReady)
            {
                _focusWhenReady = false;
                // The editor can take focus only once its template exists.
                _ = Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => _surface?.FocusInput());
            }
        }
        catch (Exception ex)
        {
            _failed = true;
            Log.Error("Calculator failed to open", ex);
            Children.Add(Theme.Placeholder.Create(CalculatorModule.Icon, L.T("Calculator unavailable"), L.T("Your sheets were not changed. See the log for details.")));
        }
        finally { _loading = false; }
    }
}
