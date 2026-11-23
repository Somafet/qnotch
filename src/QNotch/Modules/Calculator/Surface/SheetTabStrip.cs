using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using QNotch.Calculator;
using QNotch.Modules;
using QNotch.Theme;

namespace Calc.Windows;

/// <summary>
/// One row of sheet tabs that never wraps and never pushes the buttons beside it away. Every tab has the same width: shared out between
/// the tabs, within a minimum and a maximum. Past the minimum the row scrolls: the wheel, chevrons on the sides that have more, and an
/// all-sheets button. Only the tabs in view exist, so 256 sheets cost what ten do.
/// </summary>
internal sealed class SheetTabStrip : Grid
{
    internal const double MinTabWidth = 92, MaxTabWidth = 150, ChevronWidth = 22, TabGap = 2, AllButtonWidth = 28, AddButtonWidth = 30;
    const double WheelStep = 0.5; // of a wheel notch's 120 units, in DIPs per unit

    readonly Canvas _row = new() { ClipToBounds = true, Background = Brushes.Transparent };
    readonly Button _left, _right, _all, _add;
    readonly List<SheetTabView> _views = [];
    IReadOnlyList<SheetTab> _tabs = [];
    Guid _active;
    double _offset, _view, _laidOutWidth, _tabWidth = MaxTabWidth;

    internal event Action<Guid>? Selected;
    internal event Action<Guid>? CloseRequested;
    internal event Action<Guid>? RenameRequested;
    internal event Action<Guid, UIElement>? MenuRequested;
    internal event Action? NewRequested;
    internal event Action? AllRequested;

    public SheetTabStrip()
    {
        // The row is as wide as its tabs, so the new-sheet button follows the last tab; a star column takes what is left.
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition());
        Background = Brushes.Transparent;
        Children.Add(_row);
        _left = Chevron("", "calculator-tabs-left", HorizontalAlignment.Left, -1);
        _right = Chevron("", "calculator-tabs-right", HorizontalAlignment.Right, 1);
        Children.Add(_left);
        Children.Add(_right);
        _all = Icon("", "calculator-tabs-all", () => AllRequested?.Invoke());
        _all.Visibility = Visibility.Collapsed;
        SetColumn(_all, 1);
        Children.Add(_all);
        _add = Icon(Glyphs.Add, "calculator-new", () => NewRequested?.Invoke());
        SetColumn(_add, 2);
        Children.Add(_add);
        SizeChanged += (_, _) => Layout();
        PreviewMouseWheel += OnWheel;
        Retitle();
    }

    /// <summary>Button names follow the interface language.</summary>
    internal void Retitle()
    {
        var text = UiText.Current;
        _left.ToolTip = text["scrollTabsLeft"];
        _right.ToolTip = text["scrollTabsRight"];
        _all.ToolTip = text["allSheets"];
        _add.ToolTip = text["newSheetTip"];
        foreach (var view in _views) view.Retitle();
    }

    static Button Icon(string glyph, string id, Action click)
    {
        var button = new Button
        {
            Style = (Style)Application.Current.FindResource("IconButton"),
            Content = glyph,
            Width = 26,
            Height = 26,
            Margin = new Thickness(2, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Focusable = false,
        };
        AutomationProperties.SetAutomationId(button, id);
        button.Click += (_, _) => click();
        return button;
    }

    Button Chevron(string glyph, string id, HorizontalAlignment side, int direction)
    {
        var button = Icon(glyph, id, () => Page(direction));
        button.Width = ChevronWidth;
        button.Margin = new Thickness(0);
        button.HorizontalAlignment = side;
        button.Visibility = Visibility.Collapsed;
        button.Template = ChevronTemplate();
        return button;
    }

    static ControlTemplate? _chevronTemplate;
    static ControlTemplate ChevronTemplate()
    {
        if (_chevronTemplate is not null) return _chevronTemplate;
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        border.SetResourceReference(Border.BackgroundProperty, "SurfaceRaisedBrush");
        var glyph = new FrameworkElementFactory(typeof(TextBlock));
        glyph.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(nameof(ContentControl.Content)) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        glyph.SetResourceReference(TextBlock.FontFamilyProperty, "IconFont");
        glyph.SetValue(TextBlock.FontSizeProperty, 10.0);
        glyph.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        glyph.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        glyph.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(glyph);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        template.Seal();
        return _chevronTemplate = template;
    }

    // ---------- content ----------

    /// <summary>Shows these tabs and keeps the active one fully in view.</summary>
    internal void Show(IReadOnlyList<SheetTab> tabs, Guid active)
    {
        var moved = active != _active;
        _tabs = tabs;
        _active = active;
        Layout();
        if (moved) RevealActive();
    }

    /// <summary>After closing a tab that is not active. The row stays where it is, so the next tab slides under the pointer for another
    /// middle-click; it only moves to keep an active tab in view that was in view.</summary>
    internal void ShowKeepingPlace(IReadOnlyList<SheetTab> tabs, Guid active)
    {
        var index = IndexOf(_active);
        var left = index * Step;
        var wasInView = index >= 0 && left >= _offset - 0.5 && left + _tabWidth <= _offset + _view + 0.5;
        _tabs = tabs;
        _active = active;
        Layout();
        if (wasInView) RevealActive();
    }

    internal void RevealActive() => Reveal(_active);

    /// <summary>Scrolls just enough to show a tab whole, clear of the chevrons.</summary>
    internal void Reveal(Guid id)
    {
        var index = IndexOf(id);
        if (index < 0) return;
        var view = _view;
        if (view <= 0) return;
        var content = ContentWidth;
        if (content <= view) { SetOffset(0); return; }
        var left = index * Step;
        var right = left + _tabWidth;
        var leftInset = left > 0 ? ChevronWidth : 0;
        var rightInset = right < content ? ChevronWidth : 0;
        var offset = _offset;
        if (left - leftInset < offset) offset = left - leftInset;
        else if (right + rightInset > offset + view) offset = right + rightInset - view;
        SetOffset(offset);
    }

    int IndexOf(Guid id)
    {
        for (var i = 0; i < _tabs.Count; i++) if (_tabs[i].Id == id) return i;
        return -1;
    }

    double Step => _tabWidth + TabGap;
    double ContentWidth => _tabs.Count == 0 ? 0 : _tabs.Count * Step - TabGap;

    void OnWheel(object sender, MouseWheelEventArgs e)
    {
        if (ContentWidth <= _view) return;
        SetOffset(_offset - e.Delta * WheelStep);
        e.Handled = true;
    }

    void Page(int direction) => SetOffset(_offset + direction * Math.Max(Step, _view - 2 * ChevronWidth - Step));

    void SetOffset(double offset)
    {
        var clamped = Math.Clamp(offset, 0, Math.Max(0, ContentWidth - _view));
        if (Math.Abs(clamped - _offset) < 0.01) { Place(); return; }
        _offset = clamped;
        Place();
    }

    // ---------- layout: only the tabs in view ----------

    void Layout()
    {
        var available = ActualWidth - AddButtonWidth;
        if (available <= 0) return;
        var count = Math.Max(1, _tabs.Count);
        var fitting = (available + TabGap) / count - TabGap;
        var overflow = fitting < MinTabWidth;
        _all.Visibility = overflow ? Visibility.Visible : Visibility.Collapsed;
        _tabWidth = overflow ? MinTabWidth : Math.Min(MaxTabWidth, Math.Floor(fitting));
        _view = overflow ? Math.Max(MinTabWidth, available - AllButtonWidth) : ContentWidth;
        _row.Width = _view;
        _offset = Math.Clamp(_offset, 0, Math.Max(0, ContentWidth - _view));
        Place();
        if (Math.Abs(ActualWidth - _laidOutWidth) < 0.5) return;
        _laidOutWidth = ActualWidth; // First layout or a resize: the active tab comes into view.
        Reveal(_active);
    }

    void Place()
    {
        var view = _view;
        var height = ActualHeight > 0 ? ActualHeight : 32;
        var used = 0;
        if (_tabs.Count > 0 && view > 0)
        {
            var first = Math.Max(0, (int)Math.Floor(_offset / Step));
            var last = Math.Min(_tabs.Count - 1, (int)Math.Floor((_offset + view) / Step));
            for (var i = first; i <= last; i++)
            {
                if (used == _views.Count)
                {
                    var created = new SheetTabView(this);
                    _views.Add(created);
                    _row.Children.Add(created);
                }
                var tab = _views[used++];
                tab.Bind(_tabs[i], i, _tabs[i].Id == _active);
                tab.Width = _tabWidth;
                tab.Height = Math.Min(height, 28);
                Canvas.SetLeft(tab, Math.Round(i * Step - _offset));
                Canvas.SetTop(tab, Math.Round((height - tab.Height) / 2));
                tab.Visibility = Visibility.Visible;
            }
        }
        for (var i = used; i < _views.Count; i++) _views[i].Unbind();
        var more = ContentWidth > view + 0.5;
        _left.Visibility = more && _offset > 0.5 ? Visibility.Visible : Visibility.Collapsed;
        _right.Visibility = more && _offset < ContentWidth - view - 0.5 ? Visibility.Visible : Visibility.Collapsed;
    }

    // ---------- what a tab reports ----------

    internal void Select(SheetTab tab) => Selected?.Invoke(tab.Id);
    internal void Close(SheetTab tab) => CloseRequested?.Invoke(tab.Id);
    internal void Rename(SheetTab tab) => RenameRequested?.Invoke(tab.Id);
    internal void Menu(SheetTab tab, UIElement target) => MenuRequested?.Invoke(tab.Id, target);
}

/// <summary>
/// One visible tab. The middle button closes it browser style: it acts on release over the same tab, never selects it first, and a drag
/// off the tab cancels. The close mark shows on the active and the hovered tab.
/// </summary>
internal sealed class SheetTabView : Button, IMiddleClickTarget
{
    static readonly ControlTemplate Shape = CreateTemplate();
    readonly SheetTabStrip _strip;
    readonly TextBlock _label = new() { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 22, 0) };
    readonly Button _close;
    readonly Border _mark = new() { Height = 2, CornerRadius = new CornerRadius(1), VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(8, 0, 8, 0), Visibility = Visibility.Collapsed };
    SheetTab? _tab;
    Guid? _middlePressed;
    bool _active;

    public SheetTabView(SheetTabStrip strip)
    {
        _strip = strip;
        Template = Shape;
        Focusable = false;
        Cursor = Cursors.Arrow;
        _mark.SetResourceReference(Border.BackgroundProperty, "AccentBrush");
        _close = new Button
        {
            Style = (Style)Application.Current.FindResource("IconButton"),
            Content = "",
            Width = 18,
            Height = 18,
            FontSize = 9,
            Focusable = false,
            Margin = new Thickness(0, 0, 3, 0),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Hidden,
        };
        _close.Click += (_, e) =>
        {
            e.Handled = true;
            if (_tab is { } tab) _strip.Close(tab);
        };
        var body = new Grid();
        body.Children.Add(_label);
        body.Children.Add(_mark);
        body.Children.Add(_close);
        Content = body;
        Click += (_, _) => { if (_tab is { } tab) _strip.Select(tab); };
        MouseDoubleClick += (_, e) => { if (e.ChangedButton == MouseButton.Left && _tab is { } tab) { _strip.Rename(tab); e.Handled = true; } };
        MouseEnter += (_, _) => Paint();
        MouseLeave += (_, _) => Paint();
        PreviewMouseRightButtonUp += (_, e) => { if (_tab is { } tab) { _strip.Menu(tab, this); e.Handled = true; } };
        PreviewMouseDown += (_, e) => { if (e.ChangedButton == MouseButton.Middle) { MiddleDown(); e.Handled = true; } };
        PreviewMouseUp += (_, e) =>
        {
            if (e.ChangedButton != MouseButton.Middle) return;
            e.Handled = true;
            MiddleUp(IsUnderPointer(e));
        };
        LostMouseCapture += (_, _) => _middlePressed = null;
        ToolTipService.SetInitialShowDelay(this, 500);
        Retitle();
    }

    internal void Retitle() => _close.ToolTip = UiText.Current["closeSheet"];

    internal void Bind(SheetTab tab, int index, bool active)
    {
        if (!ReferenceEquals(_tab, tab))
        {
            _middlePressed = null;
            _tab = tab;
            _label.Text = tab.Name;
            ToolTip = tab.Name;
            AutomationProperties.SetName(this, tab.Name);
        }
        AutomationProperties.SetAutomationId(this, $"calculator-tab-{index}");
        AutomationProperties.SetAutomationId(_close, $"calculator-tab-{index}-close");
        _active = active;
        Paint();
    }

    internal void Unbind()
    {
        _tab = null;
        _middlePressed = null;
        if (IsMouseCaptured) ReleaseMouseCapture();
        AutomationProperties.SetAutomationId(this, "");
        AutomationProperties.SetAutomationId(_close, "");
        Visibility = Visibility.Collapsed;
    }

    void Paint()
    {
        var hovered = IsMouseOver;
        _close.Visibility = _active || hovered ? Visibility.Visible : Visibility.Hidden;
        _mark.Visibility = _active ? Visibility.Visible : Visibility.Collapsed;
        _label.FontWeight = _active ? FontWeights.SemiBold : FontWeights.Normal;
        _label.SetResourceReference(TextBlock.ForegroundProperty, _active ? "TextPrimaryBrush" : "TextSecondaryBrush");
        if (_active) SetResourceReference(BackgroundProperty, "ControlBrush");
        else if (hovered) SetResourceReference(BackgroundProperty, "ControlHoverBrush");
        else Background = Brushes.Transparent;
    }

    /// <summary>The press only arms the close: the tab is not selected and the sheet in front keeps its caret.</summary>
    void MiddleDown()
    {
        if (_tab is null) return;
        _middlePressed = _tab.Id;
        CaptureMouse();
    }

    /// <summary>Asks the strip what is on top at the pointer, because a chevron can cover part of this tab.</summary>
    bool IsUnderPointer(MouseEventArgs e)
    {
        for (var at = _strip.InputHitTest(e.GetPosition(_strip)) as DependencyObject; at is Visual; at = VisualTreeHelper.GetParent(at))
            if (ReferenceEquals(at, this)) return true;
        return false;
    }

    void MiddleUp(bool inside)
    {
        var pressed = _middlePressed;
        _middlePressed = null;
        if (IsMouseCaptured) ReleaseMouseCapture();
        if (inside && pressed is { } id && _tab is { } tab && tab.Id == id) _strip.Close(tab);
    }

    /// <summary>The debug channel's middle click: the same press and release, with where the pointer ended up.</summary>
    void IMiddleClickTarget.MiddleClick(bool releasedInside)
    {
        MiddleDown();
        MiddleUp(releasedInside);
    }

    static ControlTemplate CreateTemplate()
    {
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(7));
        border.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding(nameof(Background)) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.AppendChild(new FrameworkElementFactory(typeof(ContentPresenter)));
        var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        template.Seal();
        return template;
    }
}
