using System.Text.Json;
using Calc.Core;
namespace Calc.Documents.Tests;
public sealed class EquationFunctionTests : IDisposable
{
    private readonly string directory=Path.Combine(Path.GetTempPath(),"Calc-equation-tests",Guid.NewGuid().ToString("N"));
    [Fact]
    public void FormulaCatalogUsesSchemaFourSurvivesRestartAndNeverDowngrades()
    {
        Guid id;
        using(var store=new WorkspaceStore(directory))
        {
            var ws=store.Load().Workspace;id=ws.ActiveSheetId;var doc=store.Open(id).Document;
            var source="savedArea(b)=integral(x^2,0,b)\nsavedRoots(c)=solve x^2 = c\nsavedSlope(p)=derivative(sin(x),p)";
            store.SaveWithFunctions(doc with{Source=source},FunctionUpdate.Prepare(source,store.LoadFunctions(),[]));
        }
        using var reopened=new WorkspaceStore(directory);reopened.Load();var functions=reopened.LoadFunctions();Assert.Equal(FunctionLibrary.FormulaCatalogVersion,functions.MinimumCatalogVersion);
        var results=new SheetEvaluationSession().EvaluateWithFunctions("savedArea(3)\nsavedRoots(4)\nsavedSlope(0)",functions,[]).Results;
        Assert.All(results,r=>Assert.Null(r.Error));Assert.Equal(new[]{"9","x = -2 or x = 2","≈ 1"},results.Select(r=>r.Display));
        var doc2=reopened.Open(id).Document;var forget="forget savedArea\nforget savedRoots\nforget savedSlope";
        reopened.SaveWithFunctions(doc2 with{Source=forget},FunctionUpdate.Prepare(forget,functions,reopened.LoadFunctionReceipts(id)));
        using var catalog=JsonDocument.Parse(File.ReadAllText(Path.Combine(directory,"functions.json")));Assert.Equal(FunctionLibrary.FormulaCatalogVersion,catalog.RootElement.GetProperty("Version").GetInt32());
    }
    [Fact]
    public void EarlierCatalogMigratesAndLaterCatalogIsRefusedUntouched()
    {
        var path=Path.Combine(directory,"functions.json");
        using(var store=new WorkspaceStore(directory))
        {
            store.Load();var original=JsonSerializer.Serialize(new FunctionCatalog(3,[new("saved",["b"],"integral(x,0,b)")]));File.WriteAllText(path,original);
            Assert.Equal(FunctionLibrary.FormulaCatalogVersion,store.LoadFunctions().MinimumCatalogVersion);Assert.Equal(original,File.ReadAllText(path+".bak"));
            using var catalog=JsonDocument.Parse(File.ReadAllText(path));Assert.Equal(FunctionLibrary.FormulaCatalogVersion,catalog.RootElement.GetProperty("Version").GetInt32());
        }
        var future="{\"Version\":"+(FunctionLibrary.LatestCatalogVersion+1)+",\"Definitions\":[]}";File.WriteAllText(path,future);
        using var reopened=new WorkspaceStore(directory);reopened.Load();Assert.Throws<UnsupportedDocumentVersionException>(()=>reopened.LoadFunctions());Assert.Equal(future,File.ReadAllText(path));
    }
    public void Dispose(){if(Directory.Exists(directory))Directory.Delete(directory,true);}
}
