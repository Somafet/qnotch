using Calc.Core;

namespace Calc.Core.Tests;

public class VariableRenameTests
{
    [Fact]
    public void RenamesDefinitionsAndReferencesButNotCommentsQuotesTagsOrHeadings()
    {
        const string source = "# rate\nrate = 5% // rate\n\"rate\" 100 + rate #rate\nrates = 2\nrate * rates\nRATE";
        Assert.Equal("# rate\nfee = 5% // rate\n\"rate\" 100 + fee #rate\nrates = 2\nfee * rates\nfee",
            VariableRename.Apply(source, "rate", "fee"));
    }
    [Fact]
    public void MultiWordNamesMatchGreedilyAndAcrossSpacing()
    {
        const string source = "rent = 10\nmonthly rent = 1200\nmonthly  rent * 12 + rent";
        Assert.Equal("rent = 10\nhousing = 1200\nhousing * 12 + rent", VariableRename.Apply(source, "monthly rent", "housing"));
        Assert.Equal("cost = 10\nmonthly rent = 1200\nmonthly  rent * 12 + cost", VariableRename.Apply(source, "rent", "cost"));
    }
    [Fact]
    public void FindsTheVariableAtTheCaretOrExactSelection()
    {
        const string source = "a = 1\nmonthly rent = 2\nmonthly rent + a2 + 3a";
        var line = source.LastIndexOf('\n') + 1;
        Assert.Equal("monthly rent", VariableRename.Find(source, line + 3, 0)?.Name);
        Assert.Equal("monthly rent", VariableRename.Find(source, line + 12, 0)?.Name); // caret right after the name
        Assert.Equal("monthly rent", VariableRename.Find(source, line, 13)?.Name); // trailing space is trimmed
        Assert.Null(VariableRename.Find(source, line, 7)); // part of a longer name
        Assert.Null(VariableRename.Find(source, source.IndexOf("a2"), 0)); // a different word
        Assert.Equal("a", VariableRename.Find(source, source.Length, 0)?.Name); // implicit product "3a"
        Assert.Equal(new SourceSpan(0, 1), VariableRename.Find(source, 0, 0)?.Span);
        Assert.Null(VariableRename.Find("1 + 2", 0, 0));
    }
    [Fact]
    public void RejectsInvalidReservedAndTakenNamesButAllowsCaseChanges()
    {
        const string source = "a = 1\nb = 2\na + b";
        Assert.Equal(VariableRename.Problem.Taken, VariableRename.Check(source, "a", "B"));
        Assert.Equal(VariableRename.Problem.Invalid, VariableRename.Check(source, "a", "1x"));
        Assert.Equal(VariableRename.Problem.Invalid, VariableRename.Check(source, "a", "sum"));
        Assert.Equal(VariableRename.Problem.Invalid, VariableRename.Check(source, "a", "L2"));
        Assert.Equal(VariableRename.Problem.Invalid, VariableRename.Check(source, "a", " "));
        Assert.Equal("A = 1\nb = 2\nA + b", VariableRename.Apply(source, "a", "A"));
        Assert.Equal("total cost = 1\nb = 2\ntotal cost + b", VariableRename.Apply(source, "a", "  total   cost "));
        Assert.Null(VariableRename.Apply(source, "a", "b"));
    }
    [Fact]
    public void FunctionParametersAreLeftAlone()
    {
        const string source = "x = 3\ntwice(x) = x * 2\ntwice(x)";
        Assert.Equal("y = 3\ntwice(x) = x * 2\ntwice(y)", VariableRename.Apply(source, "x", "y"));
    }
    [Fact]
    public void RenamedSheetEvaluatesTheSame()
    {
        const string source = "price = 40\ntax rate = 25%\nprice + tax rate\r\nprice * 2";
        var renamed = VariableRename.Apply(source, "price", "net price")!;
        Assert.Equal("net price = 40\ntax rate = 25%\nnet price + tax rate\r\nnet price * 2", renamed);
        Assert.Equal(new SheetEvaluationSession().Evaluate(source).Select(r => r.Display), new SheetEvaluationSession().Evaluate(renamed).Select(r => r.Display));
    }
}
