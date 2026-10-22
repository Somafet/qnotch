using System.Windows;
using System.Windows.Controls;
using QNotch.Modules;

namespace QNotch.Shell;

/// <summary>
/// Chrome around a Home card (title, order badge, hover state). One instance per visible card, reused across reorders.
/// Edit mode: the EditMode module may set RenderTransform / attach drag behaviour on the host. Do not set Content here.
/// </summary>
public sealed class CardHost : ContentControl
{
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(nameof(Title), typeof(string), typeof(CardHost), new(""));
    public static readonly DependencyProperty OrderNumberProperty = DependencyProperty.Register(nameof(OrderNumber), typeof(int), typeof(CardHost), new(0));
    public static readonly DependencyProperty IsEditModeProperty = DependencyProperty.Register(nameof(IsEditMode), typeof(bool), typeof(CardHost), new(false));

    /// <summary>Set by Edit mode while the card is dragged: accent border instead of a shadow (effects are software rendered here).</summary>
    public static readonly DependencyProperty IsLiftedProperty = DependencyProperty.Register(nameof(IsLifted), typeof(bool), typeof(CardHost), new(false));

    static CardHost() => DefaultStyleKeyProperty.OverrideMetadata(typeof(CardHost), new FrameworkPropertyMetadata(typeof(CardHost)));

    readonly CardLayout _layout;

    public CardHost(CardDescriptor descriptor, CardLayout layout)
    {
        _layout = layout;
        Descriptor = descriptor;
        Title = descriptor.Title;
        System.Windows.Automation.AutomationProperties.SetAutomationId(this, "card-" + descriptor.Id);
    }

    public override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        SyncSize();
    }

    internal void SyncSize()
    {
        if (Descriptor.SupportedSizes.Count < 2) return;
        foreach (var (part, direction) in new[] { ("ResizeLeft", -1), ("ResizeRight", 1) })
            if (GetTemplateChild(part) is ContentControl slot)
            {
                slot.Content ??= new CardResizeHandle(this, _layout, direction);
                if (slot.Content is CardResizeHandle handle) handle.SyncSize();
            }
    }

    public CardDescriptor Descriptor { get; }
    public string CardId => Descriptor.Id;
    public string Title { get => (string)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    /// <summary>Fixed 1-based position of this card in the full (including hidden) order. Shown as a badge in Edit mode.</summary>
    public int OrderNumber { get => (int)GetValue(OrderNumberProperty); set => SetValue(OrderNumberProperty, value); }
    public bool IsLifted { get => (bool)GetValue(IsLiftedProperty); set => SetValue(IsLiftedProperty, value); }
    public bool IsEditMode { get => (bool)GetValue(IsEditModeProperty); set => SetValue(IsEditModeProperty, value); }
}
