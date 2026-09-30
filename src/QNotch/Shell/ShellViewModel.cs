using System.Windows.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using QNotch.Core;

namespace QNotch.Shell;

/// <summary>DataContext of the notch window. Owned by ShellController.</summary>
public sealed partial class ShellViewModel : ObservableObject
{
    public ShellViewModel(AppState state, GeneralSettings settings, Action openSettings)
    {
        State = state;
        Settings = settings;
        OpenSettingsCommand = new RelayCommand(openSettings);
    }

    public AppState State { get; }
    public GeneralSettings Settings { get; }
    public IRelayCommand OpenSettingsCommand { get; }

    [ObservableProperty] ImageSource? _profileImage;
    [ObservableProperty] string _profileInitial = "?";
    /// <summary>True only while collapsed with something playing: the glance strip under the pill.</summary>
    [ObservableProperty] bool _showGlance;
    [ObservableProperty] bool _isHomeSelected = true;
    [ObservableProperty] bool _isEditMode;
    [ObservableProperty] bool _motionEnabled = true;
    /// <summary>Header date line ("Tuesday, 30 September"), refreshed when the panel opens.</summary>
    [ObservableProperty] string _dateText = "";
}
