using System.Text.Json;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Shell;
using QNotch.Shell.Onboarding;
using QNotch.Shell.Settings;

var tests = new List<(string Name, Action Run)>
{
    ("presentation round trip keeps unknown ids and Home recovery", () =>
    {
        var p = new WindowsPresentationSettings();
        p.SetTab("media", false);
        p.SetTab("home", false);
        p.SetSegments(["agents.pill", "future.pill"], false);
        var loaded = JsonSerializer.Deserialize<WindowsPresentationSettings>(JsonSerializer.Serialize(p, SettingsStore.Json), SettingsStore.Json)!;
        Require(!loaded.TabVisible("media") && loaded.TabVisible("home") && loaded.TabVisible("future"));
        Require(!loaded.SegmentVisible("future.pill"));
        loaded.SetTab("media", true);
        Require(loaded.TabVisible("media"));
        Require(!SetupCode.All(ModuleList.All).Any(s => s.Id == "windows-presentation"));
    }),
    ("hidden and disabled cards retain saved positions", () =>
    {
        var cards = new Registry<CardDescriptor>();
        var gs = new GeneralSettings { CardOrder = ["disabled", "b", "a"] };
        cards.Register(new("a", "A", 1, () => null!));
        cards.Register(new("b", "B", 2, () => null!));
        var layout = new CardLayout(cards, gs);
        layout.SetVisible("b", false);
        Require(layout.Visible.Select(c => c.Id).SequenceEqual(["a"]));
        layout.Move("a", "b");
        Require(gs.CardOrder.SequenceEqual(["disabled", "a", "b"]));
        cards.Register(new("disabled", "Disabled", 0, () => null!));
        layout.SetVisible("b", true);
        Require(layout.Visible.Select(c => c.Id).SequenceEqual(["disabled", "a", "b"]));
    }),
    ("welcome Search switch writes the existing restart contract", () =>
    {
        var gs = new GeneralSettings();
        var c = new TourChoices(TourMode.FirstRun, gs, ModuleList.All.Select(m => m.Id));
        c.SetOn("search", false);
        c.Apply(gs, TourEnd.Skipped);
        Require(gs.DisabledModules.Contains("search"));
        Require(ModuleList.All.Single(m => m.Id == "search").Create is not null);
        Require(ModuleList.TourGroups.Count(g => g.Ids.Contains("search")) == 1);
    }),
};
var failures = 0;
foreach (var (name, run) in tests)
{
    try { run(); Console.WriteLine("PASS " + name); }
    catch (Exception ex) { failures++; Console.Error.WriteLine("FAIL " + name + ": " + ex); }
}
return failures == 0 ? 0 : 1;

static void Require(bool condition) { if (!condition) throw new InvalidOperationException("assertion failed"); }
