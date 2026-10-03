using System.Windows;
using System.Windows.Controls;
using CommunityToolkit.Mvvm.ComponentModel;
using QNotch.Theme;

namespace QNotch.Modules.Volume;

internal sealed partial class VolumeState : ObservableObject
{
    /// <summary>False without a playback device (render "unavailable").</summary>
    [ObservableProperty] bool _isAvailable = true;
    /// <summary>0..100.</summary>
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Text))] double _level;
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Text))] bool _muted;

    public string Text => Muted ? "Muted" : $"{Level:0}%";
}

/// <summary>
/// System volume card: slider, mute, mouse wheel. Event driven: the device reports changes made elsewhere, and the default device is
/// re-read each time the panel opens (it may have changed). No timer.
/// </summary>
public sealed class VolumeModule : INotchModule, ICadenceAware
{
    const string Speaker = "", SpeakerMuted = "";

    readonly VolumeState _st = new();
    readonly VolumeCom _com = new();
    ModuleContext _ctx = null!;

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        ctx.Cards.Register(new CardDescriptor("volume", "Volume", 25, Card));
        if (ctx.Settings.ReadOnly) { _st.Level = 62; return; } // snapshot run: demo level, never touch the audio device
        _com.Changed += (level, muted) => ctx.Bus.Run(() => Apply(level, muted));
    }

    public void SetCadence(Cadence cadence)
    {
        if (cadence != Cadence.Fast || _ctx.Settings.ReadOnly) return;
        Task.Run(() =>
        {
            var v = _com.Open();
            _ctx.Bus.Run(() =>
            {
                _st.IsAvailable = v is not null;
                if (v is { } x) Apply(x.Level, x.Muted);
            });
        });
    }

    void Apply(float level, bool muted)
    {
        _st.Level = Math.Round(level * 100);
        _st.Muted = muted;
    }

    void SetLevel(double level)
    {
        level = Math.Clamp(Math.Round(level), 0, 100);
        if (level == _st.Level) return;
        _st.Level = level;
        _com.SetLevel((float)(level / 100));
        if (_st.Muted && level > 0) SetMute(false);
    }

    void SetMute(bool mute)
    {
        _st.Muted = mute;
        _com.SetMute(mute);
    }

    FrameworkElement Card()
    {
        var mute = new Button { Style = (Style)Application.Current.FindResource("IconButton"), ToolTip = "Mute or unmute", Margin = new Thickness(-6, 0, 4, 0) };
        mute.Click += (_, _) => SetMute(!_st.Muted);
        var text = new TextBlock { FontSize = 22, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        UiKit.Bind(text, TextBlock.TextProperty, _st, nameof(VolumeState.Text));
        var top = new StackPanel { Orientation = Orientation.Horizontal };
        top.Children.Add(mute);
        top.Children.Add(text);

        var slider = new Slider { Minimum = 0, Maximum = 100, SmallChange = 2, LargeChange = 10, IsMoveToPointEnabled = true, Margin = new Thickness(0, 12, 0, 0) };
        slider.ValueChanged += (_, e) => SetLevel(e.NewValue);

        var live = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        live.Children.Add(top);
        live.Children.Add(slider);
        var none = Placeholder.Create(Speaker, "", "No playback device.");

        // Transparent background so the wheel works anywhere on the card body.
        var root = new Grid { Background = System.Windows.Media.Brushes.Transparent };
        root.Children.Add(live);
        root.Children.Add(none);
        root.MouseWheel += (_, e) => { if (_st.IsAvailable) SetLevel(_st.Level + Math.Sign(e.Delta) * 2); e.Handled = true; };

        void Refresh()
        {
            live.Visibility = _st.IsAvailable ? Visibility.Visible : Visibility.Collapsed;
            none.Visibility = _st.IsAvailable ? Visibility.Collapsed : Visibility.Visible;
            mute.Content = _st.Muted || _st.Level == 0 ? SpeakerMuted : Speaker;
            slider.Value = _st.Level;
            slider.Opacity = _st.Muted ? 0.4 : 1;
        }
        _st.PropertyChanged += (_, _) => Refresh();
        Refresh();
        return root;
    }
}
