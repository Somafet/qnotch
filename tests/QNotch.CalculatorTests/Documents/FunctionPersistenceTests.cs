using System.Text.Json;
using Calc.Core;
using Calc.Documents;

namespace Calc.Documents.Tests;

public sealed class FunctionPersistenceTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "Calc-tests", Guid.NewGuid().ToString("N"));
    private static SheetDocument Save(WorkspaceStore store, Guid id, string source)
    {
        var opened = store.Open(id).Document with { Source = source };
        var update = FunctionUpdate.Prepare(source, store.LoadFunctions(), store.LoadFunctionReceipts(id));
        store.SaveWithFunctions(opened, update); return opened;
    }
    [Fact]
    public void DefinitionsSurviveRestartAndOldSheetsDoNotOverrideNewDefinitions()
    {
        Guid first; Guid second;
        using (var store = new WorkspaceStore(directory))
        {
            first = store.Load().Workspace.ActiveSheetId;
            Save(store, first, "f(x)=x+1");
            second = store.Create("Other").ActiveSheetId;
            Save(store, second, "f(x)=x+2");
        }
        using var reopened = new WorkspaceStore(directory); reopened.Load();
        var sheet = reopened.Open(first);
        var evaluated = new SheetEvaluationSession().EvaluateWithFunctions(sheet.Document.Source + "\nf(10)", reopened.LoadFunctions(), sheet.FunctionReceipts!);
        Assert.Equal("12", evaluated.Results[1].Display);
        Save(reopened, second, "forget f");
        Assert.Empty(reopened.LoadFunctions().Definitions);
        Assert.Empty(Directory.GetFiles(directory, "function-save.json"));
    }
    [Fact]
    public void CalendarFunctionsReopenFromSourceWithTheNewHostDate()
    {
        Guid id;
        const string source="nextMonth(d)=d+1month\ncurrent()=today\nnextMonth(2024-01-31)\ncurrent()";
        using(var store=new WorkspaceStore(directory))
        {
            id=store.Load().Workspace.ActiveSheetId;Save(store,id,source);
        }
        using var reopened=new WorkspaceStore(directory);reopened.Load();var sheet=reopened.Open(id);
        Assert.Equal(source,sheet.Document.Source);
        var session=new SheetEvaluationSession();var result=session.EvaluateWithFunctions(sheet.Document.Source,reopened.LoadFunctions(),sheet.FunctionReceipts!,context:new(new DateOnly(2026,10,30)));
        Assert.False(result.Functions.HasChanges);Assert.Equal("2024-02-29",result.Results[2].Display);Assert.Equal("2026-10-30",result.Results[3].Display);
        Assert.Equal("2026-11-01",session.EvaluateWithFunctions("current()",reopened.LoadFunctions(),[],context:new(new DateOnly(2026,11,1))).Results[0].Display);
    }
    [Fact]
    public void ClockIntervalFunctionsReopenWithoutAClockOrEvaluatedSnapshot()
    {
        Guid id;const string source="work(a,b)=from a to b\nshift(t)=t+90min\nwork(22:00,06:00)-30min\nshift(23:30)";
        using(var store=new WorkspaceStore(directory)){id=store.Load().Workspace.ActiveSheetId;Save(store,id,source);}
        using var reopened=new WorkspaceStore(directory);reopened.Load();var sheet=reopened.Open(id);
        Assert.Equal(source,sheet.Document.Source);
        var result=new SheetEvaluationSession().EvaluateWithFunctions(source,reopened.LoadFunctions(),sheet.FunctionReceipts!);
        Assert.False(result.Functions.HasChanges);Assert.False(result.UsesCurrentDate);
        Assert.Equal("7 h 30 min",result.Results[2].Display);Assert.Equal("(01:00 + 1 day)",result.Results[3].Display);
    }
    [Fact]
    public void ZonedAndCurrentTimeFunctionsReopenFromSourceWithFreshContext()
    {
        Guid id; const string source = "zone(d,t)=d at t Europe/Budapest\nclock()=now in unix\nzone(2026-10-30,15:00)\nclock()";
        using (var store = new WorkspaceStore(directory))
        { id = store.Load().Workspace.ActiveSheetId; Save(store, id, source); }
        using var reopened = new WorkspaceStore(directory); reopened.Load(); var sheet = reopened.Open(id);
        Assert.Equal(source, sheet.Document.Source);
        var instant = new DateTimeOffset(2026, 10, 30, 12, 0, 1, TimeSpan.Zero);
        var result = new SheetEvaluationSession().EvaluateWithFunctions(sheet.Document.Source, reopened.LoadFunctions(), sheet.FunctionReceipts!, context: new(Now: instant));
        Assert.False(result.Functions.HasChanges); Assert.True(result.UsesCurrentInstant); Assert.False(result.UsesCurrentDate);
        Assert.Equal("2026-10-30T15:00:00+01:00", result.Results[2].Display); Assert.Equal("1793361601", result.Results[3].Display);
        Assert.DoesNotContain("1793361601", File.ReadAllText(Path.Combine(directory, "functions.json")));
    }
    [Fact]
    public void CountdownFunctionsReopenWithFreshClockAndLocalRules()
    {
        Guid id; const string source = "remaining(d)=until d\nremaining(2026-11-01)";
        using (var store = new WorkspaceStore(directory))
        { id = store.Load().Workspace.ActiveSheetId; Save(store, id, source); }
        using var reopened = new WorkspaceStore(directory); reopened.Load(); var sheet = reopened.Open(id);
        var context = new EvaluationContext(new(2026, 10, 31), new DateTimeOffset(2026, 10, 31, 12, 0, 0, TimeSpan.Zero),
            LocalZone: new(NodaTime.DateTimeZone.Utc, "test UTC"));
        var result = new SheetEvaluationSession().EvaluateWithFunctions(sheet.Document.Source, reopened.LoadFunctions(), sheet.FunctionReceipts!, context: context);
        Assert.False(result.Functions.HasChanges); Assert.True(result.RequiresSecondRefresh); Assert.True(result.UsesLocalTimeZone);
        Assert.Equal("12 h", result.Results[1].Display); Assert.Equal(source, sheet.Document.Source);
        Assert.DoesNotContain("12 h", File.ReadAllText(Path.Combine(directory, "functions.json")));
    }
    [Theory]
    [InlineData("body")]
    [InlineData("library")]
    [InlineData("receipts")]
    public void InterruptedSaveReplaysCompleteTransactionBeforeOtherWrites(string stage)
    {
        Guid id; string file;
        using (var store = new WorkspaceStore(directory))
        {
            id = store.Load().Workspace.ActiveSheetId; Save(store, id, "f(x)=x+1");
            var document = store.Open(id).Document with { Source = "f(x)=x+2" };
            var update = FunctionUpdate.Prepare(document.Source, store.LoadFunctions(), store.LoadFunctionReceipts(id));
            file = stage switch
            {
                "body" => Path.Combine(directory, "sheets", id.ToString("N") + ".json"),
                "library" => Path.Combine(directory, "functions.json"),
                _ => Path.Combine(directory, "sheets", id.ToString("N") + ".receipts")
            };
            using var locked = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
            Assert.ThrowsAny<IOException>(() => store.SaveWithFunctions(document, update));
            Assert.True(File.Exists(Path.Combine(directory, "function-save.json")));
            Assert.ThrowsAny<IOException>(() => store.Rename(id, "must not bypass pending transaction"));
        }
        using var reopened = new WorkspaceStore(directory); reopened.Load();
        var sheet = reopened.Open(id);
        Assert.Equal("f(x)=x+2", sheet.Document.Source);
        Assert.Equal("12", new SheetEvaluationSession().EvaluateWithFunctions("f(10)", reopened.LoadFunctions(), []).Results[0].Display);
        Assert.Single(sheet.FunctionReceipts!);
        Assert.False(File.Exists(Path.Combine(directory, "function-save.json")));
    }
    [Fact]
    public void FailedAndStalePlansCannotReplaceFunctions()
    {
        using var store = new WorkspaceStore(directory); var id = store.Load().Workspace.ActiveSheetId;
        Save(store, id, "f(x)=x+1");
        var document = store.Open(id).Document with { Source = "f(x)=x+2" };
        var stale = FunctionUpdate.Prepare(document.Source, store.LoadFunctions(), store.LoadFunctionReceipts(id));
        Save(store, id, "f(x)=x+3");
        Assert.Throws<InvalidDataException>(() => store.SaveWithFunctions(document, stale));
        var bad = Save(store, id, "f(x)=unknown(x)");
        Assert.Equal("f(x)=unknown(x)", bad.Source);
        Assert.Equal("13", new SheetEvaluationSession().EvaluateWithFunctions("f(10)", store.LoadFunctions(), []).Results[0].Display);
    }
    [Fact]
    public void FunctionLibraryCorruptionRecoversBackupAndPreservesRejectedFile()
    {
        using (var store = new WorkspaceStore(directory))
        {
            var id = store.Load().Workspace.ActiveSheetId;
            Save(store, id, "f(x)=x+1"); Save(store, id, "f(x)=x+2");
        }
        File.WriteAllText(Path.Combine(directory, "functions.json"), "{bad");
        using var reopened = new WorkspaceStore(directory); reopened.Load();
        Assert.Equal("11", new SheetEvaluationSession().EvaluateWithFunctions("f(10)", reopened.LoadFunctions(), []).Results[0].Display);
        Assert.Single(Directory.GetFiles(directory, "functions.json.corrupt-*"));
    }
    [Fact]
    public void ForeignOrFutureJournalIsRefusedBeforeMutatingSource()
    {
        using (var store = new WorkspaceStore(directory)) store.Load();
        var transaction = new FunctionSaveTransaction(1, new(1, Guid.NewGuid(), "overwrite", false), new(1, []), new(1, Guid.NewGuid(), []));
        var journal = Path.Combine(directory, "function-save.json");
        File.WriteAllText(journal, JsonSerializer.Serialize(transaction));
        using var reopened = new WorkspaceStore(directory);
        Assert.Throws<InvalidDataException>(() => reopened.Load());
        Assert.True(File.Exists(journal));
        Assert.Single(Directory.GetFiles(Path.Combine(directory, "sheets"), "*.json"));
        File.WriteAllText(journal, JsonSerializer.Serialize(transaction with { Version = 2 }));
        Assert.Throws<UnsupportedDocumentVersionException>(() => reopened.Load());
    }
    public void Dispose() => Directory.Delete(directory, true);
}
