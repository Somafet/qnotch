using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Core.Updates;

internal sealed partial class UpdateState : ObservableObject
{
    public required string CurrentVersion { get; init; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasUpdate), nameof(CanUpdate), nameof(AvailableText))]
    string _availableVersion = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanCheck), nameof(CanUpdate))]
    bool _isBusy;

    [ObservableProperty] string _status = "Automatic checks are off. You can check manually at any time.";
    [ObservableProperty] int _downloadPercent;
    [ObservableProperty] bool _isDownloading;
    [ObservableProperty] bool _needsPreferenceChoice;

    public bool HasUpdate => AvailableVersion.Length > 0;
    public bool CanCheck => !IsBusy;
    public bool CanUpdate => HasUpdate && !IsBusy;
    public string AvailableText => $"QNotch {AvailableVersion} is available";
}
