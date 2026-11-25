using Calc.Core;
using Calc.Documents;

namespace Calc.Documents.Tests;

public sealed class PreferencesTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "Calc-tests", Guid.NewGuid().ToString("N"));
    [Fact]
    public void RegionSurvivesRestartWithoutChangingSourceAndOldWorkspacesNeedNoRewrite()
    {
        Guid id;
        using (var store = new WorkspaceStore(directory))
        {
            id = store.Load().Workspace.ActiveSheetId;
            Assert.Null(store.LoadPreferences().WorkdayRegion);
            Assert.False(File.Exists(Path.Combine(directory, "preferences.json")));
            store.Open(id); store.Save(new(1, id, "f(n)=n working days\n2027-12-23+f(1)", false));
            store.SetWorkdayRegion("US");
        }
        using (var reopened = new WorkspaceStore(directory))
        {
            reopened.Load(); var region = reopened.LoadPreferences().WorkdayRegion; Assert.Equal("US", region);
            var sheet = reopened.Open(id); var session = new SheetEvaluationSession();
            Assert.Equal("2027-12-27", session.EvaluateWithFunctions(sheet.Document.Source, reopened.LoadFunctions(), sheet.FunctionReceipts ?? [], context: new(WorkdayRegion: region)).Results[^1].Display);
            Assert.Equal("2027-12-24", session.EvaluateWithFunctions(sheet.Document.Source, reopened.LoadFunctions(), sheet.FunctionReceipts ?? [], context: new(WorkdayRegion: "DE")).Results[^1].Display);
            Assert.Contains("f(1)", sheet.Document.Source);
            Assert.Null(reopened.SetWorkdayRegion(null).WorkdayRegion);
        }
    }
    [Fact]
    public void DefaultCurrencySurvivesRestartAndRejectsUnknownCodes()
    {
        using (var store = new WorkspaceStore(directory))
        {
            store.Load(); Assert.Null(store.LoadPreferences().DefaultCurrency);
            var saved = store.UpdatePreferences(value => value with { DefaultCurrency = "HUF" });
            Assert.Equal(2, saved.Version);
            Assert.Throws<InvalidDataException>(() => store.UpdatePreferences(value => value with { DefaultCurrency = "ZZZ" }));
        }
        using (var reopened = new WorkspaceStore(directory))
        {
            reopened.Load(); Assert.Equal("HUF", reopened.LoadPreferences().DefaultCurrency);
            Assert.Null(reopened.UpdatePreferences(value => value with { DefaultCurrency = null }).DefaultCurrency);
        }
    }
    [Fact]
    public void CorruptPreferencesRecoverTheLastGoodBackupAndPreserveRejectedBytes()
    {
        using var store = new WorkspaceStore(directory); store.Load(); store.SetWorkdayRegion("DE"); store.SetWorkdayRegion("US");
        var path = Path.Combine(directory, "preferences.json"); File.WriteAllText(path, "{bad");
        Assert.Equal("DE", store.LoadPreferences().WorkdayRegion); Assert.True(store.PreferencesRecovered);
        Assert.Equal("{bad", File.ReadAllText(Directory.GetFiles(directory, "preferences.json.corrupt-*").Single()));
    }
    [Fact]
    public void UnsupportedVersionsAndInvalidChoicesCannotBeSilentlyOverwritten()
    {
        using var store = new WorkspaceStore(directory); store.Load(); store.SetWorkdayRegion("DE");
        Assert.Throws<InvalidDataException>(() => store.SetWorkdayRegion("ZZ"));
        var path = Path.Combine(directory, "preferences.json"); const string future = "{\"Version\":999,\"WorkdayRegion\":\"US\"}";
        File.WriteAllText(path, future);
        Assert.Throws<UnsupportedDocumentVersionException>(() => store.LoadPreferences());
        Assert.Throws<UnsupportedDocumentVersionException>(() => store.SetWorkdayRegion("US"));
        Assert.Equal(future, File.ReadAllText(path));
    }
    [Fact]
    public void FailedPreferenceReplacementRetainsThePreviousCalendar()
    {
        using var store = new WorkspaceStore(directory); store.Load(); store.SetWorkdayRegion("DE");
        var path = Path.Combine(directory, "preferences.json");
        using (var locked = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            Assert.Throws<IOException>(() => store.SetWorkdayRegion("US"));
        Assert.Equal("DE", store.LoadPreferences().WorkdayRegion);
        Assert.Empty(Directory.GetFiles(directory, "preferences.json.*.tmp"));
    }
    [Fact]
    public void AutomaticCurrencyDownloadsDefaultOffAndCalendarChangesPreserveTheExplicitChoice()
    {
        using (var store = new WorkspaceStore(directory))
        {
            store.Load(); Assert.False(store.LoadPreferences().AutoCurrencyRates);
            store.SetAutoCurrencyRates(true); Assert.True(store.SetWorkdayRegion("DE").AutoCurrencyRates);
        }
        using var reopened = new WorkspaceStore(directory); reopened.Load();
        Assert.True(reopened.LoadPreferences().AutoCurrencyRates); Assert.Equal("DE",reopened.LoadPreferences().WorkdayRegion);
        Assert.Equal("DE",reopened.SetAutoCurrencyRates(false).WorkdayRegion);
    }
    [Fact]
    public void RecoveringAnOlderBackupCannotReenableRevokedNetworkConsent()
    {
        using (var store = new WorkspaceStore(directory))
        {
            store.Load(); store.SetAutoCurrencyRates(true); store.SetAutoCurrencyRates(false);
            File.WriteAllText(Path.Combine(directory,"preferences.json"),"{bad");
            Assert.False(store.LoadPreferences().AutoCurrencyRates); Assert.True(store.PreferencesRecovered);
        }
        using var reopened = new WorkspaceStore(directory); reopened.Load();
        Assert.False(reopened.LoadPreferences().AutoCurrencyRates);
    }
    public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
}
