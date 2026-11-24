using System.Globalization;
using System.Numerics;
using Calc.Core;

namespace Calc.Core.Tests;

public class PrimeTests
{
    private static LineResult Last(string source) => SheetEvaluator.Evaluate(source)[^1];
    private static SheetValue Value(string source) { var result = Last(source); Assert.Null(result.Error); return result.Value!.Value; }
    private static BigInteger Exact(string source) => Value(source).Number.Exact.Rational.Numerator;
    /// <summary>Multiplies a displayed factorization back together, so the check does not depend on how the factors were found.</summary>
    private static BigInteger Multiply(string product) => product.Split(" × ").Aggregate(BigInteger.One, (total, part) =>
    {
        var pieces = part.Split('^');
        return total * BigInteger.Pow(BigInteger.Parse(pieces[0], CultureInfo.InvariantCulture), pieces.Length == 2 ? int.Parse(pieces[1], CultureInfo.InvariantCulture) : 1);
    });

    [Theory]
    [InlineData("isprime(91)", "not prime: 7 × 13")]
    [InlineData("isprime(97)", "prime")]
    public void PublishedReferenceExamples(string source, string display)
    { var value = Value(source); Assert.Equal(SheetValueKind.Prime, value.Kind); Assert.Equal(display, value.Display); Assert.Equal(display, value.CopyText); }

    [Fact]
    public void SmallIntegersAgreeWithAnIndependentSieve()
    {
        const int limit = 1200;
        var composite = new bool[limit];
        for (var p = 2; p * p < limit; p++) if (!composite[p]) for (var m = p * p; m < limit; m += p) composite[m] = true;
        for (var n = 2; n < limit; n++)
        {
            var isPrime = Value($"isprime({n})");
            Assert.Equal(!composite[n], isPrime.Prime.IsPrime); Assert.True(isPrime.Prime.IsProven);
            Assert.Equal(composite[n] ? "not prime: " + Value($"factor({n})").Display : "prime", isPrime.Display);
            Assert.Equal((BigInteger)n, Multiply(Value($"factor({n})").Display));
        }
    }
    [Theory]
    [InlineData("0")]
    [InlineData("1")]
    public void ZeroAndOneAreNotPrime(string n) => Assert.Equal("not prime", Value($"isprime({n})").Display);
    [Theory]
    [InlineData("7919")] // the 1000th prime
    [InlineData("104729")] // the 10000th prime
    [InlineData("2^13-1")]
    [InlineData("2^31-1")]
    [InlineData("2^61-1")] // Mersenne primes below 2^64
    [InlineData("2^32-5")] // largest prime below 2^32
    [InlineData("2^64-59")] // largest prime below 2^64
    [InlineData("18446744073709551557")]
    [InlineData("2^16+1")] // Fermat prime
    public void KnownPrimesBelow2To64AreProven(string n)
    {
        var value = Value($"isprime({n})");
        Assert.Equal("prime", value.Display); Assert.True(value.Prime.IsProven); Assert.True(value.Prime.IsPrime);
        Assert.Contains("proven", Last($"isprime({n})").Explanation[^1].Assumption);
    }
    [Theory]
    [InlineData("2^89-1")]
    [InlineData("2^107-1")]
    [InlineData("2^127-1")]
    [InlineData("2^521-1")]
    [InlineData("2^607-1")]
    [InlineData("2^1024-105")] // largest prime below 2^1024
    public void PublishedPrimesAboveTheBoundAreProbablePrimesAndSaySo(string n)
    {
        var value = Value($"isprime({n})");
        Assert.Equal("probable prime", value.Display); Assert.True(value.Prime.IsPrime); Assert.False(value.Prime.IsProven);
        Assert.Contains("not a proof", Last($"isprime({n})").Explanation[^1].Assumption);
    }
    [Theory]
    [InlineData("561")]
    [InlineData("1105")]
    [InlineData("1729")]
    [InlineData("2465")]
    [InlineData("2821")]
    [InlineData("6601")]
    [InlineData("8911")]
    [InlineData("41041")]
    [InlineData("825265")]
    [InlineData("321197185")] // Carmichael numbers fool Fermat tests for every coprime base.
    [InlineData("2047")]
    [InlineData("1373653")]
    [InlineData("25326001")]
    [InlineData("3215031751")]
    [InlineData("2152302898747")]
    [InlineData("3474749660383")]
    [InlineData("341550071728321")]
    [InlineData("3825123056546413051")] // Smallest strong pseudoprimes to the first 1 through 9 prime bases.
    [InlineData("2^11-1")]
    [InlineData("2^23-1")]
    [InlineData("2^29-1")]
    [InlineData("2^67-1")] // Cole's 1903 factorization
    [InlineData("2^32+1")] // Euler's factor of F5
    [InlineData("2^64-1")]
    public void CompositesThatFoolWeakerTestsAreFactoredCompletely(string source)
    {
        var n = Exact(source); var value = Value($"isprime({source})");
        Assert.False(value.Prime.IsPrime); Assert.True(value.Prime.IsProven); Assert.StartsWith("not prime: ", value.Display);
        var product = value.Display["not prime: ".Length..];
        Assert.Equal(n, Multiply(product));
        Assert.All(product.Split(" × "), part => Assert.StartsWith("prime", Value($"isprime({part.Split('^')[0]})").Display));
        Assert.Equal(product, Value($"factor({source})").Display);
    }
    [Theory]
    [InlineData("318665857834031151167461", "399165290221", "798330580441")] // psi12, Sorenson and Webster
    [InlineData("3317044064679887385961981", "1287836182261", "2575672364521")] // psi13: the first value above the deterministic bound
    public void TheStrongestPublishedPseudoprimesAreCaught(string n, string p, string q)
    {
        Assert.Equal(BigInteger.Parse(n, CultureInfo.InvariantCulture), BigInteger.Parse(p, CultureInfo.InvariantCulture) * BigInteger.Parse(q, CultureInfo.InvariantCulture));
        var value = Value($"isprime({n})");
        Assert.False(value.Prime.IsPrime); Assert.StartsWith("not prime", value.Display);
    }
    [Fact]
    public void TheDeterministicBoundIsWhereProofEnds()
    {
        var bound = BigInteger.Parse("3317044064679887385961981", CultureInfo.InvariantCulture);
        var below = SheetEvaluator.Evaluate($"p = prevprime({bound})\nisprime(p)"); var above = SheetEvaluator.Evaluate($"q = nextprime({bound})\nisprime(q)");
        Assert.True(below[0].Value!.Value.Number.Exact.Rational.Numerator < bound); Assert.True(above[0].Value!.Value.Number.Exact.Rational.Numerator > bound);
        Assert.Equal("prime", below[1].Display); Assert.True(below[1].Value!.Value.Prime.IsProven);
        Assert.Equal("probable prime", above[1].Display); Assert.False(above[1].Value!.Value.Prime.IsProven);
    }
    [Theory]
    [InlineData("factor(360)", "2^3 × 3^2 × 5")]
    [InlineData("factor(97)", "97")]
    [InlineData("factor(1)", "1")]
    [InlineData("factor(2^10)", "2^10")]
    [InlineData("factor(2^64-1)", "3 × 5 × 17 × 257 × 641 × 65537 × 6700417")] // F0 through F5, with Euler's split of F5
    [InlineData("factor(2^64+1)", "274177 × 67280421310721")] // Landry's factorization of F6
    [InlineData("factor(4294967279 * 4294967291)", "4294967279 × 4294967291")] // both just below 2^32, the hardest shape below 2^64
    [InlineData("factor(1000003^2)", "1000003^2")]
    [InlineData("factor(1000003^2 * 1000033)", "1000003^2 × 1000033")]
    [InlineData("factor(2^2 * 3 * 1000003^3)", "2^2 × 3 × 1000003^3")]
    public void FactorizationsMatchPublishedResults(string source, string display)
    {
        var value = Value(source);
        Assert.Equal(display, value.Display); Assert.Equal(display, value.CopyText); Assert.Equal(value.Prime.Number, Multiply(display));
    }
    [Theory]
    [InlineData("nextprime(0)", "2")]
    [InlineData("nextprime(1)", "2")]
    [InlineData("nextprime(2)", "3")]
    [InlineData("nextprime(3)", "5")]
    [InlineData("nextprime(90)", "97")]
    [InlineData("nextprime(113)", "127")] // first prime gap of 14
    [InlineData("prevprime(3)", "2")]
    [InlineData("prevprime(4)", "3")]
    [InlineData("prevprime(5)", "3")]
    [InlineData("prevprime(100)", "97")]
    [InlineData("prevprime(127)", "113")]
    [InlineData("nextprime(2^64)", "18446744073709551629")] // 2^64 + 13
    [InlineData("prevprime(2^64)", "18446744073709551557")] // 2^64 - 59
    public void NeighbouringPrimesMatchPublishedGaps(string source, string display)
    { var value = Value(source); Assert.Equal(SheetValueKind.Number, value.Kind); Assert.Equal(display, value.Display); }
    [Theory]
    [InlineData("isprime(-7)", "nonnegative")]
    [InlineData("nextprime(-1)", "nonnegative")]
    [InlineData("factor(-12)", "nonnegative")]
    [InlineData("factor(0)", "positive")]
    [InlineData("prevprime(2)", "above 2")]
    [InlineData("prevprime(0)", "above 2")]
    [InlineData("isprime(7/2)", "exact integer")]
    [InlineData("isprime(2.5)", "exact integer")]
    [InlineData("isprime(sqrt(2))", "exact integer")]
    [InlineData("isprime(pi)", "exact integer")]
    [InlineData("isprime(sin(1))", "exact integer")]
    [InlineData("factor(1 + 0 * pi)", "exact integer")]
    [InlineData("isprime(5 m)", "exact integer")]
    [InlineData("factor(5 kg)", "exact integer")]
    [InlineData("isprime(10%)", "exact integer")]
    [InlineData("isprime($5)", "exact integer")]
    [InlineData("isprime(1 + i)", "exact integer")]
    [InlineData("isprime(2^1024)", "below 2^1024")]
    [InlineData("factor(2^1024 * 3)", "below 2^1024")]
    [InlineData("isprime(1, 2)", "expects 1")]
    [InlineData("isprime(7) + 1", "not numbers")]
    [InlineData("-isprime(7)", "not numbers")]
    [InlineData("factor(12) * 2", "not numbers")]
    public void InvalidInputsFailExplicitly(string source, string message)
    {
        var result = Last(source);
        Assert.Null(result.Value); Assert.Contains(message, result.Error);
    }
    [Fact]
    public void AdmissibleIntegerFormsAreAccepted()
    {
        Assert.Equal("prime", Value("isprime(0x61)").Display); Assert.Equal("prime", Value("isprime(7.0)").Display);
        Assert.Equal("prime", Value("n = 96 + 1\nisprime(n)").Display);
    }
    [Fact]
    public void ExhaustedFactoringIsAClearFailureThatNeverHidesCompositeness()
    {
        // 2^128 + 1 = 59649589127497217 × 5704689200685129054721 (Morrison and Brillhart); the small factor is beyond the rho budget.
        var failed = Last("factor(2^128+1)");
        Assert.Null(failed.Value); Assert.Contains("exceeded the computation budget", failed.Error);
        var composite = Last("isprime(2^128+1)");
        Assert.Equal("not prime", composite.Display); Assert.False(composite.Value!.Value.Prime.IsPrime);
        Assert.Contains("exceeded the budget", composite.Explanation[^1].Assumption);
        Assert.Contains("found 3 × 5", Last("factor(15 * (2^128+1))").Error);
    }
    [Fact]
    public void ResultsAreDeterministic()
    {
        Assert.Equal(Value("factor(4294967279 * 4294967291)"), Value("factor(4294967279 * 4294967291)"));
        Assert.Equal(Value("isprime(2^127-1)"), Value("isprime(2^127-1)"));
    }
    [Fact]
    public void AggregatesSkipPrimeLinesWithoutCrashing()
    {
        var results = SheetEvaluator.Evaluate("isprime(7)\nfactor(12)\n5\n6\nsum");
        Assert.Equal("11", results[4].Display); Assert.Contains("prime", results[4].Explanation[^1].Assumption);
        Assert.Equal("5", Last("isprime(7) #t\nfactor(12) #t\n5 #t\nsum #t").Display);
    }
    [Fact]
    public void NewNamesLeaveVariablesAndLabelsAlone()
    {
        Assert.Equal("6", Last("factor = 3\nfactor * 2").Display);
        Assert.Equal("3", Value("arg = 3\narg").Display); Assert.Equal("4", Value("re 4").Display);
        var plain = SheetEvaluator.Evaluate("factor of safety")[0]; Assert.Null(plain.Value);
    }
    [Fact]
    public void SavedFunctionsParseCanonicalizeAndReload()
    {
        var update = FunctionUpdate.Prepare("check(n) = isprime(n)\nabove(n) = nextprime(n) + 1", FunctionLibrary.Empty, []);
        Assert.Equal(FunctionLibrary.LatestCatalogVersion, update.Library.MinimumCatalogVersion);
        var reloaded = new FunctionLibrary(update.Library.Definitions);
        Assert.Equal(update.Library.Fingerprint, reloaded.Fingerprint);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("check(91)\nabove(90)", reloaded, []).Results;
        Assert.Equal(new[] { "not prime: 7 × 13", "98" }, results.Select(result => result.Display));
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("isprime", ["n"], "n")]));
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("bad", ["n"], "factor(n, 2)")]));
    }
    [Fact]
    public void CancellationPropagates()
    {
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => SheetEvaluator.Evaluate("factor(2^128+1)", cancelled.Token));
    }
}
