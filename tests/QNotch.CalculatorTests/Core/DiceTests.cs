using Calc.Core;

namespace Calc.Core.Tests;

public sealed class DiceTests
{
    private static Guid Node(int index) => new(index, 0, 0, new byte[8]);
    private static StableUuidContext Rolls(int lines, params (int Line, string Formula, int[] Faces)[] rolls) =>
        new(Enumerable.Range(1, lines).Select(Node), [], rolls.Select(r => new DiceBinding(Node(r.Line + 1), r.Formula, r.Faces)));
    private static IReadOnlyList<LineResult> Evaluate(string source, StableUuidContext? rolls = null) =>
        SheetEvaluator.Evaluate(source, context: new() { Uuids = rolls });

    [Theory]
    [InlineData("10d6+4", "10d6+4", 10)]
    [InlineData("2d6+1d8", "2d6+1d8", 3)]
    [InlineData("d20", "1d20", 1)]
    [InlineData("1D20 + 5", "1d20+5", 1)]
    [InlineData("d%", "1d100", 1)]
    [InlineData("2d20kh1", "2d20kh1", 2)]
    [InlineData("2d20k1", "2d20kh1", 2)]
    [InlineData("2d20kl1-1", "2d20kl1-1", 2)]
    [InlineData("4d6dl1", "4d6dl1", 4)]
    [InlineData("-1d4 + 2", "-1d4+2", 1)]
    [InlineData("crit 2d6+3", "crit 2d6+3", 4)]
    [InlineData("crit! 2d6+3", "crit! 2d6+3", 2)]
    [InlineData("CRIT!2d6", "crit! 2d6", 2)]
    [InlineData("Smite crit! 2d8 + 4d8 + 3", "crit! 2d8+4d8+3", 6)]
    [InlineData("Fireball 8d6", "8d6", 8)]
    [InlineData("Longsword crit 1d8 + 3", "crit 1d8+3", 2)]
    public void ParsesNotation(string text, string notation, int dice)
    {
        var formula = DiceSyntax.TryParse(text);
        Assert.NotNull(formula); Assert.Equal(notation, formula.Notation); Assert.Equal(dice, formula.Sides.Count);
    }

    [Theory]
    [InlineData("2d6x")] [InlineData("2d")] [InlineData("d")] [InlineData("4")] [InlineData("2d6 3")] [InlineData("4d6d1")]
    [InlineData("2d20kh3")] [InlineData("4d6dl4")] [InlineData("0d6")] [InlineData("2d0")] [InlineData("1001d6")] [InlineData("1d10001")]
    [InlineData("I rolled 2d6 today")] [InlineData("2d6*2")] [InlineData("crit")] [InlineData("crit 4")] [InlineData("crit!")] [InlineData("crit2d6")] [InlineData("crit 600d6")] [InlineData("2d6+1000001")]
    public void RejectsNonDice(string text) => Assert.Null(DiceSyntax.TryParse(text));

    [Fact]
    public void SheetVariablesShadowCountlessDice()
    {
        Assert.Null(DiceSyntax.TryParse("d6 + 2", new HashSet<string>(["d6"], StringComparer.OrdinalIgnoreCase)));
        Assert.Null(DiceSyntax.TryParse("d%", new HashSet<string>(["d"], StringComparer.OrdinalIgnoreCase)));
        Assert.NotNull(DiceSyntax.TryParse("2d6", new HashSet<string>(["d6", "d"], StringComparer.OrdinalIgnoreCase)));
        var rows = Evaluate("d6 = 4\nd6 + 2\nd = 3\nd%");
        Assert.Equal("6", rows[1].Display); Assert.Equal("3%", rows[3].Display);
    }

    [Fact]
    public void UnrolledLinesPreviewTheirRangeAndHaveNoValue()
    {
        var rows = Evaluate("10d6+4\nd20\ncrit 2d6+3\n4d6dl1\nx = 2d6\nx + 1\nsum\n\ncrit! 2d6+3");
        Assert.Equal("14–64", rows[0].Display); Assert.Null(rows[0].Value); Assert.Null(rows[0].Error);
        Assert.Contains("average 39", rows[0].Explanation[^1].Assumption);
        Assert.Equal("1–20", rows[1].Pending); Assert.Contains("average 10.5", rows[1].Explanation[^1].Assumption);
        // A crit rolls the dice twice (4d6+3); a crunchy crit adds their maximum to one roll (12 + 2d6 + 3).
        Assert.Equal("7–27", rows[2].Pending); Assert.Contains("average 17", rows[2].Explanation[^1].Assumption);
        Assert.Equal("17–27", rows[8].Pending); Assert.Contains("average 22", rows[8].Explanation[^1].Assumption);
        Assert.Equal("3–18", rows[3].Pending); Assert.Contains("average ≈12.24", rows[3].Explanation[^1].Assumption);
        Assert.Equal("L5 not rolled yet", rows[5].Error);
        Assert.NotNull(rows[6].Error);
    }

    [Fact]
    public void RolledLinesTotalTheirFacesAndFeedDependents()
    {
        var rolls = Rolls(8, (0, "10d6+4", [1, 4, 5, 3, 1, 2, 2, 5, 3, 5]), (1, "2d6+1d8", [6, 4, 3]), (2, "2d20kh1+5", [7, 15]),
            (3, "4d6dl1", [5, 2, 5, 2]), (4, "crit! 2d6+3", [3, 6]), (6, "crit 2d6+1d8+3", [3, 6, 1, 2, 5, 4]), (7, "crit 2d20kh1", [4, 9, 12, 2]));
        var rows = Evaluate("10d6+4\n2d6 + 1d8\nattack = 2d20kh1+5\n4d6dl1\ncrit! 2d6+3\nattack * 2\ncrit 2d6 + 1d8 + 3\ncrit 2d20kh1", rolls);
        Assert.Equal(["35", "13", "20", "12", "24", "40", "24", "21"], rows.Select(r => r.Display));
        Assert.Contains("[1, 4, 5, 3, 1, 2, 2, 5, 3, 5] + 4", rows[0].Explanation[^1].Assumption);
        Assert.Contains("[(7), 15] + 5", rows[2].Explanation[^1].Assumption);
        Assert.Contains("[5, 2, 5, (2)]", rows[3].Explanation[^1].Assumption);
        Assert.Contains("12 + [3, 6] + 3", rows[4].Explanation[^1].Assumption);
        // Each group's second roll follows it: 2d6 twice, then 1d8 twice.
        Assert.Contains("[3, 6] + [1, 2] + [5] + [4] + 3", rows[6].Explanation[^1].Assumption);
        Assert.Contains("[(4), 9] + [12, (2)]", rows[7].Explanation[^1].Assumption);
    }

    [Fact]
    public void StaleOrMismatchedRollsAreIgnored()
    {
        // A roll for another formula, or with impossible faces, leaves the line unrolled.
        Assert.Equal("2–16", Evaluate("2d8", Rolls(1, (0, "2d6", [3, 4])))[0].Display);
        Assert.Throws<ArgumentException>(() => Rolls(1, (0, "2d6", [3, 7])));
        Assert.Throws<ArgumentException>(() => Rolls(1, (0, "2d6", [3])));
        Assert.Throws<ArgumentException>(() => Rolls(1, (0, "2D6", [3, 4])));
    }

    [Fact]
    public void CacheFollowsRollChanges()
    {
        var session = new SheetEvaluationSession();
        var first = session.EvaluateWithFunctions("2d6\nL1 + 1", FunctionLibrary.Empty, [], context: new() { Uuids = Rolls(2, (0, "2d6", [1, 2])) });
        Assert.Equal("4", first.Results[1].Display);
        var second = session.EvaluateWithFunctions("2d6\nL1 + 1", FunctionLibrary.Empty, [], context: new() { Uuids = Rolls(2, (0, "2d6", [6, 6])) });
        Assert.Equal("13", second.Results[1].Display);
        var unrolled = session.EvaluateWithFunctions("2d6\nL1 + 1", FunctionLibrary.Empty, [], context: new() { Uuids = Rolls(2) });
        Assert.Equal("2–12", unrolled.Results[0].Display);
    }

    [Fact]
    public void FacesExposeKeptDiceForPresentation()
    {
        var formula = DiceSyntax.TryParse("2d20kh1+1d4")!;
        Assert.Equal([new DieFace(20, 3, false), new DieFace(20, 17, true), new DieFace(4, 2, true)], DiceSyntax.Faces(formula, [3, 17, 2]));
        // Ties keep the earlier die.
        Assert.Equal([true, false], DiceSyntax.Faces(DiceSyntax.TryParse("2d6kh1")!, [4, 4]).Select(f => f.Kept));
    }

    [Fact]
    public void IdentityIgnoresLabelsSpacingAndCaseButNotDice()
    {
        Assert.Equal(UuidSyntax.ExpressionIdentity("2d6 + 3"), UuidSyntax.ExpressionIdentity("Hit 2D6+3"));
        Assert.Equal(UuidSyntax.ExpressionIdentity("dmg = 2d6+3"), UuidSyntax.ExpressionIdentity("damage = 2d6+3 // sword"));
        Assert.NotEqual(UuidSyntax.ExpressionIdentity("2d6+3"), UuidSyntax.ExpressionIdentity("2d8+3"));
    }
}
