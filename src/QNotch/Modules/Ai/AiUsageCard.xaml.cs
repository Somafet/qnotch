using System.Windows.Controls;
using QNotch.Shell;

namespace QNotch.Modules.Ai;

public partial class AiUsageCard : UserControl
{
    readonly IShell _shell;
    IDisposable? _hold;

    public AiUsageCard(IShell shell)
    {
        _shell = shell;
        InitializeComponent();
    }

    // The dropdown is its own window: keep the panel open while the pointer is over it.
    void OnAccountsOpened(object sender, EventArgs e) => _hold ??= _shell.HoldOpen();
    void OnAccountsClosed(object sender, EventArgs e) { _hold?.Dispose(); _hold = null; }
}
