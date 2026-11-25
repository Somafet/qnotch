using System.Text.Json;
using Calc.Core;
using Calc.Documents;

namespace QNotch.Modules.Calculator;

/// <summary>The saved workspace, opened off the UI thread. The store then belongs to the UI thread.</summary>
internal sealed class CalculatorSession
{
    public required string DataDirectory { get; init; }
    public required WorkspaceStore Store { get; init; }
    public required WorkspaceDocument Workspace { get; init; }
    public required PreferencesDocument Preferences { get; init; }
    public required FunctionLibrary Functions { get; init; }
    public LoadResult? Sheet { get; init; }
    public string? OpenFailure { get; init; }
    public bool Recovered { get; init; }

    public static CalculatorSession Open(string directory)
    {
        var store = new WorkspaceStore(directory);
        try
        {
            var loaded = store.Load();
            var preferences = store.LoadPreferences();
            var functions = store.LoadFunctions();
            LoadResult? sheet = null;
            string? failure = null;
            try { sheet = store.Open(loaded.Workspace.ActiveSheetId); }
            catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or JsonException) { failure = e.Message; }
            return new CalculatorSession
            {
                DataDirectory = directory,
                Store = store,
                Workspace = loaded.Workspace,
                Preferences = preferences,
                Functions = functions,
                Sheet = sheet,
                OpenFailure = failure,
                Recovered = loaded.Recovered || sheet?.Recovered == true || store.FunctionsRecovered || store.PreferencesRecovered,
            };
        }
        catch { store.Dispose(); throw; }
    }

    /// <summary>A snapshot run's sheets, in a throwaway folder: nothing of the user's is read or written.</summary>
    public static CalculatorSession OpenDemo(string directory)
    {
        Directory.CreateDirectory(directory);
        var store = new WorkspaceStore(directory);
        try
        {
            store.Rename(store.Load().Workspace.ActiveSheetId, "Trip");
            store.Create("Rent split", "rent = 1450 EUR\nshare = 3\nrent / share");
            var workspace = store.Create("Budget", DemoSource);
            return new CalculatorSession
            {
                DataDirectory = directory,
                Store = store,
                Workspace = workspace,
                Preferences = new(1, null),
                Functions = FunctionLibrary.Empty,
                Sheet = store.Open(workspace.ActiveSheetId),
            };
        }
        catch { store.Dispose(); throw; }
    }

    const string DemoSource = "# Weekend trip\nnights = 3\nhotel = 129 * nights\nfuel = 42 * 1.72\nhotel + fuel\n\n250 km in miles\n15% of 480\n2026-12-24 + 30 days\nsqrt(2) * 10";
}
