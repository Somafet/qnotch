using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using Calc.Documents;
using QNotch.Calculator;

namespace Calc.Windows;

/// <summary>
/// In-panel overlays in place of Calc's modal windows: the panel is a no-activate layered window, so a second top-level window would fight
/// it for the keyboard and the pointer. One overlay shows at a time; Esc or a click outside it closes it and typing returns to the sheet.
/// </summary>
public partial class CalculatorSurface
{
    private Action? overlayClose;
    private UIElement? overlayFocus;
    private IDisposable? overlayHold;

    private void ShowOverlay(FrameworkElement body, UIElement? focus, bool dim = true, HorizontalAlignment horizontal = HorizontalAlignment.Center,
        VerticalAlignment vertical = VerticalAlignment.Center, Thickness margin = default, double? width = null, Action? closed = null)
    {
        CloseOverlay(false);
        var card = new Border
        {
            Child = body,
            CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(14, 12, 14, 12),
            HorizontalAlignment = horizontal,
            VerticalAlignment = vertical,
            Margin = margin,
        };
        if (width is { } w) card.Width = w;
        card.SetResourceReference(Border.BackgroundProperty, "SurfaceRaisedBrush");
        card.SetResourceReference(Border.BorderBrushProperty, "StrokeStrongBrush");
        KeyboardNavigation.SetTabNavigation(card, KeyboardNavigationMode.Cycle);
        card.MouseDown += (_, e) => e.Handled = true; // A click inside is not a click outside.
        var backdrop = new Border { Background = dim ? new SolidColorBrush(Color.FromArgb(0x70, 0, 0, 0)) : Brushes.Transparent, CornerRadius = new CornerRadius(10) };
        // Any button outside closes, the middle one included: it never reaches a tab under the overlay.
        backdrop.MouseDown += (_, e) => { e.Handled = true; CloseOverlay(); };
        OverlayHost.Children.Add(backdrop);
        OverlayHost.Children.Add(card);
        OverlayHost.Visibility = Visibility.Visible;
        overlayHold ??= host.HoldOpen();
        overlayFocus = focus;
        overlayClose = closed ?? (() => { });
        if (focus is null) return;
        host.TakeKeyboard();
        focus.Focus();
        Keyboard.Focus(focus);
        // A control in a new template has no focusable parts until its first layout.
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, () =>
        {
            if (ReferenceEquals(overlayFocus, focus) && !focus.IsKeyboardFocusWithin) { focus.Focus(); Keyboard.Focus(focus); }
        });
    }

    private void CloseOverlay(bool returnFocus = true)
    {
        if (overlayClose is not { } closed) return;
        overlayClose = null;
        overlayFocus = null;
        OverlayHost.Children.Clear();
        OverlayHost.Visibility = Visibility.Collapsed;
        overlayHold?.Dispose();
        overlayHold = null;
        closed();
        if (returnFocus) Editor.Focus();
    }

    private void OverlayKeys(object sender, KeyEventArgs e)
    {
        if (overlayClose is null || e.Key != Key.Escape) return;
        e.Handled = true;
        CloseOverlay();
    }

    private static TextBlock OverlayTitle(string text) => new() { Text = text, FontSize = 14, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 10), TextTrimming = TextTrimming.CharacterEllipsis };

    private static StackPanel OverlayButtons(params Button[] buttons)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        foreach (var button in buttons)
        {
            button.Margin = new Thickness(8, 0, 0, 0);
            button.Padding = new Thickness(14, 4, 14, 4);
            row.Children.Add(button);
        }
        return row;
    }

    private static Button AccentButton(string text)
    {
        var button = new Button { Content = text, IsDefault = false };
        button.SetResourceReference(StyleProperty, "AccentButton");
        return button;
    }

    // ---------- rename ----------

    /// <summary>Renames this sheet, not whichever is in front by the time the box is confirmed.</summary>
    private void RenameSheet(Guid id)
    {
        if (workspace.Sheets.FirstOrDefault(sheet => sheet.Id == id) is not { } entry || tabList.IsClosed(id)) return;
        var input = new TextBox { Text = entry.Name, MaxLength = WorkspaceStore.MaxNameLength, FontSize = 13 };
        AutomationProperties.SetName(input, T["sheetName"]);
        AutomationProperties.SetAutomationId(input, "calculator-sheet-name");
        var problem = new TextBlock { FontSize = 11, Margin = new Thickness(0, 6, 0, 0), TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        problem.SetResourceReference(TextBlock.ForegroundProperty, "DangerBrush");
        var save = AccentButton(T["renameSheet"]);
        AutomationProperties.SetAutomationId(save, "calculator-sheet-name-save");
        var cancel = new Button { Content = T["cancel"] };
        void Commit()
        {
            var name = input.Text.Trim();
            if (name == entry.Name) { CloseOverlay(); return; }
            if (tabList.IsClosed(id) || !workspace.Sheets.Any(sheet => sheet.Id == id)) { CloseOverlay(); return; }
            if (name.Length == 0 || name.Any(char.IsControl)) { problem.Text = T["invalidSheetName"]; problem.Visibility = Visibility.Visible; input.SelectAll(); return; }
            if (id == document.Id && !Save()) return;
            if (RenameSheetTo(id, name)) CloseOverlay();
            else { problem.Text = T["sheetUnavailable"]; problem.Visibility = Visibility.Visible; }
        }
        save.Click += (_, _) => Commit();
        cancel.Click += (_, _) => CloseOverlay();
        input.PreviewKeyDown += (_, e) => { if (e.Key == Key.Enter) { Commit(); e.Handled = true; } };
        input.TextChanged += (_, _) => problem.Visibility = Visibility.Collapsed;
        var body = new StackPanel();
        body.Children.Add(OverlayTitle(T["renameSheet"]));
        body.Children.Add(input);
        body.Children.Add(problem);
        body.Children.Add(OverlayButtons(cancel, save));
        ShowOverlay(body, input, width: 320);
        input.SelectAll();
    }

    // ---------- all sheets ----------

    private sealed record SheetRow(SheetTab Tab, bool Current)
    {
        public string Name => Tab.Name;
        public Visibility Mark => Current ? Visibility.Visible : Visibility.Hidden;
    }

    private static DataTemplate? sheetRowTemplate;
    private static DataTemplate SheetRowTemplate()
    {
        if (sheetRowTemplate is not null) return sheetRowTemplate;
        var panel = new FrameworkElementFactory(typeof(DockPanel));
        var mark = new FrameworkElementFactory(typeof(TextBlock));
        mark.SetValue(TextBlock.TextProperty, "");
        mark.SetResourceReference(TextBlock.FontFamilyProperty, "IconFont");
        mark.SetValue(TextBlock.FontSizeProperty, 11.0);
        mark.SetResourceReference(TextBlock.ForegroundProperty, "AccentBrush");
        mark.SetValue(FrameworkElement.MarginProperty, new Thickness(0, 0, 8, 0));
        mark.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        mark.SetBinding(UIElement.VisibilityProperty, new Binding(nameof(SheetRow.Mark)));
        panel.AppendChild(mark);
        var name = new FrameworkElementFactory(typeof(TextBlock));
        name.SetBinding(TextBlock.TextProperty, new Binding(nameof(SheetRow.Name)));
        name.SetValue(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis);
        name.SetValue(TextBlock.FontSizeProperty, 12.0);
        name.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        panel.AppendChild(name);
        var template = new DataTemplate { VisualTree = panel };
        template.Seal();
        return sheetRowTemplate = template;
    }

    /// <summary>Every sheet in a filterable list: type to narrow, arrows to move, Enter to open.</summary>
    private void ShowAllSheets()
    {
        var filter = new TextBox { FontSize = 12, Margin = new Thickness(0, 0, 0, 8) };
        AutomationProperties.SetName(filter, T["filterSheets"]);
        AutomationProperties.SetAutomationId(filter, "calculator-tabs-filter");
        var list = new ListBox
        {
            MaxHeight = 214,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            ItemTemplate = SheetRowTemplate(),
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        VirtualizingPanel.SetIsVirtualizing(list, true);
        VirtualizingPanel.SetVirtualizationMode(list, VirtualizationMode.Recycling);
        AutomationProperties.SetName(list, T["allSheets"]);
        AutomationProperties.SetAutomationId(list, "calculator-tabs-list");
        var rows = tabList.Visible.Select(tab => new SheetRow(tab, tab.Id == document.Id)).ToArray();
        void Refill()
        {
            var query = filter.Text.Trim();
            var shown = query.Length == 0 ? rows : rows.Where(row => row.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToArray();
            list.ItemsSource = shown;
            list.SelectedItem = shown.FirstOrDefault(row => row.Current) ?? shown.FirstOrDefault();
            if (list.SelectedItem is { } selected) list.ScrollIntoView(selected);
        }
        void Open()
        {
            if (list.SelectedItem is not SheetRow row) return;
            CloseOverlay();
            SwitchSheet(row.Tab.Id);
            Tabs.RevealActive();
        }
        void Move(int by)
        {
            if (list.Items.Count == 0) return;
            list.SelectedIndex = Math.Clamp(list.SelectedIndex + by, 0, list.Items.Count - 1);
            list.ScrollIntoView(list.SelectedItem);
        }
        filter.TextChanged += (_, _) => Refill();
        filter.PreviewKeyDown += (_, e) =>
        {
            switch (e.Key)
            {
                case Key.Down: Move(1); e.Handled = true; break;
                case Key.Up: Move(-1); e.Handled = true; break;
                case Key.PageDown: Move(8); e.Handled = true; break;
                case Key.PageUp: Move(-8); e.Handled = true; break;
                case Key.Enter: Open(); e.Handled = true; break;
            }
        };
        list.PreviewKeyDown += (_, e) => { if (e.Key == Key.Enter) { Open(); e.Handled = true; } };
        list.MouseLeftButtonUp += (_, e) => { if (ItemsControl.ContainerFromElement(list, (DependencyObject)e.OriginalSource) is not null) Open(); };
        var hint = new TextBlock { Text = T["filterSheets"], FontSize = 12, IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 8) };
        hint.SetResourceReference(TextBlock.ForegroundProperty, "TextTertiaryBrush");
        filter.TextChanged += (_, _) => hint.Visibility = filter.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var box = new Grid();
        box.Children.Add(filter);
        box.Children.Add(hint);
        var body = new StackPanel();
        body.Children.Add(box);
        body.Children.Add(list);
        Refill();
        ShowOverlay(body, filter, dim: false, horizontal: HorizontalAlignment.Right, vertical: VerticalAlignment.Top, margin: new Thickness(0, 34, 40, 0), width: 280);
    }

    // ---------- a text report ----------

    private void ShowReport(string title, string report)
    {
        var text = new TextBox
        {
            Text = report, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 200, FontSize = 12,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, BorderThickness = new Thickness(0), Background = Brushes.Transparent,
        };
        AutomationProperties.SetName(text, title);
        var close = new Button { Content = T["close"] };
        close.Click += (_, _) => CloseOverlay();
        var body = new StackPanel();
        body.Children.Add(OverlayTitle(title));
        body.Children.Add(text);
        body.Children.Add(OverlayButtons(close));
        ShowOverlay(body, close, width: 460);
    }
}
