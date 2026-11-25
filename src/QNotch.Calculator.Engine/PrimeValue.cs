using System.Numerics;

namespace Calc.Core;

/// <summary>Result of isprime or factor. It reads as a verdict or a product and is not a number. IsProven is false above the deterministic bound.</summary>
public sealed record PrimeValue(BigInteger Number, bool IsPrime, bool IsProven, string Display)
{
    public string CopyText => Display;
    public override string ToString() => Display;
}
