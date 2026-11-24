using System.Text.Json;
using Calc.Core;
namespace Calc.Documents.Tests;
public sealed class RateFunctionTests : IDisposable
{
    private readonly string directory=Path.Combine(Path.GetTempPath(),"Calc-rate-tests",Guid.NewGuid().ToString("N"));
    [Fact]
    public void RateCatalogSurvivesRestartAndNeverDowngrades()
    {
        Guid id;
        using(var store=new WorkspaceStore(directory))
        {
            var ws=store.Load().Workspace;id=ws.ActiveSheetId;var doc=store.Open(id).Document;
            var source="savedTransfer(x)=x at 100 Mbps\nsavedCost(x)=x tokens at $3/M\nsavedUp(x)=x uptime for 30 days";
            store.SaveWithFunctions(doc with{Source=source},FunctionUpdate.Prepare(source,store.LoadFunctions(),[]));
        }
        using var reopened=new WorkspaceStore(directory);reopened.Load();var functions=reopened.LoadFunctions();Assert.Equal(3,functions.MinimumCatalogVersion);
        var results=new SheetEvaluationSession().EvaluateWithFunctions("savedTransfer(5 GB)\nsavedCost(1200000)\nsavedUp(99.9%)",functions,[]).Results;
        Assert.All(results,r=>Assert.Null(r.Error));Assert.Equal(new[]{"6 min 40 s","3.6 USD","43 min 12 s"},results.Select(r=>r.Display));
        var doc2=reopened.Open(id).Document;var forget="forget savedTransfer\nforget savedCost\nforget savedUp";
        reopened.SaveWithFunctions(doc2 with{Source=forget},FunctionUpdate.Prepare(forget,functions,reopened.LoadFunctionReceipts(id)));
        using var catalog=JsonDocument.Parse(File.ReadAllText(Path.Combine(directory,"functions.json")));Assert.Equal(3,catalog.RootElement.GetProperty("Version").GetInt32());
    }
    [Theory][InlineData(1)][InlineData(2)]
    public void EarlierDevelopmentCatalogMigratesAtomically(int version)
    {
        using var store=new WorkspaceStore(directory);store.Load();var path=Path.Combine(directory,"functions.json");
        var original=JsonSerializer.Serialize(new FunctionCatalog(version,[new("wire",[],"1 Mbps")]));File.WriteAllText(path,original);
        Assert.Equal(3,store.LoadFunctions().MinimumCatalogVersion);Assert.Equal(original,File.ReadAllText(path+".bak"));
        using var catalog=JsonDocument.Parse(File.ReadAllText(path));Assert.Equal(3,catalog.RootElement.GetProperty("Version").GetInt32());
    }
    public void Dispose(){if(Directory.Exists(directory))Directory.Delete(directory,true);}
}
