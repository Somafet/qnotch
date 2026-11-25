using System.Text.Json;
using Calc.Core;

namespace Calc.Documents.Tests;

public sealed class GeneratedUuidTests : IDisposable
{
    private readonly string directory=Path.Combine(Path.GetTempPath(),"Calc-uuid-tests",Guid.NewGuid().ToString("N"));
    private static string[] Values(GeneratedUuidSession session)
    {
        var engine=new SheetEvaluationSession();var context=new EvaluationContext{Uuids=session.Context};
        var evaluated=engine.EvaluateWithFunctions(session.Source,FunctionLibrary.Empty,[],context:context);
        if(evaluated.UuidRequests.Count>0){session.Supply(evaluated.UuidRequests,context.Uuids!);evaluated=engine.EvaluateWithFunctions(session.Source,FunctionLibrary.Empty,[],context:context with{Uuids=session.Context});}
        Assert.All(evaluated.Results,r=>Assert.Null(r.Error));return evaluated.Results.Where(r=>r.Value?.Kind==SheetValueKind.Text).Select(r=>r.Value!.Value.Text.Value).ToArray();
    }
    [Fact]
    public void EditsUndoReplayCopiesAndDocumentIsolation()
    {
        var session=new GeneratedUuidSession("uuid\nuuid\n2+2");Assert.False(session.Enabled);Assert.Null(session.Snapshot);Assert.Null(session.Context);
        Assert.True(session.Enable());Assert.False(session.Enable());var before=Values(session);
        var edit=session.Apply("uuid\nuuid\nuuid\n2+2",0,0,5);var after=Values(session);Assert.Equal(before,after.Skip(1));Assert.DoesNotContain(after[0],before);
        edit.Undo();session.ReplaySource("uuid\nuuid\n2+2");Assert.Equal(before,Values(session));edit.Redo();session.ReplaySource("uuid\nuuid\nuuid\n2+2");Assert.Equal(after,Values(session));
        var snapshot=session.Snapshot!;var loaded=new GeneratedUuidSession(session.Source,snapshot);Assert.Equal(after,Values(loaded));snapshot.Statements[0]=Guid.NewGuid();Assert.Equal(after,Values(loaded));
        var independent=new GeneratedUuidSession(session.Source);independent.Enable();Assert.DoesNotContain(Values(independent)[0],after);
    }
    [Fact]
    public void VersionOneMigratesOnlyWhenGenerationIsUsedAndSurvivesRestart()
    {
        string[] values;Guid id;
        using(var store=new WorkspaceStore(directory))
        {
            var workspace=store.Load().Workspace;id=workspace.ActiveSheetId;var doc=store.Open(id).Document;Assert.Equal(1,doc.Version);Assert.Null(doc.GeneratedUuids);
            var session=new GeneratedUuidSession("uuid\nuuid()");session.Enable();values=Values(session);
            store.Save(doc with{Version=2,Source=session.Source,GeneratedUuids=session.Snapshot});
        }
        using var reopened=new WorkspaceStore(directory);reopened.Load();var saved=reopened.Open(id).Document;
        Assert.Equal(2,saved.Version);Assert.NotNull(saved.GeneratedUuids);Assert.Equal(values,Values(new(saved.Source,saved.GeneratedUuids)));
    }
    [Fact]
    public void FunctionJournalCommitsUuidStateWithSourceAndFunctions()
    {
        using var store=new WorkspaceStore(directory);var ws=store.Load().Workspace;var doc=store.Open(ws.ActiveSheetId).Document;
        var session=new GeneratedUuidSession("saved()=uuid\nsaved()");session.Enable();var expected=Values(session);var next=doc with{Version=2,Source=session.Source,GeneratedUuids=session.Snapshot};
        var update=FunctionUpdate.Prepare(next.Source,store.LoadFunctions(),[]);store.SaveWithFunctions(next,update);
        using var catalog=JsonDocument.Parse(File.ReadAllText(Path.Combine(directory,"functions.json")));Assert.Equal(2,catalog.RootElement.GetProperty("Version").GetInt32());
        var loaded=store.Open(doc.Id).Document;var result=new SheetEvaluationSession().EvaluateWithFunctions(loaded.Source,store.LoadFunctions(),store.LoadFunctionReceipts(doc.Id),context:new(){Uuids=new GeneratedUuidSession(loaded.Source,loaded.GeneratedUuids).Context});
        Assert.Null(result.Results[1].Error);Assert.Equal(expected[0],result.Results[1].Display);
    }
    [Fact]
    public void CorruptionRecoversPairedStateAndFutureSchemaIsPreserved()
    {
        using var store=new SheetStore(directory);var original=store.Load().Document;var session=new GeneratedUuidSession("uuid");session.Enable();
        var expected=Values(session);var doc=original with{Version=2,Source=session.Source,GeneratedUuids=session.Snapshot};store.Save(doc);store.Save(doc with{Dark=true});
        var path=Path.Combine(directory,"sheet.json");File.WriteAllText(path,"{bad");var recovered=store.Load();Assert.True(recovered.Recovered);Assert.Equal(Values(session),Values(new(recovered.Document.Source,recovered.Document.GeneratedUuids)));
        var future=JsonSerializer.Serialize(doc with{Version=3});File.WriteAllText(path,future);Assert.Throws<UnsupportedDocumentVersionException>(()=>store.Load());Assert.Equal(future,File.ReadAllText(path));
    }
    [Fact]
    public void BadMetadataCannotOverwriteAValidSheet()
    {
        using var store=new SheetStore(directory);var doc=store.Load().Document;store.Save(doc);var path=Path.Combine(directory,"sheet.json");var before=File.ReadAllText(path);
        Assert.Throws<InvalidDataException>(()=>store.Save(doc with{Version=2}));
        Assert.Throws<InvalidDataException>(()=>store.Save(doc with{GeneratedUuids=new(1,[Guid.NewGuid()],[])}));
        Assert.Throws<InvalidDataException>(()=>store.Save(doc with{Version=2,GeneratedUuids=new(1,[Guid.Empty],[])}));Assert.Equal(before,File.ReadAllText(path));
    }
    [Fact]
    public void MaximumDocumentLinesRemainBoundedThroughUndo()
    {
        var session=new GeneratedUuidSession("uuid");session.Enable();var before=Values(session);
        var source=new string('\n',10000)+"uuid";var edit=session.Apply(source,0,0,10000);Assert.Equal(10000,session.Snapshot!.Statements.Length);
        GeneratedUuidSession.Validate(source,session.Snapshot);edit.Undo();session.ReplaySource("uuid");Assert.Equal(before,Values(session));
    }
    [Fact]
    public void MaximumUnicodeSourceAndMetadataCanBeSavedAndReopened()
    {
        var source=new string('中',190001)+new string('\n',9999);var ids=Enumerable.Range(0,10000).Select(_=>Guid.NewGuid()).ToArray();
        var values=Enumerable.Range(0,1024).Select(i=>new UuidBinding(ids[0],new string('中',59)+i.ToString("x3"),Guid.NewGuid())).ToArray();
        using var store=new SheetStore(directory);var original=store.Load().Document;
        store.Save(original with{Version=2,Source=source,GeneratedUuids=new(1,ids,values)});
        Assert.Equal(source,store.Load().Document.Source);Assert.Equal(1024,store.Load().Document.GeneratedUuids!.Bindings.Length);
        Assert.InRange(new FileInfo(Path.Combine(directory,"sheet.json")).Length,2_000_001,SheetStore.MaxDocumentBytes);
    }
    [Fact]
    public void StaleRequestsAndMismatchedEditsCannotChangeBindings()
    {
        var session=new GeneratedUuidSession("uuid\n2");session.Enable();var observed=session.Context!;
        var requests=new SheetEvaluationSession().EvaluateWithFunctions(session.Source,FunctionLibrary.Empty,[],context:new(){Uuids=observed}).UuidRequests;
        session.Apply(" uuid\n2",0,0,1);
        Assert.Throws<InvalidOperationException>(()=>session.Supply(requests,observed));Assert.Empty(session.Snapshot!.Bindings);
        var current=session.Source;Assert.Throws<ArgumentException>(()=>session.Apply(" uuid\n3",0,1,1));Assert.Equal(current,session.Source);
    }
    [Fact]
    public void UuidFunctionCatalogDoesNotDowngradeAndFutureVersionIsPreserved()
    {
        var path=Path.Combine(directory,"functions.json");
        using(var store=new WorkspaceStore(directory))
        {
            var ws=store.Load().Workspace;var doc=store.Open(ws.ActiveSheetId).Document;
            var source="saved()=uuid";var update=FunctionUpdate.Prepare(source,store.LoadFunctions(),[]);store.SaveWithFunctions(doc with{Source=source},update);
            source="forget saved";update=FunctionUpdate.Prepare(source,store.LoadFunctions(),store.LoadFunctionReceipts(doc.Id));store.SaveWithFunctions(doc with{Source=source},update);
            using var catalog=JsonDocument.Parse(File.ReadAllText(path));Assert.Equal(2,catalog.RootElement.GetProperty("Version").GetInt32());
        }
        var future="{\"Version\":"+(FunctionLibrary.LatestCatalogVersion+1)+",\"Definitions\":[]}";File.WriteAllText(path,future);
        using var reopened=new WorkspaceStore(directory);reopened.Load();Assert.Throws<UnsupportedDocumentVersionException>(()=>reopened.LoadFunctions());Assert.Equal(future,File.ReadAllText(path));
    }
    [Fact]
    public void VersionOneUuidCatalogMigratesWithoutRecoveringAwayDefinitions()
    {
        using var store=new WorkspaceStore(directory);store.Load();var path=Path.Combine(directory,"functions.json");
        var text=JsonSerializer.Serialize(new FunctionCatalog(1,[new("saved",[],"uuid")]));File.WriteAllText(path,text);File.WriteAllText(path+".bak",JsonSerializer.Serialize(new FunctionCatalog(1,[])));
        Assert.Equal("saved",Assert.Single(store.LoadFunctions().Definitions).Name);
        using var upgraded=JsonDocument.Parse(File.ReadAllText(path));Assert.Equal(2,upgraded.RootElement.GetProperty("Version").GetInt32());
        Assert.Equal(text,File.ReadAllText(path+".bak"));Assert.False(store.FunctionsRecovered);Assert.Empty(Directory.GetFiles(directory,"*.corrupt-*"));
    }
    public void Dispose(){if(Directory.Exists(directory))Directory.Delete(directory,true);}
}
