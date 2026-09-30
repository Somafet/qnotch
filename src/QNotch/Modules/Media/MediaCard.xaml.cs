using System.Windows.Controls;
using QNotch.Shell;

namespace QNotch.Modules.Media;

public partial class MediaCard : UserControl
{
    public MediaCard(MediaState m, IShell shell)
    {
        DataContext = m;
        InitializeComponent();
        MediaViews.WirePicker(Picker, m, shell);
        MediaViews.WireStates(m, Live, Empty, MediaViews.Nothing(true), MediaViews.Unavailable(true));
        Seek.SeekRequested += f => m.Seek(f);
    }
}
