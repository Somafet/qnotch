using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Modules.Weather;

public enum WeatherStatus { NoPlace, Loading, Ready, Error }

/// <summary>Weather state. Only touch on the UI thread; WeatherService posts results through the bus.</summary>
public sealed partial class WeatherState : ObservableObject
{
    [ObservableProperty] WeatherStatus _status = WeatherStatus.Loading;
    [ObservableProperty] bool _refreshing;
    /// <summary>True when the shown forecast is the saved one because the last refresh failed.</summary>
    [ObservableProperty] bool _stale;
    [ObservableProperty] string _placeName = "";
    /// <summary>MET symbol code for now, "partlycloudy_day".</summary>
    [ObservableProperty] string _symbol = "";
    [ObservableProperty] string _tempText = "";
    [ObservableProperty] string _conditionText = "";
    /// <summary>"Feels 13° · 4 m/s".</summary>
    [ObservableProperty] string _detailText = "";
    [ObservableProperty] IReadOnlyList<WeatherDay> _days = [];
    [ObservableProperty] string _updatedText = "";
    /// <summary>Error or offline explanation, empty when fine.</summary>
    [ObservableProperty] string _message = "";
    /// <summary>The pill and game bar show the temperature: there is a forecast and the user wants it in the pill.</summary>
    [ObservableProperty] bool _pillVisible;
    [ObservableProperty] bool _gameVisible;
}
