using System.Text.Json;
using Calc.Documents;

namespace Calc.Documents.Tests;

public sealed class PreferencesVersionTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "Calc-tests", Guid.NewGuid().ToString("N"));
    private string PreferencesPath => Path.Combine(directory, "preferences.json");
    private WorkspaceStore Open() { var store = new WorkspaceStore(directory); store.Load(); return store; }
    private int StoredVersion() => JsonDocument.Parse(File.ReadAllText(PreferencesPath)).RootElement.GetProperty("Version").GetInt32();

    [Fact]
    public void VersionOneFilesStayReadableAndAreNotRewrittenOnLoad()
    {
        using (Open()) { }
        const string legacy = "{\"Version\":1,\"WorkdayRegion\":\"DE\",\"AutoCurrencyRates\":true}";
        File.WriteAllText(PreferencesPath, legacy);
        using var store = Open();
        var loaded = store.LoadPreferences();
        Assert.Equal("DE", loaded.WorkdayRegion); Assert.True(loaded.AutoCurrencyRates);
        Assert.Null(loaded.FontSize); Assert.Null(loaded.DecimalPlaces); Assert.Null(loaded.NumberStyle);
        Assert.Null(loaded.Language); Assert.False(loaded.AlwaysOnTop); Assert.Null(loaded.Window);
        Assert.Equal(legacy, File.ReadAllText(PreferencesPath));
        // Version-1 settings alone keep the file readable by builds that predate version 2.
        store.SetWorkdayRegion("US"); Assert.Equal(1, StoredVersion());
    }
    [Fact]
    public void VersionTwoSettingsMigrateAndSurviveRestartWithoutLosingVersionOneChoices()
    {
        var placement = new WindowPlacementPreference(100, 80, 900, 700, true);
        using (var store = Open())
        {
            store.SetWorkdayRegion("DE"); store.SetAutoCurrencyRates(true);
            var saved = store.UpdatePreferences(current => current with { FontSize = 24, DecimalPlaces = 2, NumberStyle = "period", Language = "ja", AlwaysOnTop = true, Window = placement });
            Assert.Equal(2, saved.Version); Assert.Equal(2, StoredVersion());
        }
        using (var reopened = Open())
        {
            var loaded = reopened.LoadPreferences();
            Assert.Equal((24, 2, "period", "ja", true, placement, "DE", true),
                (loaded.FontSize!.Value, loaded.DecimalPlaces!.Value, loaded.NumberStyle, loaded.Language, loaded.AlwaysOnTop, loaded.Window, loaded.WorkdayRegion, loaded.AutoCurrencyRates));
            // Clearing every version-2 setting returns the file to version 1.
            reopened.UpdatePreferences(current => current with { FontSize = null, DecimalPlaces = null, NumberStyle = null, Language = null, AlwaysOnTop = false, Window = null });
            Assert.Equal(1, StoredVersion());
            Assert.Equal("DE", reopened.LoadPreferences().WorkdayRegion);
        }
    }
    [Theory]
    [InlineData("{\"Version\":2,\"FontSize\":9}")]
    [InlineData("{\"Version\":2,\"FontSize\":41}")]
    [InlineData("{\"Version\":2,\"DecimalPlaces\":-1}")]
    [InlineData("{\"Version\":2,\"DecimalPlaces\":21}")]
    [InlineData("{\"Version\":2,\"NumberStyle\":\"roman\"}")]
    [InlineData("{\"Version\":2,\"Language\":\"pt\"}")]
    [InlineData("{\"Version\":2,\"Window\":{\"Left\":0,\"Top\":0,\"Right\":0,\"Bottom\":10,\"Maximized\":false}}")]
    [InlineData("{\"Version\":2,\"Window\":{\"Left\":-2000000,\"Top\":0,\"Right\":10,\"Bottom\":10,\"Maximized\":false}}")]
    [InlineData("{\"Version\":1,\"FontSize\":24}")]
    public void InvalidStoredSettingsRecoverTheLastGoodBackupAndKeepTheRejectedBytes(string invalid)
    {
        using var store = Open();
        store.UpdatePreferences(current => current with { FontSize = 18 });
        store.UpdatePreferences(current => current with { FontSize = 22 });
        File.WriteAllText(PreferencesPath, invalid);
        Assert.Equal(18, store.LoadPreferences().FontSize); Assert.True(store.PreferencesRecovered);
        Assert.Equal(invalid, File.ReadAllText(Directory.GetFiles(directory, "preferences.json.corrupt-*").Single()));
    }
    [Fact]
    public void InvalidChoicesAndFutureVersionsAreNeverWritten()
    {
        using var store = Open();
        store.UpdatePreferences(current => current with { DecimalPlaces = 3 });
        var before = File.ReadAllText(PreferencesPath);
        Assert.Throws<InvalidDataException>(() => store.UpdatePreferences(current => current with { FontSize = 100 }));
        Assert.Throws<InvalidDataException>(() => store.UpdatePreferences(current => current with { Language = "EN" }));
        Assert.Throws<InvalidDataException>(() => store.UpdatePreferences(current => current with { Window = new(0, 0, 0, 0, false) }));
        Assert.Equal(before, File.ReadAllText(PreferencesPath));
        const string future = "{\"Version\":3,\"FontSize\":24}";
        File.WriteAllText(PreferencesPath, future);
        Assert.Throws<UnsupportedDocumentVersionException>(() => store.UpdatePreferences(current => current with { FontSize = 16 }));
        Assert.Equal(future, File.ReadAllText(PreferencesPath));
    }
    [Fact]
    public void LargestSettingsStayInsideTheFourKibibyteBound()
    {
        using var store = Open();
        var largest = store.UpdatePreferences(current => current with { WorkdayRegion = "WEEKDAYS", AutoCurrencyRates = true, FontSize = 40, DecimalPlaces = 20, NumberStyle = "apostrophe",
            Language = "zh-Hans", AlwaysOnTop = true, Window = new(-1_000_000, -1_000_000, -900_000, -900_000, true) });
        Assert.True(new FileInfo(PreferencesPath).Length < 1024);
        Assert.Equal(largest, store.LoadPreferences());
    }
    [Fact]
    public void InterfaceLanguagesAreTheKeywordAliasLanguages()
    {
        var root = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(root, "QNotch.sln"))) root = Path.GetDirectoryName(root) ?? throw new DirectoryNotFoundException("Repository root");
        using var keywords = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "src", "QNotch.Calculator.Engine", "LanguageKeywords.json")));
        var codes = keywords.RootElement.GetProperty("languages").EnumerateArray().Select(language => language.GetProperty("code").GetString()!).ToArray();
        Assert.Equal(codes, PreferencesDocument.Languages);
    }
    public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
}
