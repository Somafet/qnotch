using Calc.Core;

namespace Calc.Core.Tests;

public class FunctionTests
{
    [Fact]
    public void ConstantsArityAndLibraryLimits()
    {
        Assert.Equal("7", SheetEvaluator.Evaluate("constant()=7\nconstant()")[1].Display);
        var wrong = SheetEvaluator.Evaluate("f(x)=x+1\nf(1,2)")[1];
        Assert.Null(wrong.Value); Assert.Equal("f expects 1 argument(s)", wrong.Error);
        Assert.Throws<ArithmeticException>(() => new FunctionLibrary(Enumerable.Range(0, 129).Select(i => new FunctionDefinition("f" + i, ["x"], "x+1"))));
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("f", Enumerable.Range(0, 17).Select(i => "x" + i).ToArray(), "1")]));
        var result = SheetEvaluator.Evaluate("f(x)=x+1\nf(2)")[1];
        Assert.Contains(result.Explanation, step => step.Assumption == "f(x) = x+1");
    }
    [Fact]
    public void DefinitionCallsForwardAndMultipleArguments()
    {
        var values = SheetEvaluator.Evaluate("f(100)\nf(x) = x * 1.19\narea(w,h)=w*h\narea(3,4)");
        Assert.Equal("119", values[0].Display); Assert.Equal("", values[1].Display);
        Assert.Equal("12", values[3].Display);
    }
    [Fact]
    public void ParametersAreLocalTypedAndNested()
    {
        var values = SheetEvaluator.Evaluate("x=999\ntip(x,p)=x+p\ntwice(x)=tip(x,10%)*2\ntwice(100)\ntip(100,20%)");
        Assert.Equal("220", values[3].Display); Assert.Equal("120", values[4].Display);
        Assert.Empty(values[3].Dependencies);
    }
    [Fact]
    public void ExpandedNestedExplanationsRemainBoundedAndIncludeTheCallDefinition()
    {
        var body = "x" + string.Concat(Enumerable.Repeat("+1", 100));
        var answer = SheetEvaluator.Evaluate($"f(x)={body}\ng(x)=f(x)+f(x)\ng(1)")[2];
        Assert.Null(answer.Error); Assert.Equal("202", answer.Display);
        Assert.InRange(answer.Explanation.Count, 1, 64);
        Assert.Contains(answer.Explanation, step => step.Assumption == "g(x) = f(x)+f(x)");
        Assert.Contains(answer.Explanation, step => step.Assumption?.Contains("limited") == true);
    }
    [Theory]
    [InlineData("f(x)=x+y\nf(2)")]
    [InlineData("f(x)=prev+1\nf(2)")]
    [InlineData("f(x)=f(x)\nf(2)")]
    [InlineData("f(x)=g(x)\ng(x)=f(x)\nf(2)")]
    [InlineData("sqrt(x)=x\nsqrt(2)")]
    [InlineData("abs(x)=x\nabs(-2)")]
    [InlineData("f(x,x)=x\nf(2,3)")]
    [InlineData("f(x)=unknown(x)\nf(2)")]
    public void InvalidScopeOrRecursionHasNoNumericResult(string source)
    {
        var values = SheetEvaluator.Evaluate(source);
        Assert.NotNull(values[0].Error); Assert.Null(values[^1].Value);
    }
    [Fact]
    public void DefinitionAndForgetPersistOnlyOncePerReceipt()
    {
        var define = FunctionUpdate.Prepare("f(x)=x+1", FunctionLibrary.Empty, []);
        var other = FunctionUpdate.Prepare("f(x)=x+2", define.Library, []);
        var oldSheet = new SheetEvaluationSession().EvaluateWithFunctions("f(x)=x+1\nf(10)", other.Library, define.Receipts);
        Assert.Equal("12", oldSheet.Results[1].Display);
        var forget = FunctionUpdate.Prepare("forget f", other.Library, []);
        Assert.Empty(forget.Library.Definitions);
        var recreate = FunctionUpdate.Prepare("f(x)=x+3", forget.Library, []);
        var forgottenSheet = new SheetEvaluationSession().EvaluateWithFunctions("forget f\nf(10)", recreate.Library, forget.Receipts);
        Assert.Equal("13", forgottenSheet.Results[1].Display);
        Assert.False(FunctionUpdate.Prepare("forget f", recreate.Library, forget.Receipts).HasChanges);
    }
    [Fact]
    public void RemovalOfSourceDoesNotForgetAndReaddingIsAnAction()
    {
        var created = FunctionUpdate.Prepare("f(x)=x+1", FunctionLibrary.Empty, []);
        var removed = FunctionUpdate.Prepare("notes", created.Library, created.Receipts);
        Assert.Single(removed.Library.Definitions); Assert.Empty(removed.Receipts);
        var changedElsewhere = FunctionUpdate.Prepare("f(x)=x+2", removed.Library, []);
        var readded = FunctionUpdate.Prepare("f(x)=x+1", changedElsewhere.Library, removed.Receipts);
        Assert.True(readded.HasChanges);
        Assert.Equal("11", new SheetEvaluationSession().EvaluateWithFunctions("f(10)", readded.Library, []).Results[0].Display);
    }
    [Fact]
    public void InvalidDraftRetainsCommittedLibraryButBlocksStaleCalls()
    {
        var good = FunctionUpdate.Prepare("f(x)=x+1", FunctionLibrary.Empty, []);
        var session = new SheetEvaluationSession();
        var bad = session.EvaluateWithFunctions("f(x)=typo\nf(10)", good.Library, good.Receipts);
        Assert.Equal(good.Library.Fingerprint, bad.Functions.Library.Fingerprint);
        Assert.NotNull(bad.Results[0].Error); Assert.Null(bad.Results[1].Value);
        var fixedDraft = session.EvaluateWithFunctions("f(x)=x+2\nf(10)", good.Library, good.Receipts);
        Assert.Null(fixedDraft.Results[0].Error); Assert.Equal("12", fixedDraft.Results[1].Display);
        var committed = session.EvaluateWithFunctions("f(x)=x+2\nf(10)", fixedDraft.Functions.Library, fixedDraft.Functions.Receipts);
        Assert.Null(committed.Results[0].Error); Assert.Equal("12", committed.Results[1].Display);
    }
    [Fact]
    public void LibraryChangesInvalidateCallersEvenWithUnchangedSheet()
    {
        var a = new FunctionLibrary([new("f", ["x"], "x+1")]);
        var b = new FunctionLibrary([new("f", ["x"], "x+2")]);
        var session = new SheetEvaluationSession();
        Assert.Equal("11", session.EvaluateWithFunctions("f(10)", a, []).Results[0].Display);
        Assert.Equal("12", session.EvaluateWithFunctions("f(10)", b, []).Results[0].Display);
    }
    [Fact]
    public void AcyclicExpansionStillHasASharedStepBudget()
    {
        var definitions = Enumerable.Range(0, 20).Select(i => new FunctionDefinition("f" + i, ["x"], i == 0 ? "x+x" : $"f{i-1}(x)+f{i-1}(x)"));
        var library = new FunctionLibrary(definitions);
        var values = new SheetEvaluationSession().EvaluateWithFunctions("f19(1)", library, []).Results;
        Assert.Equal("Expression step limit exceeded", values[0].Error);
    }
    [Fact]
    public void RepeatedFunctionExpansionHasAWholeSheetBudget()
    {
        var definitions = Enumerable.Range(0, 10).Select(i => new FunctionDefinition("f" + i, ["x"], i == 0 ? "x+x" : $"f{i-1}(x)+f{i-1}(x)"));
        var library = new FunctionLibrary(definitions);
        var session = new SheetEvaluationSession();
        Assert.Throws<SheetComputationLimitException>(() => session.EvaluateWithFunctions(string.Join('\n', Enumerable.Repeat("f9(1)", 100)), library, []));
        Assert.Equal("2", session.Evaluate("1+1")[0].Display);
    }
    [Fact]
    public void ReceiptsAndLibraryInputsAreBoundedAndCopied()
    {
        string[] parameters = ["x"];
        var library = new FunctionLibrary([new("f", parameters, "x+1")]); parameters[0] = "bad";
        Assert.Equal("11", new SheetEvaluationSession().EvaluateWithFunctions("f(10)", library, []).Results[0].Display);
        Assert.Throws<FormatException>(() => FunctionUpdate.ValidateReceipts([new("not-a-hash", 1)]));
        var overflow = string.Join('\n', Enumerable.Repeat("forget f", 257));
        Assert.Contains(SheetEvaluator.Evaluate(overflow), r => r.Error is not null);
    }
}
