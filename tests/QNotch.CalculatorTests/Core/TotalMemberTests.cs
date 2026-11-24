using Calc.Core;

namespace Calc.Core.Tests;

public class TotalMemberTests
{
    private static IReadOnlyList<int> Members(string source) =>
        new SheetEvaluationSession().EvaluateWithFunctions(source, FunctionLibrary.Empty, [], default, new EvaluationContext()).TotalMembers;

    [Fact]
    public void MembersSpanBlocksAndMatchWhatAnUntaggedSumReadsInEachBlock()
    {
        const string sheet = "# A\n1\n2\nsum\n\n# B\nx = 3\nbad +\n// comment\nf(n) = n*2\nsum #t\naverage";
        Assert.Equal([1, 2, 6, 7], Members(sheet));
        var results = SheetEvaluator.Evaluate(sheet);
        Assert.Equal([1, 2], results[3].Dependencies); // Block A's own sum reads the same members as the sheet list restricted to A.
    }

    [Fact]
    public void PresentationAndHolidayDeclarationsAreNotMembers()
    {
        Assert.Equal([1], Members("holidays = [24 dec]\n5\nplot sin(x) from 0 to 1"));
    }
}
