using System.Windows.Controls;
using QNotch.Shell;

namespace QNotch.Modules.Media;

public partial class MediaTab : UserControl
{
    public MediaTab(MediaState m, IShell shell)
    {
        DataContext = m;
        InitializeComponent();
        MediaViews.WirePicker(Picker, m, shell);
        MediaViews.WireStates(m, Live, Empty, MediaViews.Nothing(false), MediaViews.Unavailable(false));
        Seek.SeekRequested += f => MediaViews.Seek(m, f);
    }
}
