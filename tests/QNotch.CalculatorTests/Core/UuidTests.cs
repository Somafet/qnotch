using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public sealed class UuidTests
{
    private static Guid Node(int index) => new(index,0,0,new byte[8]);
    private static Guid Uuid(int index) => Guid.Parse("00000000-0000-4000-8000-"+index.ToString("x12"));
    private static StableUuidContext Context(int rows=16)
    {
        var ids=Enumerable.Range(1,rows).Select(Node).ToArray();var sites=new[]{"/0","/2","/3","/4","/0:MAKE/0"};
        return new(ids,ids.SelectMany((id,i)=>sites.Select((site,j)=>new UuidBinding(id,site,Uuid(i*sites.Length+j+1)))));
    }
    private static string Value(string source, StableUuidContext? input=null)
    {var row=SheetEvaluator.Evaluate(source,context:new(){Uuids=input??Context()})[^1];Assert.Null(row.Error);return row.Value!.Value.Text.Value;}
    public static IEnumerable<object[]> OracleCases()
    {
        using var stream=typeof(UuidTests).Assembly.GetManifestResourceStream("Calc.UuidOracle")!;using var d=JsonDocument.Parse(stream);
        return d.RootElement.GetProperty("cases").EnumerateArray().Select(row=>new object[]{row.GetRawText()}).ToArray();
    }
    [Theory,MemberData(nameof(OracleCases))]
    public void IndependentUuidInputAndFormat(string json)
    {
        using var doc=JsonDocument.Parse(json);var row=doc.RootElement;var id=Guid.Parse(row.GetProperty("node").GetString()!);var expected=row.GetProperty("value").GetString()!;
        var value=Guid.Parse(expected);var input=new StableUuidContext([id],[new(id,"/0",value)]);
        Assert.Equal(expected,Value("uuid",input));Assert.Equal(expected,Value("uuid()",input));
        Span<byte> bytes=stackalloc byte[16];value.TryWriteBytes(bytes,bigEndian:true,out _);
        Assert.Equal(row.GetProperty("networkBytes").GetString(),Convert.ToHexStringLower(bytes));Assert.True(StableUuidContext.IsVersion4(value));
    }
    [Fact]
    public void ValuesAreStableDistinctComposableAndScopedByContext()
    {
        var input=Context();var source="a=uuid\nb=uuid()\na\nbase64(a)";
        var rows=SheetEvaluator.Evaluate(source,context:new(){Uuids=input});Assert.All(rows,r=>Assert.Null(r.Error));
        var a=rows[0].Value!.Value.Text.Value;var b=rows[1].Value!.Value.Text.Value;
        Assert.NotEqual(a,b);Assert.Equal(a,rows[2].Value!.Value.Text.Value);Assert.Equal(Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(a)),rows[3].Display);
        Assert.Equal('4',a[14]);Assert.Contains(a[19],"89ab");Assert.True(Guid.TryParseExact(a,"D",out _));Assert.Equal(a,Value("uuid",input));
        Assert.Equal(a,Value("uuid()",input));Assert.NotEqual(a,Value("sha256(uuid)",input));
        var fn="make()=uuid\nmake()\nmake()";var calls=SheetEvaluator.Evaluate(fn,context:new(){Uuids=input});
        Assert.NotEqual(calls[1].Display,calls[2].Display);Assert.Equal(calls[^1].Display,Value(fn,input));
        Assert.NotEqual(a,Value("uuid",new StableUuidContext([Node(99)],[new(Node(99),"/0",Uuid(999))])));
    }
    [Theory]
    [InlineData("uuid(1)")][InlineData("uuid(\"x\")")][InlineData("uuid()+1")][InlineData("uuid in hex")]
    public void InvalidArgumentsAndNumericOperationsFail(string source) => Assert.NotNull(SheetEvaluator.Evaluate(source,context:new(){Uuids=Context()})[^1].Error);
    [Fact]
    public void GenerationRequiresExplicitContextAndInvalidatesOnlyReaders()
    {
        var session=new SheetEvaluationSession();var first=session.Evaluate("uuid\n2+2");Assert.Contains("context",first[0].Error!);
        var next=session.Evaluate("uuid\n2+2",context:new(){Uuids=Context()});Assert.Null(next[0].Error);Assert.Same(first[1],next[1]);
        var again=session.Evaluate("uuid\n2+2",context:new(){Uuids=Context()});Assert.Same(next[0],again[0]);
        var fresh=session.Evaluate("uuid\n2+2",context:new(){Uuids=new StableUuidContext([Node(99),Node(100)],[new(Node(99),"/0",Uuid(999))])});
        Assert.NotEqual(next[0].Display,fresh[0].Display);Assert.Same(next[1],fresh[1]);
    }
    [Theory]
    [InlineData("uuid",true)][InlineData("uuid()",true)][InlineData("text(\"uuid\")",false)][InlineData("# uuid",false)]
    [InlineData("uuid=7\nuuid+1",false)][InlineData("make()=uuid",false)][InlineData("make()=uuid\nmake()",true)]
    [InlineData("uuid(1)",false)]
    public void OnlyActualGenerationEnablesState(string source,bool expected) => Assert.Equal(expected,UuidSyntax.RequiresState(source));
    [Fact]
    public void PendingDiscoveryNeverPublishesPlaceholderValuesOrTraces()
    {
        var ids=Enumerable.Range(1,5).Select(Node).ToArray();var input=new StableUuidContext(ids,[]);var session=new SheetEvaluationSession();
        var pending=session.EvaluateWithFunctions("a=uuid\nb=uuid()\na\nbase64(a)\n2+2",FunctionLibrary.Empty,[],context:new(){Uuids=input});
        Assert.Equal(2,pending.UuidRequests.Count);Assert.All(pending.Results.Take(4),r=>{Assert.Null(r.Value);Assert.Equal("UUID generation pending",r.Error);Assert.Empty(r.Explanation);});Assert.Equal("4",pending.Results[4].Display);
        var bindings=pending.UuidRequests.Select((r,i)=>new UuidBinding(ids[r.Line],r.Site,Uuid(i+1))).ToArray();
        var complete=session.EvaluateWithFunctions("a=uuid\nb=uuid()\na\nbase64(a)\n2+2",FunctionLibrary.Empty,[],context:new(){Uuids=new(ids,bindings)});
        Assert.Empty(complete.UuidRequests);Assert.All(complete.Results,r=>Assert.Null(r.Error));Assert.Equal(complete.Results[0].Display,complete.Results[2].Display);
    }
    [Fact]
    public void SnapshotIsImmutableAndBoundsAndCancellationHold()
    {
        var ids=new[]{Node(1)};var bindings=new[]{new UuidBinding(ids[0],"/0",Uuid(1))};var input=new StableUuidContext(ids,bindings);var value=Value("uuid",input);
        ids[0]=Node(2);bindings[0]=new(Node(2),"/0",Uuid(2));Assert.Equal(value,Value("uuid",input));
        Assert.Throws<ArgumentException>(()=>new StableUuidContext([Guid.Empty],[]));Assert.Throws<ArgumentException>(()=>new StableUuidContext([Node(1),Node(1)],[]));
        Assert.Throws<ArgumentException>(()=>new StableUuidContext([Node(1)],[new(Node(1),"/0",Guid.Empty)]));
        Assert.Throws<ArgumentException>(()=>new StableUuidContext([Node(1)],[new(Node(1),"/0",Uuid(1)),new(Node(1),"/0",Uuid(2))]));
        Assert.Throws<ArgumentException>(()=>new StableUuidContext(Enumerable.Range(1,10001).Select(Node),[]));
        Assert.Throws<ArgumentException>(()=>new StableUuidContext([Node(1)],Enumerable.Range(0,1025).Select(i=>new UuidBinding(Node(1),"/"+i,Uuid(i+1)))));
        using var cancellation=new CancellationTokenSource();cancellation.Cancel();Assert.ThrowsAny<OperationCanceledException>(()=>UuidSyntax.RequiresState("uuid",token:cancellation.Token));
    }
}
