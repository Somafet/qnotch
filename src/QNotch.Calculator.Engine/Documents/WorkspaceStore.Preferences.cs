using Calc.Core;

namespace Calc.Documents;

public sealed record PreferencesDocument(int Version, string? WorkdayRegion)
{
    public bool AutoCurrencyRates { get; init; }
    // Version 2 display and window preferences. Absent values keep the version-1 behavior.
    public int? FontSize { get; init; }
    public int? DecimalPlaces { get; init; }
    public string? NumberStyle { get; init; }
    public string? Language { get; init; }
    public bool AlwaysOnTop { get; init; }
    public WindowPlacementPreference? Window { get; init; }
    /// <summary>ISO code plain monetary results are shown in; null shows each amount in its own currency.</summary>
    public string? DefaultCurrency { get; init; }
    public const int MinimumFontSize = 10, MaximumFontSize = 40;
    /// <summary>Interface languages: the nine keyword-alias languages.</summary>
    public static readonly IReadOnlyList<string> Languages = ["en", "ro", "de", "fr", "es", "it", "ja", "zh-Hans", "ko"];
    internal bool UsesVersion2 => FontSize is not null || DecimalPlaces is not null || NumberStyle is not null || Language is not null || AlwaysOnTop || Window is not null || DefaultCurrency is not null;
}

/// <summary>Restored (normal) window bounds in Windows workspace pixels, plus whether it was maximized.</summary>
public sealed record WindowPlacementPreference(int Left, int Top, int Right, int Bottom, bool Maximized)
{
    public const int MaximumCoordinate = 1_000_000, MaximumExtent = 100_000;
    public int Width => Right - Left;
    public int Height => Bottom - Top;
    public bool IsValid => Math.Abs((long)Left) <= MaximumCoordinate && Math.Abs((long)Top) <= MaximumCoordinate &&
        Math.Abs((long)Right) <= MaximumCoordinate && Math.Abs((long)Bottom) <= MaximumCoordinate &&
        Width is > 0 and <= MaximumExtent && Height is > 0 and <= MaximumExtent;
}

public sealed partial class WorkspaceStore
{
    public const int PreferencesVersion = 2;
    public bool PreferencesRecovered { get; private set; }
    public PreferencesDocument LoadPreferences()
    {
        RequireWorkspace();
        var path = Path.Combine(directory, "preferences.json");
        if (!File.Exists(path) && !File.Exists(path + ".bak")) return new(1, null);
        var loaded = AtomicJson.Load<PreferencesDocument>(path, 4096, ValidatePreferences);
        PreferencesRecovered = loaded.Recovered;
        var value = loaded.Value;
        if (loaded.Recovered && value.AutoCurrencyRates)
        {
            value = value with { AutoCurrencyRates = false };
            AtomicJson.Write(path,value); // Recovery cannot roll back a user's network-consent revocation.
        }
        return value;
    }
    public PreferencesDocument SetWorkdayRegion(string? region) => UpdatePreferences(current => current with { WorkdayRegion = region });
    public PreferencesDocument SetAutoCurrencyRates(bool enabled) => UpdatePreferences(current => current with { AutoCurrencyRates = enabled });
    /// <summary>Replaces preferences atomically. A file is written as version 2 only once it holds a version-2
    /// setting, so version-1 files stay readable by builds that predate these settings.</summary>
    public PreferencesDocument UpdatePreferences(Func<PreferencesDocument, PreferencesDocument> change)
    {
        RequireWorkspace();
        var current = LoadPreferences(); // Refuse an unsupported/external future document before replacement.
        var next = change(current);
        next = next with { Version = next.UsesVersion2 ? 2 : 1 };
        ValidatePreferences(next);
        AtomicJson.Write(Path.Combine(directory, "preferences.json"), next);
        return next;
    }
    private static void ValidatePreferences(PreferencesDocument value)
    {
        if (value.Version is not (1 or PreferencesVersion)) throw new UnsupportedDocumentVersionException();
        if (value.WorkdayRegion is not null && !WorkdayCalendar.SupportedRegions.Contains(value.WorkdayRegion))
            throw new InvalidDataException("Unsupported workday calendar preference");
        if (value.Version == 1 && value.UsesVersion2) throw new InvalidDataException("Version-1 preferences cannot hold version-2 settings");
        if (value.FontSize is < PreferencesDocument.MinimumFontSize or > PreferencesDocument.MaximumFontSize)
            throw new InvalidDataException("Unsupported text size preference");
        if (value.DecimalPlaces is < 0 or > ResultFormat.MaxDecimalPlaces) throw new InvalidDataException("Unsupported decimal places preference");
        if (value.NumberStyle is not null && !Calc.Core.NumberStyle.PresetIds.Contains(value.NumberStyle))
            throw new InvalidDataException("Unsupported number style preference");
        if (value.Language is not null && !PreferencesDocument.Languages.Contains(value.Language))
            throw new InvalidDataException("Unsupported language preference");
        if (value.DefaultCurrency is not null && !CurrencyCatalog.TryCode(value.DefaultCurrency, out _))
            throw new InvalidDataException("Unsupported default currency preference");
        if (value.Window is { IsValid: false }) throw new InvalidDataException("Invalid window placement preference");
    }
}
