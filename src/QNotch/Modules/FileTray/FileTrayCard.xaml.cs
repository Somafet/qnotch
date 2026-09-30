using System.Windows.Controls;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Shell;

namespace QNotch.Modules.FileTray;

public partial class FileTrayCard : UserControl
{
    readonly IShell _shell;

    public FileTrayCard(IShell shell)
    {
        _shell = shell;
        InitializeComponent();
    }

    void OnClick(object sender, MouseButtonEventArgs e)
    {
        _shell.SelectTab("files");
    }
}
