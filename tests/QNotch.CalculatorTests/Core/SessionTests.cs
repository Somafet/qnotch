using Calc.Core;

namespace Calc.Core.Tests;

public class SessionTests
{
    [Fact]
    public void OnlyChangedLineAndDependentsReevaluate()
    {
        var session = new SheetEvaluationSession();
        session.Evaluate("a=2\na+1\n40+2");
        var result = session.Evaluate("a=3\na+1\n40+2");
        Assert.Equal("4", result[1].Display);
        Assert.Equal(new EvaluationStatistics(1, 2, 1), session.LastStatistics);
        session.Evaluate("a=3\na+1\n40+2");
        Assert.Equal(new EvaluationStatistics(0, 0, 3), session.LastStatistics);
    }
    [Fact]
    public void BindingChangesInvalidateEvenWhenDependencySetIsUnchanged()
    {
        var session = new SheetEvaluationSession();
        Assert.Equal("-1", session.Evaluate("a=1\nb=2\na-b")[2].Display);
        Assert.Equal("1", session.Evaluate("b=1\na=2\na-b")[2].Display);
        session.Evaluate("label 10\n3");
        Assert.NotNull(session.Evaluate("label 10\nlabel=3")[0].Error);
    }
    [Fact]
    public void InsertionTagsCyclesAndFailureTransitionsMatchFreshEvaluation()
    {
        var session = new SheetEvaluationSession();
        var sheets = new[] { "1 #x\n2\nsum #x", "# heading\n1 #x\n2 #x\nsum #x", "a=L2\na", "a=1/0\na", "a=2\na", "hello\nhello+1", "hello=3\nhello+1" };
        foreach (var source in sheets)
        {
            var actual = session.Evaluate(source); var fresh = SheetEvaluator.Evaluate(source);
            Assert.Equal(fresh.Select(r => (r.Display, r.Value, r.Error)), actual.Select(r => (r.Display, r.Value, r.Error)));
            for (var i = 0; i < actual.Count; i++) Assert.Equal(fresh[i].Dependencies, actual[i].Dependencies);
        }
    }
    [Fact]
    public void RandomEditsMatchStatelessEvaluation()
    {
        var random = new Random(881);
        var session = new SheetEvaluationSession();
        var lines = new List<string> { "a=2", "b=3", "a-b", "10 #cost", "sum #cost" };
        var choices = new[] { "a=4", "b=7", "a=1/0", "a-b", "a = L3", "b = a+1", "note", "cost 12 #cost", "sum #cost", "average", "# Heading", "", "50 is what % of 200" };
        for (var edit = 0; edit < 200; edit++)
        {
            var index = random.Next(lines.Count);
            if (random.Next(4) == 0 && lines.Count < 30) lines.Insert(index, choices[random.Next(choices.Length)]);
            else lines[index] = choices[random.Next(choices.Length)];
            var source = string.Join('\n', lines);
            var actual = session.Evaluate(source); var expected = SheetEvaluator.Evaluate(source);
            Assert.Equal(expected.Select(r => (r.Display, r.Value, r.Error)), actual.Select(r => (r.Display, r.Value, r.Error)));
        }
    }
    [Fact]
    public void CancelledRevisionDoesNotReplaceSnapshot()
    {
        var session = new SheetEvaluationSession(); session.Evaluate("a=2\na+1");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Assert.Throws<OperationCanceledException>(() => session.Evaluate("a=5\na+1", cancelled.Token));
        Assert.Equal("3", session.Evaluate("a=2\na+1")[1].Display);
        Assert.Equal(2, session.LastStatistics.ReusedResults);
    }
    [Fact]
    public void RemovingADeclarationDoesNotReuseItsPreviousParseError()
    {
        var session = new SheetEvaluationSession();
        Assert.Equal("10", session.Evaluate("Label 10\nnotes")[0].Display);
        Assert.NotNull(session.Evaluate("Label 10\nLabel=3")[0].Error);
        Assert.Equal("10", session.Evaluate("Label 10\nnotes")[0].Display);
    }
}
