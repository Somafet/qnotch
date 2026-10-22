using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using QNotch.Modules;

namespace QNotch.Shell;

/// <summary>A visible card edge anchor. Dragging snaps to supported widths; arrows and UI Automation offer the same sizes.</summary>
internal sealed class CardResizeHandle : Thumb
{
    readonly CardHost _host;
    readonly CardLayout _layout;
    readonly int _direction;
    CardSize _startSize;
    CardSize _reportedSize;
    UIElement? _dragRoot;
    Point _press, _pointerStart;

    public CardResizeHandle(CardHost host, CardLayout layout, int direction)
    {
        _host = host;
        _layout = layout;
        _direction = direction;
        Style = (Style)host.FindResource("CardResizeHandle");
        var side = direction < 0 ? "left" : "right";
        AutomationProperties.SetAutomationId(this, $"card-resize-{host.CardId}-{side}");
        AutomationProperties.SetName(this, $"Resize {host.Title}, {side} edge");
        _reportedSize = Size;
        SyncSize();
        DragStarted += (_, e) =>
        {
            _startSize = Size;
            _dragRoot = (UIElement?)Window.GetWindow(this) ?? host;
            _press = new Point(e.HorizontalOffset, e.VerticalOffset);
            _pointerStart = TranslatePoint(_press, _dragRoot);
            Focus();
        };
        DragDelta += (_, e) =>
        {
            if (_dragRoot is null) return;
            // Thumb deltas are relative to its original local press, not incremental movement.
            // Convert back to a stable window coordinate so snapping/reflow cannot compound them.
            var pointer = TranslatePoint(new Point(_press.X + e.HorizontalChange, _press.Y + e.VerticalChange), _dragRoot);
            var width = WidthOf(_startSize) + (pointer.X - _pointerStart.X) * _direction;
            SetSize(host.Descriptor.SupportedSizes.MinBy(s => Math.Abs(WidthOf(s) - width)));
        };
        DragCompleted += (_, e) => { if (e.Canceled) SetSize(_startSize); _dragRoot = null; };
    }

    CardSize Size => _layout.SizeOf(_host.CardId);
    internal int Columns => (int)Size;
    internal int MaximumColumns => (int)_host.Descriptor.SupportedSizes[^1];
    static double WidthOf(CardSize size) => (int)size * (HomeView.Unit + HomeView.Gap) - HomeView.Gap;
    void SetSize(CardSize size) { if (_host.IsEditMode) _layout.SetSize(_host.CardId, size); }

    internal void SyncSize()
    {
        ToolTip = $"{Size} · Drag to resize. Left/Right: change size. Home/End: smallest/largest.";
        if (_reportedSize != Size && UIElementAutomationPeer.FromElement(this) is { } peer)
            peer.RaisePropertyChangedEvent(RangeValuePatternIdentifiers.ValueProperty, (double)(int)_reportedSize, (double)(int)Size);
        _reportedSize = Size;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        var sizes = _host.Descriptor.SupportedSizes;
        var index = sizes.ToList().IndexOf(Size);
        switch (e.Key)
        {
            case Key.Left: SetSize(sizes[Math.Max(0, index - 1)]); break;
            case Key.Right: SetSize(sizes[Math.Min(sizes.Count - 1, index + 1)]); break;
            case Key.Home: SetSize(sizes[0]); break;
            case Key.End: SetSize(sizes[^1]); break;
            case Key.Escape when IsDragging: CancelDrag(); break;
            default: base.OnKeyDown(e); return;
        }
        e.Handled = true;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new ResizePeer(this);

    sealed class ResizePeer(CardResizeHandle owner) : FrameworkElementAutomationPeer(owner), IRangeValueProvider
    {
        protected override string GetClassNameCore() => nameof(CardResizeHandle);
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Slider;
        public override object? GetPattern(PatternInterface patternInterface) => patternInterface == PatternInterface.RangeValue ? this : base.GetPattern(patternInterface);
        public bool IsReadOnly => !owner.IsEnabled || !owner._host.IsEditMode;
        public double LargeChange => 1;
        public double SmallChange => 1;
        public double Maximum => (int)owner._host.Descriptor.SupportedSizes[^1];
        public double Minimum => (int)owner._host.Descriptor.SupportedSizes[0];
        public double Value => (int)owner.Size;
        public void SetValue(double value)
        {
            if (IsReadOnly) throw new ElementNotEnabledException();
            if (!owner._host.Descriptor.SupportedSizes.Any(s => (int)s == value)) throw new ArgumentOutOfRangeException(nameof(value));
            owner.SetSize((CardSize)(int)value);
        }
    }
}
