using Calc.Documents;

namespace Calc.Documents.Tests;

public sealed class OfflineDefaultTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "Calc-tests", Guid.NewGuid().ToString("N"));
    [Fact]
    public void FreshAndOlderPreferencesLeaveAutomaticRatesOff()
    {
        using var store = new WorkspaceStore(directory); store.Load();
        Assert.False(store.LoadPreferences().AutoCurrencyRates);
        Assert.False(File.Exists(Path.Combine(directory, "preferences.json")));
        File.WriteAllText(Path.Combine(directory, "preferences.json"), "{\"Version\":1,\"WorkdayRegion\":null}");
        Assert.False(store.LoadPreferences().AutoCurrencyRates);
    }
    [Fact]
    public void AWorkspaceCreatesNoRateCache()
    {
        using var store = new WorkspaceStore(directory); store.Load();
        Assert.Empty(Directory.GetFiles(directory, "currency-rates*"));
    }
    public void Dispose() => Directory.Delete(directory, true);
}
