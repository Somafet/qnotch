using System.Globalization;
using System.Numerics;

namespace Calc.Core;

/// <summary>Deterministic, bounded primality and factorization. No randomness: Pollard rho uses fixed seeds, so results repeat exactly.</summary>
internal sealed class PrimeArithmetic(ExactArithmetic math, ExecutionBudget budget, CancellationToken token)
{
    internal const int MaxBits = 1024;
    internal const string NotNumeric = "Primality and factorization results are not numbers";
    private const string Proven = "Deterministic Miller-Rabin with the first 13 prime bases, proven below 3317044064679887385961981 (Sorenson and Webster)";
    private const string Probable = "13 Miller-Rabin bases plus a strong Lucas test (Baillie-PSW family); no counterexample is known, but this is not a proof";
    private const string Factoring = "trial division below 1000, then deterministic Pollard rho within the computation budget";
    private const int RhoBudget = 8192, RhoBatch = 64, RhoPolynomials = 16;
    private static readonly int[] Bases = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41];
    private static readonly BigInteger DeterministicBound = BigInteger.Parse("3317044064679887385961981", CultureInfo.InvariantCulture);
    private static readonly int[] SmallPrimes = Enumerable.Range(2, 998).Where(n => Enumerable.Range(2, n - 2).TakeWhile(d => d * d <= n).All(d => n % d != 0)).ToArray();
    private int rhoRemaining;
    internal static bool IsFunction(string name) => name.ToLowerInvariant() is "isprime" or "factor" or "nextprime" or "prevprime";
    internal static void ValidateArity(string name, int count)
    { if (count != 1) throw new FormatException($"{name} expects 1 argument(s)"); }
    private void Step() => budget.Step(token);
    private void Charge(int steps) { for (var i = 0; i < steps; i++) Step(); }
    private static BigInteger Input(string name, SheetValue value)
    {
        if (!IntegerArithmetic.IsExactInteger(value)) throw new ArithmeticException(name + " expects an exact integer without units");
        var number = IntegerArithmetic.Require(value);
        if (number.Sign < 0) throw new ArithmeticException(name + " expects a nonnegative integer");
        return number.GetBitLength() <= MaxBits ? number : throw new ArithmeticException(name + " supports integers below 2^1024");
    }
    private bool StrongProbablePrime(BigInteger n, BigInteger candidate, BigInteger odd, int twos)
    {
        var witness = candidate % n; if (witness.IsZero) return true;
        var last = n - 1; Charge(1 + (int)(n.GetBitLength() / 64));
        var x = BigInteger.ModPow(witness, odd, n);
        if (x.IsOne || x == last) return true;
        for (var i = 1; i < twos; i++)
        {
            Step(); x = x * x % n;
            if (x == last) return true;
            if (x.IsOne) return false;
        }
        return false;
    }
    private int Jacobi(BigInteger a, BigInteger n)
    {
        a %= n; if (a.Sign < 0) a += n;
        var result = 1;
        while (!a.IsZero)
        {
            Step();
            var twos = (int)BigInteger.TrailingZeroCount(a); a >>= twos;
            if ((twos & 1) != 0 && (n % 8) is var r && (r == 3 || r == 5)) result = -result;
            (a, n) = (n, a);
            if (a % 4 == 3 && n % 4 == 3) result = -result;
            a %= n;
        }
        return n.IsOne ? result : 0;
    }
    /// <summary>Strong Lucas probable-prime test with Selfridge parameters (P = 1, Q = (1 - D)/4). n is odd and not a perfect square.</summary>
    private bool StrongLucas(BigInteger n)
    {
        var d = new BigInteger(5);
        while (Jacobi(d, n) != -1) { Step(); d = d.Sign > 0 ? -(d + 2) : -d + 2; }
        var q = (1 - d) / 4; var twos = (int)BigInteger.TrailingZeroCount(n + 1); var odd = (n + 1) >> twos;
        BigInteger Mod(BigInteger value) { value %= n; return value.Sign < 0 ? value + n : value; }
        BigInteger Halve(BigInteger value) => (value.IsEven ? value : value + n) >> 1;
        BigInteger u = 1, v = 1, power = Mod(q);
        for (var bit = (int)odd.GetBitLength() - 2; bit >= 0; bit--)
        {
            Step(); u = Mod(u * v); v = Mod(v * v - 2 * power); power = Mod(power * power);
            if (((odd >> bit) & 1).IsOne) { (u, v) = (Halve(Mod(u + v)), Halve(Mod(d * u + v))); power = Mod(power * q); }
        }
        if (u.IsZero) return true;
        for (var r = 0; r < twos; r++)
        {
            Step(); if (v.IsZero) return true;
            v = Mod(v * v - 2 * power); power = Mod(power * power);
        }
        return false;
    }
    private bool IsPrime(BigInteger n)
    {
        if (n < 2) return false;
        foreach (var prime in SmallPrimes)
        {
            Step();
            if (n == prime) return true;
            if ((n % prime).IsZero) return false;
        }
        if (n < 1009 * 1009) return true; // Below 1009^2 a survivor of trial division is prime.
        var twos = (int)BigInteger.TrailingZeroCount(n - 1); var odd = (n - 1) >> twos;
        foreach (var candidate in Bases) if (!StrongProbablePrime(n, candidate, odd, twos)) return false;
        if (n < DeterministicBound) return true;
        var root = math.IntegerRoot(n);
        return root * root != n && StrongLucas(n);
    }
    /// <summary>Pays for one batch of modular multiplications, scaled by operand size. False when the factoring allowance is gone.</summary>
    private bool Spend(BigInteger n)
    {
        var steps = 1 + (int)(n.GetBitLength() / 256);
        if ((rhoRemaining -= steps) < 0) return false;
        Charge(steps); return true;
    }
    /// <summary>Brent's cycle variant of Pollard rho with fixed polynomials; null when the budget ends without a split.</summary>
    private BigInteger? Rho(BigInteger n)
    {
        for (var c = BigInteger.One; c <= RhoPolynomials; c++)
        {
            BigInteger y = 2, x = 2, saved = 2, product = 1, divisor = 1; long cycle = 1;
            BigInteger Next(BigInteger value) => (value * value + c) % n;
            do
            {
                x = y;
                for (long done = 0; done < cycle; done += RhoBatch)
                {
                    if (!Spend(n)) return null;
                    for (long i = 0; i < Math.Min(RhoBatch, cycle - done); i++) y = Next(y);
                }
                for (long done = 0; done < cycle && divisor.IsOne; done += RhoBatch)
                {
                    saved = y;
                    if (!Spend(n)) return null;
                    for (long i = 0; i < Math.Min(RhoBatch, cycle - done); i++) { y = Next(y); product = product * BigInteger.Abs(x - y) % n; }
                    divisor = BigInteger.GreatestCommonDivisor(product, n);
                }
                cycle *= 2;
            } while (divisor.IsOne);
            if (divisor == n)
                do { Step(); saved = Next(saved); divisor = BigInteger.GreatestCommonDivisor(BigInteger.Abs(x - saved), n); } while (divisor.IsOne);
            if (divisor != n) return divisor;
        }
        return null;
    }
    /// <summary>Prime powers in ascending order and the part that resisted factoring, 1 when complete.</summary>
    private (SortedDictionary<BigInteger, int> Factors, BigInteger Cofactor) Factorize(BigInteger n)
    {
        var factors = new SortedDictionary<BigInteger, int>(); var cofactor = BigInteger.One; rhoRemaining = RhoBudget;
        void Add(BigInteger prime) => factors[prime] = factors.GetValueOrDefault(prime) + 1;
        foreach (var prime in SmallPrimes)
        {
            Step();
            while ((n % prime).IsZero) { Step(); Add(prime); n /= prime; }
            if (n.IsOne) return (factors, cofactor);
        }
        var pending = new Stack<BigInteger>(); pending.Push(n);
        while (pending.TryPop(out var part))
        {
            Step();
            if (part.IsOne) continue;
            if (IsPrime(part)) { Add(part); continue; }
            var root = math.IntegerRoot(part);
            if (root * root == part) { pending.Push(root); pending.Push(root); continue; }
            if (Rho(part) is { } divisor) { pending.Push(divisor); pending.Push(part / divisor); }
            else cofactor *= part;
        }
        return (factors, cofactor);
    }
    private static string Product(SortedDictionary<BigInteger, int> factors) => string.Join(" × ", factors.Select(pair =>
        pair.Key.ToString(CultureInfo.InvariantCulture) + (pair.Value == 1 ? "" : "^" + pair.Value.ToString(CultureInfo.InvariantCulture))));
    private static string Test(BigInteger n) => n < DeterministicBound ? Proven : Probable;
    private (SheetValue Value, string Evidence) IsPrimeResult(BigInteger n)
    {
        var prime = IsPrime(n); var proven = n < DeterministicBound;
        if (prime) return (new(new PrimeValue(n, true, proven, proven ? "prime" : "probable prime")), Test(n));
        if (n < 2) return (new(new PrimeValue(n, false, true, "not prime")), "0 and 1 are not prime by definition");
        var (factors, cofactor) = Factorize(n); var complete = cofactor.IsOne;
        var evidence = Test(n) + "; " + Factoring + (complete ? "" : "; composite by the strong test, complete factorization exceeded the budget");
        return (new(new PrimeValue(n, false, true, complete ? "not prime: " + Product(factors) : "not prime")), evidence);
    }
    private (SheetValue Value, string Evidence) FactorResult(BigInteger n)
    {
        if (n.IsZero) throw new ArithmeticException("factor expects a positive integer");
        if (n.IsOne) return (new(new PrimeValue(n, false, true, "1")), "1 has no prime factors");
        var (factors, cofactor) = Factorize(n);
        if (!cofactor.IsOne) throw new ArithmeticException("Factorization exceeded the computation budget" + (factors.Count == 0 ? "" : "; found " + Product(factors) + " and an unfactored composite"));
        var proven = factors.Keys.All(prime => prime < DeterministicBound);
        return (new(new PrimeValue(n, factors.Count == 1 && factors.First().Value == 1, proven, Product(factors))), Factoring + "; " + (proven ? Proven : Probable));
    }
    private (SheetValue Value, string Evidence) Next(BigInteger n)
    {
        if (n < 2) return (new(new Rational(2, 1)), Proven);
        var candidate = (n + 1) | 1;
        while (true) { Step(); if (IsPrime(candidate)) return (new(new Rational(candidate, 1)), Test(candidate)); candidate += 2; }
    }
    private (SheetValue Value, string Evidence) Previous(BigInteger n)
    {
        if (n <= 2) throw new ArithmeticException("prevprime expects an integer above 2");
        if (n == 3) return (new(new Rational(2, 1)), Proven);
        var candidate = (n - 2) | 1;
        while (true) { Step(); if (IsPrime(candidate)) return (new(new Rational(candidate, 1)), Test(candidate)); candidate -= 2; }
    }
    internal (SheetValue Value, string Evidence) Function(string name, SheetValue[] args)
    {
        ValidateArity(name, args.Length);
        var n = Input(name, args[0]);
        return name.ToLowerInvariant() switch { "isprime" => IsPrimeResult(n), "factor" => FactorResult(n), "nextprime" => Next(n), _ => Previous(n) };
    }
}
