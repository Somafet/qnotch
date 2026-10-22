using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using QNotch.Shell;

namespace QNotch.Modules.Media;

public partial class MediaCard : UserControl
{
    public MediaCard(MediaState m, IShell shell)
    {
        DataContext = m;
        InitializeComponent();
        MediaViews.WirePicker(Picker, m);
        MediaViews.WireStates(m, Live, Empty, MediaViews.Nothing(true), MediaViews.Unavailable(true));
        Seek.SeekRequested += f => m.Seek(f);
        SizeChanged += (_, _) =>
        {
            var small = ActualWidth < 300;
            Art.Visibility = small ? Visibility.Collapsed : Visibility.Visible;
            Grid.SetColumn(Track, small ? 0 : 1);
            Grid.SetColumnSpan(Track, small ? 3 : 1);
            Track.Margin = small ? new Thickness(0) : new Thickness(12, 0, 12, 0);
            Grid.SetRow(Controls, small ? 1 : 0);
            Grid.SetColumn(Controls, small ? 0 : 2);
            Grid.SetColumnSpan(Controls, small ? 3 : 1);
            Controls.HorizontalAlignment = small ? HorizontalAlignment.Center : HorizontalAlignment.Right;
            if (small) Timeline.Visibility = Visibility.Collapsed;
            else Timeline.SetBinding(VisibilityProperty, new Binding(nameof(MediaState.HasTimeline)) { Converter = (IValueConverter)FindResource("BoolToVis") });
            // The full source picker and seek bar remain available in the Media tab.
            PickerHost.Visibility = small ? Visibility.Collapsed : Visibility.Visible;
        };
    }
}
