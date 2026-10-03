using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Modules.Github;

public enum GithubStatus { NoToken, Loading, Ready, Error }

/// <summary>GitHub state. Only touch on the UI thread; GithubService posts results through the bus.</summary>
public sealed partial class GithubState : ObservableObject
{
    [ObservableProperty] GithubStatus _githubStatus = GithubStatus.Loading;
    [ObservableProperty] bool _githubHasToken;
    [ObservableProperty] bool _githubRefreshing;
    /// <summary>True when the shown data is the disk cache because the last refresh failed.</summary>
    [ObservableProperty] bool _githubStale;
    [ObservableProperty] GithubData? _githubGraph;
    [ObservableProperty] string _githubTotalText = "";
    [ObservableProperty] string _githubStreakText = "";
    [ObservableProperty] string _githubUpdatedText = "";
    /// <summary>Error or offline explanation, empty when fine.</summary>
    [ObservableProperty] string _githubMessage = "";
    [ObservableProperty] string _githubLogin = "";
}
