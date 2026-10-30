using System.Text.Json;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Modules.Notifications;
using QNotch.Shell;
using QNotch.Shell.Onboarding;
using QNotch.Shell.Settings;

if (args.Contains("--analytics-idle-measure")) { AnalyticsChecks.Measure(); return 0; }

var tests = new List<(string Name, Action Run)>
{
    ("Analytics privacy, consent, bounded delivery, retries and identity", AnalyticsChecks.Run),
    ("Terminal defaults, local opt-in, bounded VT screen and input encoding", TerminalChecks.Deterministic),
    ("Small and Medium bodies fit live, empty, loading and error states", CardRenderingChecks.Run),
    ("Home sizes preserve defaults, reject unsupported choices and survive reload", () =>
    {
        var cards = new Registry<CardDescriptor>();
        cards.Register(new("small", "Small only", 1, () => null!));
        cards.Register(new("wide", "Resizable", 2, () => null!, DefaultSize: CardSize.Medium));
        var gs = new GeneralSettings { CardSizes = new() { ["disabled"] = "Small", ["future"] = "Large" } };
        var layout = new CardLayout(cards, gs);
        var changes = 0;
        layout.Changed += () => changes++;
        Require(layout.SizeOf("wide") == CardSize.Medium && layout.SizeOf("small") == CardSize.Small);
        layout.SetSize("small", CardSize.Medium);
        layout.SetSize("wide", (CardSize)99);
        layout.SetSize("missing", CardSize.Small);
        Require(changes == 0);
        layout.SetSize("wide", CardSize.Small);
        layout.SetVisible("wide", false);
        var loaded = JsonSerializer.Deserialize<GeneralSettings>(JsonSerializer.Serialize(gs, SettingsStore.Json), SettingsStore.Json)!;
        var restored = new CardLayout(cards, loaded);
        Require(restored.SizeOf("wide") == CardSize.Small && !restored.IsVisible("wide"));
        Require(loaded.CardSizes["disabled"] == "Small" && loaded.CardSizes["future"] == "Large");
        cards.Register(new("disabled", "Enabled again", 3, () => null!, DefaultSize: CardSize.Medium));
        Require(restored.SizeOf("disabled") == CardSize.Small);
        restored.SetVisible("wide", true);
        restored.SetSize("wide", CardSize.Medium);
        Require(restored.SizeOf("wide") == CardSize.Medium);
        loaded.CardSizes["wide"] = "Large";
        loaded.CardSizes["small"] = "Medium";
        Require(restored.SizeOf("wide") == CardSize.Medium && restored.SizeOf("small") == CardSize.Small);
        Require(cards.Items.All(c => c.SupportedSizes.Contains(CardSize.Small)));
        Require(SetupCode.ShellSections.Single(s => s.Id == "general").Shared.Fields.Contains("CardSizes"));
    }),
    ("notification manual mute persists locally outside setup codes", () =>
    {
        Require(!new NotificationLocalSettings().Muted);
        var local = JsonSerializer.Deserialize<NotificationLocalSettings>(JsonSerializer.Serialize(new NotificationLocalSettings { Muted = true }, SettingsStore.Json), SettingsStore.Json)!;
        Require(local.Muted);
        Require(!SetupCode.All(ModuleList.All).Any(s => s.Id == "notifications.local"));
        Require(!ModuleList.All.Single(m => m.Id == "notifications").Shared!.Fields.Contains("Muted"));
    }),
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
if (args.Contains("--conpty"))
{
    try { await TerminalChecks.ConPty(); }
    catch (Exception ex) { failures++; Console.Error.WriteLine("FAIL real ConPTY: " + ex); }
}
return failures == 0 ? 0 : 1;

static void Require(bool condition) { if (!condition) throw new InvalidOperationException("assertion failed"); }
