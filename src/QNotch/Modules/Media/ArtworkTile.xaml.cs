using System.Windows;
using System.Windows.Controls;

namespace QNotch.Modules.Media;

public partial class ArtworkTile : UserControl
{
    public static readonly DependencyProperty RadiusProperty = DependencyProperty.Register(nameof(Radius), typeof(CornerRadius), typeof(ArtworkTile),
        new PropertyMetadata(new CornerRadius(8), (d, e) => ((ArtworkTile)d).Apply((CornerRadius)e.NewValue)));

    public CornerRadius Radius { get => (CornerRadius)GetValue(RadiusProperty); set => SetValue(RadiusProperty, value); }

    public ArtworkTile()
    {
        InitializeComponent();
        Apply(Radius);
    }

    void Apply(CornerRadius r) => Frame.CornerRadius = Art.CornerRadius = r;
}
