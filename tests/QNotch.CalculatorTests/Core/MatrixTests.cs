using System.Globalization;
using System.Numerics;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class MatrixTests
{
    private static LineResult Last(string source)
    { var result = SheetEvaluator.Evaluate(source)[^1]; Assert.Null(result.Error); return result; }
    private static Rational Fraction(string text)
    { var parts = text.Split('/'); return new(BigInteger.Parse(parts[0], CultureInfo.InvariantCulture), parts.Length == 1 ? BigInteger.One : BigInteger.Parse(parts[1], CultureInfo.InvariantCulture)); }
    public static IEnumerable<object[]> OracleCases()
    {
        using var stream = typeof(MatrixTests).Assembly.GetManifestResourceStream("Calc.MatrixOracle")!;
        using var doc = JsonDocument.Parse(stream);
        return doc.RootElement.GetProperty("cases").EnumerateArray().Select(item => new object[] { item.GetRawText() }).ToArray();
    }
    [Theory, MemberData(nameof(OracleCases))]
    public void IndependentPermutationAndCofactorOracle(string json)
    {
        using var doc = JsonDocument.Parse(json); var item = doc.RootElement;
        var value = Last(item.GetProperty("source").GetString()!).Value!.Value;
        var expected = item.GetProperty("values").EnumerateArray().Select(row => row.EnumerateArray().Select(x => Fraction(x.GetString()!)).ToArray()).ToArray();
        switch (item.GetProperty("kind").GetString())
        {
            case "number": Assert.Equal(SheetValueKind.Number, value.Kind); Assert.Equal(expected[0][0], value.Scalar); break;
            case "list": Assert.Equal(SheetValueKind.List, value.Kind); Assert.Equal(expected[0], value.List.Values.Select(x => x.Scalar)); break;
            default:
                Assert.Equal(SheetValueKind.Matrix, value.Kind); Assert.Equal(expected.Length, value.Matrix.RowCount); Assert.Equal(expected[0].Length, value.Matrix.ColumnCount);
                for (var r = 0; r < expected.Length; r++) for (var c = 0; c < expected[r].Length; c++) Assert.Equal(expected[r][c], value.Matrix[r, c].Scalar);
                break;
        }
    }
    [Theory]
    [InlineData("det([[1,2],[3,4]])", "-2")]
    [InlineData("inverse([[1,2],[3,4]])", "[[-2, 1], [1.5, -0.5]]")]
    [InlineData("[[1,2],[3,4]]*[[5],[6]]", "[[17], [39]]")]
    [InlineData("dot([1,2,3],[4,5,6])", "32")]
    [InlineData("cross([1,0,0],[0,1,0])", "[0, 0, 1]")]
    [InlineData("norm([3,4])", "5")]
    [InlineData("norm([1,1])", "sqrt(2)")]
    [InlineData("transpose([[1,2,3],[4,5,6]])", "[[1, 4], [2, 5], [3, 6]]")]
    [InlineData("trace([[1,2],[3,4]])", "5")]
    [InlineData("[[0,1],[2,3]]*[5,6]", "[6, 28]")]
    [InlineData("[5,6]*[[0,1],[2,3]]", "[12, 23]")]
    [InlineData("[[1,2]]+[[3,4]]", "[[4, 6]]")]
    [InlineData("[1,2]-[3,4]", "[-2, -2]")]
    [InlineData("-[1,2]*2", "[-2, -4]")]
    [InlineData("2*[[1,2]]", "[[2, 4]]")]
    [InlineData("[[1,2]]/2", "[[0.5, 1]]")]
    [InlineData("[[1,2]]*20%", "[[0.2, 0.4]]")]
    [InlineData("inverse([[3]]) to 3 decimals", "[[0.333]]")]
    [InlineData("[1/3,2/3] to 2 decimals", "[0.33, 0.67]")]
    [InlineData("det([[0,1],[1,0]])", "-1")]
    [InlineData("det([[1,2],[2,4]])", "0")]
    [InlineData("inv([[2]])", "[[0.5]]")]
    [InlineData("determinant([[2]])", "2")]
    [InlineData("det([[sqrt(2),1],[1,sqrt(2)]])", "1")]
    [InlineData("x=[[sqrt(2),1],[1,sqrt(2)]]\nx*inverse(x)", "[[1, 0], [0, 1]]")]
    [InlineData("4\n5\n[[1,2],[3,4]]\n[1,2]\nsum", "9")]
    [InlineData("f(x)=det(x)\nf([[1,2],[3,4]])", "-2")]
    [InlineData("f(x,y)=[[x,1],[1,y]]\ntrace(f(2,3))", "5")]
    public void PublishedExamplesAndTypedCompositions(string source, string expected) => Assert.Equal(expected, Last(source).Display);

    [Theory]
    [InlineData("[[]]")][InlineData("[[1],[2,3]]")][InlineData("[[1],2]")][InlineData("[[[1]]]")]
    [InlineData("[[1 USD]]")][InlineData("[[today]]")][InlineData("[[1%,2%]]")][InlineData("[[1 m,2 s]]")]
    [InlineData("[[0 °C]]")][InlineData("det([1,2])")][InlineData("det([[1,2]])")][InlineData("inverse([[1,2],[2,4]])")]
    [InlineData("inverse([[0]])")][InlineData("trace([[1,2]])")][InlineData("norm([])")][InlineData("norm([1 USD])")]
    [InlineData("dot([1,2],[3])")][InlineData("cross([1,2],[3,4])")][InlineData("dot([1 m,2 s],[3,4])")]
    [InlineData("[1,2]*[3,4]")][InlineData("[[1,2]]*[[3,4]]")][InlineData("[[1,2]]+[1,2]")]
    [InlineData("[[1,2]]+[[1],[2]]")][InlineData("[[1]]+1")][InlineData("1/[[1]]")][InlineData("[[1]]/0")]
    [InlineData("[[1]]^2")][InlineData("[[1]]!")][InlineData("[[1]]%")][InlineData("sum([[1,2]])")]
    [InlineData("transpose()")][InlineData("dot([1],[1],[1])")][InlineData("norm([1%])")]
    public void InvalidShapesTypesAndDomainsAreExplicit(string source) => Assert.NotNull(SheetEvaluator.Evaluate(source)[^1].Error);

    [Fact]
    public void UnitsUseCanonicalMagnitudesWithoutLosingTheDisplayBasis()
    {
        var det = Last("det([[1 m,200 cm],[3 m,400 cm]])").Value!.Value.Number;
        Assert.Equal(new Rational(-2, 1), det.Exact.Rational); Assert.Equal(new Dimension(2,0,0,0,0,0,0,0), det.Unit!.Dimension);
        var inv = Last("inverse([[2 cm]])").Value!.Value.Matrix[0, 0];
        Assert.Equal(new Rational(50, 1), inv.Exact.Rational); Assert.Equal(new Rational(100, 1), inv.Unit!.Factor);
        Assert.Equal("5 m", Last("norm([300 cm,4 m]) in m").Display);
        Assert.Equal("11 m^2", Last("dot([1 m,2 m],[3 m,4 m])").Display);
        var identity = Last("a=[[1 m,2 m],[3 m,4 m]]\na*inverse(a)").Value!.Value.Matrix;
        Assert.Null(identity[0, 0].Unit); Assert.Equal(new Rational(1, 1), identity[0, 0].Scalar);
    }
    [Fact]
    public void ImmutableMatricesCompareByCellsAndKeepCompleteCopies()
    {
        var row = new SheetList([new(new Rational(1, 1)), new(new Rational(2, 1))]);
        var input = new[] { row }; var matrix = new SheetMatrix(input); input[0] = new SheetList([new(new Rational(9, 1))]);
        Assert.Equal(new Rational(2, 1), matrix[0, 1].Scalar); Assert.Equal(matrix, new SheetMatrix([row]));
        Assert.Throws<NotSupportedException>(() => ((IList<SheetList>)matrix.Rows)[0] = row);
        var literal = "[" + string.Join(',', Enumerable.Repeat("[" + string.Join(',', Enumerable.Range(100001, 12)) + "]", 12)) + "]";
        var value = Last(literal).Value!.Value;
        Assert.True(value.Display.Length <= 516); Assert.Contains('…', value.Display); Assert.DoesNotContain('…', value.CopyText);
        Assert.Equal(143, value.CopyText.Count(c => c == ',')); Assert.Equal(value.Matrix, Last(value.CopyText).Value!.Value.Matrix);
    }
    [Fact]
    public void LargeSupportedShapesAndExpressionSheetLimitsAreEnforced()
    {
        string Identity(int n) => "[" + string.Join(',', Enumerable.Range(0, n).Select(r => "[" + string.Join(',', Enumerable.Range(0, n).Select(c => r == c ? "1" : "0")) + "]")) + "]";
        var identity = Identity(12); Assert.Equal(Last(identity).Value, Last("inverse(" + identity + ")").Value);
        Assert.NotNull(SheetEvaluator.Evaluate(Identity(13))[0].Error);
        var dense = "[" + string.Join(',', Enumerable.Range(0, 12).Select(r => "[" + string.Join(',', Enumerable.Range(0, 12).Select(c => (r == c ? 20 : 1 + (r + c) % 3).ToString(CultureInfo.InvariantCulture))) + "]")) + "]";
        Assert.Null(Last("inverse(" + dense + ")").Error);
        // Calls share the sheet budget; neither rational arithmetic nor repeated saved calls bypasses it.
        var source = "a=" + dense + "\n" + string.Join('\n', Enumerable.Repeat("inverse(a)", 100));
        Assert.Throws<SheetComputationLimitException>(() => SheetEvaluator.Evaluate(source));
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate("inverse(" + dense + ")", cancelled.Token));
    }
    [Fact]
    public void CacheDependenciesAndSavedFunctionsKeepMatricesTypedAndStatic()
    {
        var session = new SheetEvaluationSession(); const string source = "x=1\na=[[x,2],[3,4]]\ndet(a)\n7";
        session.EvaluateWithFunctions(source, FunctionLibrary.Empty, []);
        var changed = session.EvaluateWithFunctions(source.Replace("x=1", "x=2"), FunctionLibrary.Empty, []);
        Assert.Equal("2", changed.Results[2].Display); Assert.Equal(1, session.LastStatistics.ParsedLines); Assert.Equal(1, session.LastStatistics.ReusedResults);
        var future = session.EvaluateWithFunctions(source.Replace("x=1", "x=2"), FunctionLibrary.Empty, [], context: new EvaluationContext(new DateOnly(2040, 1, 1), DateTimeOffset.UtcNow));
        Assert.Equal(4, session.LastStatistics.ReusedResults); Assert.False(future.UsesCurrentDate); Assert.False(future.UsesCurrentInstant); Assert.False(future.UsesCurrencyRates);
        var library = new FunctionLibrary([new("linear", ["a", "v"], "a*v"), new("reverse", ["a"], "inverse(a)")]);
        var computed = session.EvaluateWithFunctions("linear(reverse([[1,2],[3,4]]),[5,6])", library, []);
        Assert.Equal("[-4, 4.5]", computed.Results[0].Display);
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("norm", ["x"], "x")]));
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("wrong", ["x"], "dot(x)")]));
        Assert.All(SheetEvaluator.Evaluate("a=[[b]]\nb=det(a)"), result => Assert.Equal("Circular dependency", result.Error));
    }
    [Fact]
    public void ApproximationProvenanceSurvivesAllOutputs()
    {
        // Existing long-term finance intentionally produces a represented approximation.
        const string setup = "x=fv(1%/12,1200,0,1)\na=[[1,x],[0,1]]\n";
        Assert.True(Last(setup + "a").Value!.Value.Matrix.IsApproximate);
        foreach (var operation in new[] { "det(a)", "trace(a)", "norm([1,x*0])", "dot([x,1],[0,1])" })
        { var result = Last(setup + operation); Assert.True(result.Value!.Value.Number.IsApproximate); Assert.Contains(result.Explanation, step => step.Assumption?.Contains("Approximate") == true); }
        Assert.True(Last(setup + "inverse(a)").Value!.Value.Matrix.IsApproximate);
    }
    [Fact]
    public void SeededAlgebraicIdentitiesHoldExactlyInBothMultiplicationOrders()
    {
        var random = new Random(80826);
        for (var trial = 0; trial < 40; trial++)
        {
            var n = 2 + trial % 4;
            // Strict diagonal dominance guarantees nonsingularity without consulting Calc's determinant.
            string Matrix() => "[" + string.Join(',', Enumerable.Range(0, n).Select(r => "[" + string.Join(',', Enumerable.Range(0, n).Select(c => (r == c ? 50 + random.Next(10) : random.Next(-4, 5)).ToString(CultureInfo.InvariantCulture))) + "]")) + "]";
            var a = Matrix(); var b = Matrix(); var setup = "a=" + a + "\nb=" + b + "\n";
            var identity = Last(setup + "a*inverse(a)").Value!.Value.Matrix;
            for (var r = 0; r < n; r++) for (var c = 0; c < n; c++) Assert.Equal(new Rational(r == c ? 1 : 0, 1), identity[r, c].Scalar);
            Assert.Equal(identity, Last(setup + "inverse(a)*a").Value!.Value.Matrix);
            Assert.Equal("0", Last(setup + "det(a*b)-det(a)*det(b)").Display);
            Assert.Equal("0", Last(setup + "det(transpose(a))-det(a)").Display);
            Assert.Equal("0", Last(setup + "trace(a+b)-trace(a)-trace(b)").Display);
            Assert.Equal(Last(setup + "transpose(a*b)").Value, Last(setup + "transpose(b)*transpose(a)").Value);
            Assert.Equal(Last(setup + "inverse(a*b)").Value, Last(setup + "inverse(b)*inverse(a)").Value);
        }
        for (var trial = 0; trial < 40; trial++)
        {
            string Vector() => "[" + string.Join(',', Enumerable.Range(0, 3).Select(_ => random.Next(-9, 10))) + "]";
            var setup = "u=" + Vector() + "\nv=" + Vector() + "\n";
            Assert.Equal("0", Last(setup + "dot(cross(u,v),u)").Display);
            Assert.Equal("0", Last(setup + "dot(cross(u,v),v)").Display);
            Assert.Equal(Last(setup + "cross(u,v)").Value, Last(setup + "-cross(v,u)").Value);
            Assert.Equal("0", Last(setup + "norm(cross(u,v))^2-dot(u,u)*dot(v,v)+dot(u,v)^2").Display);
        }
    }
    [Fact]
    public void InverseDoesNotComputeAnUnneededOverflowingDeterminant()
    {
        var diagonal = "[" + string.Join(',', Enumerable.Range(0, 8).Select(r => "[" + string.Join(',', Enumerable.Range(0, 8).Select(c => r == c ? "10^200" : "0")) + "]")) + "]";
        var inverse = Last("inverse(" + diagonal + ")").Value!.Value.Matrix;
        Assert.Equal(new Rational(1, BigInteger.Pow(10, 200)), inverse[0, 0].Scalar);
        Assert.NotNull(SheetEvaluator.Evaluate("det(" + diagonal + ")")[0].Error);
    }
}
