using Calc.Core;
using Calc.Documents;

namespace Calc.Documents.Tests;

public class CarriedResultsTests
{
    private static LineResult[] Results(int count) => Enumerable.Range(0, count).Select(i => new LineResult(i, null, "r" + i)).ToArray();
    private static string?[] Shown(IReadOnlyList<LineResult> carried) => carried.Select(r => r.Error).ToArray();

    [Theory]
    [InlineData("a\nb\nc", "a\nbx\nc", new[] { "r0", null, "r2" })]                 // typing on a line
    [InlineData("a\nb", "a\n\nb", new[] { "r0", null, "r1" })]                      // Return at the end of a line
    [InlineData("a\nb\nc", "a\nc", new[] { "r0", "r2" })]                           // a line deleted
    [InlineData("a\nb", "x\na\nb", new[] { null, "r0", "r1" })]                     // a line added above
    [InlineData("a\nb\nc", "z\nb\ny", new string?[] { null, null, null })]          // edits at both ends make one block
    [InlineData("a\r\nb\r\nc", "a\r\nb2\r\nc", new[] { "r0", null, "r2" })]         // Windows line breaks
    public void LinesAroundAnEditKeepTheirResults(string evaluated, string source, string?[] expected)
    {
        var results = Results(new SourceLineMap(evaluated).Count);
        var carried = CarriedResults.Map(results, evaluated, source);
        Assert.Equal(expected, Shown(carried));
        Assert.Equal(new SourceLineMap(source).Count, carried.Count);
        Assert.All(carried.Where(r => r.Error is null), r => Assert.Equal("", r.Display));
    }

    [Fact]
    public void UnchangedLinesKeepTheSameResultObjects()
    {
        var results = Results(3);
        var carried = CarriedResults.Map(results, "a\nb\nc", "a\nb!\nc");
        Assert.Same(results[0], carried[0]);
        Assert.Same(results[2], carried[2]);
    }

    [Fact]
    public void SameTextReturnsTheResultsAsTheyAre()
    {
        var results = Results(2);
        Assert.Same(results, CarriedResults.Map(results, "a\nb", "a\nb"));
    }

    [Fact]
    public void NothingIsCarriedWithoutMatchingResults()
    {
        Assert.Empty(CarriedResults.Map([], "", "a"));
        Assert.Empty(CarriedResults.Map(Results(1), "a\nb", "a\nbc")); // results do not belong to that text
    }

    [Fact]
    public void RepeatedLinesAreNotMatchedTwice()
    {
        // Prefix and suffix may not overlap: "x" added between two equal lines leaves one edited line.
        var carried = CarriedResults.Map(Results(2), "a\na", "a\nx\na");
        Assert.Equal(new[] { "r0", null, "r1" }, Shown(carried));
        carried = CarriedResults.Map(Results(2), "a\na", "a\na\na");
        Assert.Equal(new string?[] { null, null, null }, Shown(carried));
    }

    [Theory]
    [InlineData("uuid()\nb", "uuid()\nuuid()\nb", new[] { null, null, "r1" })]  // a copy pasted above or below: either line may be new
    [InlineData("a\na\nb", "a\nb", new[] { null, "r2" })]                        // one of two equal lines deleted
    [InlineData("x\na\nb", "x\na\na\nb", new[] { "r0", null, null, "r2" })]      // the ambiguity stops at a different line
    [InlineData("uuid()\n2d6\nend", "uuid()\n2d6\nuuid()\n2d6\nend", new[] { null, null, null, null, "r2" })] // a two-line block pasted above its copy
    public void EqualNeighboursNeverCarryAResultOntoTheWrongLine(string evaluated, string source, string?[] expected)
    {
        var carried = CarriedResults.Map(Results(new SourceLineMap(evaluated).Count), evaluated, source);
        Assert.Equal(expected, Shown(carried));
    }
}
