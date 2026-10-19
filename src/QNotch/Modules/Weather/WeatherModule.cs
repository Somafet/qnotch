namespace QNotch.Modules.Weather;

/// <summary>The forecast from yr.no for one place: a Home card, the temperature in the pill and the game bar, and a settings section.</summary>
public sealed class WeatherModule : INotchModule, ICadenceAware
{
    public const string Sun = "";

    WeatherService? _svc;

    public void Initialize(ModuleContext ctx)
    {
        var s = new WeatherState();
        var set = ctx.Settings.Get<WeatherSettings>("weather");
        var svc = _svc = new WeatherService(ctx, s, set);

        ctx.Cards.Register(new CardDescriptor("weather", "Weather", 15, () => new WeatherCard(s, svc, ctx.Shell), ColumnSpan: 2));
        ctx.SettingsSections.Register(new SettingsSectionDescriptor("weather", "Weather", Sun, 55, () => WeatherSection.Create(ctx, s, svc)));
        ctx.Segments.Register(new SegmentDescriptor("weather.pill", SegmentSlot.PillRight, 9, () => WeatherSegments.Pill(s)));
        ctx.Segments.Register(new SegmentDescriptor("weather.game", SegmentSlot.GameBar, 68, () => WeatherSegments.Game(s), "Weather", "Temperature and sky at your place."));

        if (!ctx.Settings.ReadOnly) WeatherSetup.PlaceChosen += svc.SetPlace; // the welcome tour, opened from Settings while this runs
        svc.Start();
    }

    /// <summary>Fast means the panel opened: bring "now" up to date, and fetch if the forecast expired while collapsed.</summary>
    public void SetCadence(Cadence cadence)
    {
        if (cadence == Cadence.Fast) _svc?.Wake();
    }
}
