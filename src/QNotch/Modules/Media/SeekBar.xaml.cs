using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace QNotch.Modules.Media;

/// <summary>Thin progress bar. When seekable it grows on hover, shows a knob, and click or drag raises <see cref="SeekRequested"/> (0..1) on release.</summary>
public partial class SeekBar : UserControl
{
    public static readonly DependencyProperty ProgressProperty = DependencyProperty.Register(nameof(Progress), typeof(double), typeof(SeekBar),
        new PropertyMetadata(0.0, (d, _) => ((SeekBar)d).Update()));
    public static readonly DependencyProperty IsSeekableProperty = DependencyProperty.Register(nameof(IsSeekable), typeof(bool), typeof(SeekBar),
        new PropertyMetadata(false, (d, _) => ((SeekBar)d).Restyle()));

    public double Progress { get => (double)GetValue(ProgressProperty); set => SetValue(ProgressProperty, value); }
    public bool IsSeekable { get => (bool)GetValue(IsSeekableProperty); set => SetValue(IsSeekableProperty, value); }
    public event Action<double>? SeekRequested;

    bool _dragging;
    double _dragFraction;

    public SeekBar()
    {
        InitializeComponent();
        SizeChanged += (_, _) => Update();
        MouseEnter += (_, _) => Restyle();
        MouseLeave += (_, _) => Restyle();
    }

    double Fraction(MouseEventArgs e) => ActualWidth <= 0 ? 0 : Math.Clamp(e.GetPosition(this).X / ActualWidth, 0, 1);

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if (!IsSeekable) return;
        _dragging = true;
        _dragFraction = Fraction(e);
        CaptureMouse();
        Update();
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (!_dragging) return;
        _dragFraction = Fraction(e);
        Update();
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        ReleaseMouseCapture();
        SeekRequested?.Invoke(Fraction(e));
        Restyle();
        e.Handled = true;
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        if (!_dragging) return;   // capture lost mid-drag (Alt-Tab, panel closing): drop the drag without seeking
        _dragging = false;
        Restyle();
    }

    void Update()
    {
        var x = ActualWidth * Math.Clamp(_dragging ? _dragFraction : Progress, 0, 1);
        Fill.Width = x;
        ThumbShift.X = x - Thumb.Width / 2;
    }

    void Restyle()
    {
        var active = IsSeekable && (IsMouseOver || _dragging);
        Track.Height = Fill.Height = active ? 6 : 4;
        Thumb.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        Cursor = IsSeekable ? Cursors.Hand : Cursors.Arrow;
        Update();
    }
}
