using Calc.Core;
using Calc.Providers;

namespace Calc.Providers.Tests;

public sealed class CurrencyCacheTests : IDisposable
{
    private readonly string directory=Path.Combine(Path.GetTempPath(),"Calc-provider-tests",Guid.NewGuid().ToString("N"));
    private string FilePath=>Path.Combine(directory,"currency-rates.json");
    private static readonly DateTimeOffset Now=new(2026,10,31,12,0,0,TimeSpan.Zero);
    private static CurrencyRateSnapshot Snapshot(int usd=2)=>new(EcbRateClient.Provider,"EUR",new(2026,10,30),Now,new Dictionary<string,Rational>{["EUR"]=new(1,1),["USD"]=new(usd,1)});
    [Fact]
    public void MissingCacheDoesNotCreateFilesAndRoundTripKeepsExactRatesAndDates()
    {
        var cache=new CurrencyRateCache(directory); Assert.Null(cache.Load().Book.Latest); Assert.False(Directory.Exists(directory));
        var book=new CurrencyRateBook(Snapshot(),new Dictionary<DateOnly,CurrencyRateSnapshot>{[new(2026,10,31)]=Snapshot()});
        cache.Save(book); var loaded=cache.Load(); Assert.Null(loaded.Warning); Assert.Equal(book.Key,loaded.Book.Key);
        Assert.Equal(new Rational(2,1),loaded.Book.Historical[new(2026,10,31)].Rates["USD"]);
    }
    [Fact]
    public void CorruptPrimaryFallsBackWithoutOverwritingRejectedBytesOrSheets()
    {
        var cache=new CurrencyRateCache(directory); cache.Save(new(Snapshot(),[])); cache.Save(new(Snapshot(3),[]));
        File.WriteAllText(FilePath,"{bad"); var recovered=cache.Load();
        Assert.True(recovered.Recovered); Assert.Equal(new Rational(2,1),recovered.Book.Latest!.Rates["USD"]);
        Assert.Equal("{bad",File.ReadAllText(FilePath)); Assert.False(File.Exists(Path.Combine(directory,"workspace.json")));
    }
    [Theory]
    [InlineData("{\"Version\":999,\"Snapshots\":[]}")]
    [InlineData("{\"Version\":\"future\",\"Snapshots\":[]}")]
    public void FutureCacheVersionsAreUnavailableAndPreservedOnSave(string text)
    {
        Directory.CreateDirectory(directory); File.WriteAllText(FilePath,text); var cache=new CurrencyRateCache(directory);
        Assert.Null(cache.Load().Book.Latest); Assert.NotNull(cache.Load().Warning);
        Assert.Throws<NotSupportedException>(()=>cache.Save(new(Snapshot(),[]))); Assert.Equal(text,File.ReadAllText(FilePath));
    }
    [Fact]
    public void LockedReplacementKeepsLastGoodRatesAndRemovesTemporaryFiles()
    {
        var cache=new CurrencyRateCache(directory); cache.Save(new(Snapshot(),[]));
        using(var locked=File.Open(FilePath,FileMode.Open,FileAccess.Read,FileShare.Read)) Assert.Throws<IOException>(()=>cache.Save(new(Snapshot(3),[])));
        Assert.Equal(new Rational(2,1),cache.Load().Book.Latest!.Rates["USD"]); Assert.Empty(Directory.GetFiles(directory,"*.tmp"));
    }
    [Fact]
    public void InterruptedStagingAndCompetingWritersCannotGrowTheCacheOrReplaceGoodData()
    {
        var cache=new CurrencyRateCache(directory); cache.Save(new(Snapshot(),[]));
        File.WriteAllText(FilePath+".tmp","partial interrupted response");
        cache.Save(new(Snapshot(3),[])); Assert.False(File.Exists(FilePath+".tmp"));
        using(var locked=File.Open(FilePath+".lock",FileMode.Open,FileAccess.ReadWrite,FileShare.None))
            Assert.Throws<IOException>(()=>cache.Save(new(Snapshot(4),[])));
        Assert.Equal(new Rational(3,1),cache.Load().Book.Latest!.Rates["USD"]);
        Assert.True(Directory.GetFiles(directory).Length<=3); // primary, backup, zero-byte ownership file
    }
    [Fact]
    public void RefreshPolicyHasNoDisabledHiddenComposingOrUnusedWork()
    {
        foreach(var flags in new[]{(false,true,false,true,false),(true,false,false,true,false),(true,true,true,true,false),(true,true,false,false,false),(true,true,false,true,true)})
            Assert.Null(CurrencyRefreshPolicy.Next(flags.Item1,flags.Item2,flags.Item3,flags.Item4,flags.Item5,null,Now,null));
        Assert.Equal(Now,CurrencyRefreshPolicy.Next(true,true,false,true,false,null,Now,null));
        Assert.Equal(Now.AddDays(1),CurrencyRefreshPolicy.Next(true,true,false,true,false,Snapshot(),Now,null));
        Assert.Equal(Now.AddMinutes(15),CurrencyRefreshPolicy.Failed(Now,TimeSpan.FromSeconds(1)));
        Assert.Equal(Now.AddDays(1),CurrencyRefreshPolicy.Failed(Now,TimeSpan.FromDays(5)));
        Assert.Equal(Now.AddHours(1),CurrencyRefreshPolicy.Next(true,true,false,true,false,null,Now,Now.AddHours(1)));
    }
    public void Dispose(){if(Directory.Exists(directory))Directory.Delete(directory,true);}
}
