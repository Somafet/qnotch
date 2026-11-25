using System.Numerics;

namespace Calc.Core;

internal sealed class NetworkArithmetic(ExecutionBudget budget, CancellationToken token)
{
    internal const string Convention = "Numeric addresses only; CIDR host bits are normalized; counts describe address space, not reachability. IPv4 /31 uses the point-to-point host model; IPv6 host assignment is not inferred";
    internal static bool IsFunction(string name) => name.ToLowerInvariant() is "subnet" or "contains" or "netmask" or "cidr" or "network" or "firstip" or "lastip" or "ipcount" or "hostcount" or "firsthost" or "lasthost" or "broadcast" or "subnetmask";
    internal static void ValidateArity(string name, int count)
    {
        var expected = name.ToLowerInvariant() is "subnet" or "contains" or "netmask" ? 2 : 1;
        if (count != expected) throw new FormatException($"{name} expects {expected} argument(s)");
    }
    private void Step() => budget.Step(token);
    private static IpAddressValue Address(SheetValue value) => value.Kind == SheetValueKind.Network && value.Network.Form == NetworkForm.Address ? value.Network.Address : throw new ArithmeticException("Expected an IP address literal/value");
    private static SubnetInfo Subnet(SheetValue value) => value.Kind == SheetValueKind.Network && value.Network.Form == NetworkForm.Subnet ? value.Network.Subnet! : throw new ArithmeticException("Expected a CIDR subnet");
    private static int SmallInteger(SheetValue value, int maximum)
    {
        var number = IntegerArithmetic.Require(value);
        if (number < 0 || number > maximum) throw new ArithmeticException("Integer is outside the network parameter's range");
        return (int)number;
    }
    private static int Prefix(SheetValue value, int width)
    {
        if (value.Kind == SheetValueKind.Network && value.Network.Form == NetworkForm.Prefix)
        {
            if (value.Network.Address.BitWidth != width) throw new ArithmeticException("Prefix and address families must match; use an explicit numeric length to change family");
            return value.Network.Prefix!.Value;
        }
        return SmallInteger(value, width);
    }
    internal SheetValue Literal(string text) { Step(); return new(new NetworkValue(IpAddressValue.Parse(text))); }
    internal SheetValue PrefixMask(int prefix, int family) => Function("netmask", [new(new Rational(prefix, 1)), new(new Rational(family, 1))]);
    internal SheetValue Attach(SheetValue address, SheetValue prefix)
    { Step(); var ip = Address(address); return new(new NetworkValue(new SubnetInfo(ip, Prefix(prefix, ip.BitWidth)))); }
    internal SheetValue Contains(SheetValue address, SheetValue subnet)
    { Step(); return new(new NetworkValue(Subnet(subnet), Address(address))); }
    internal SheetValue Function(string name, SheetValue[] args)
    {
        Step(); ValidateArity(name, args.Length);
        switch (name.ToLowerInvariant())
        {
            case "subnet": return Attach(args[0], args[1]);
            case "contains": return Contains(args[1], args[0]);
            case "netmask":
                var family = SmallInteger(args[1], 6); if (family is not (4 or 6)) throw new ArithmeticException("Address family must be 4 or 6");
                var width = family == 4 ? 32 : 128; var prefix = Prefix(args[0], width);
                return new(new NetworkValue(new IpAddressValue(((BigInteger.One << prefix) - 1) << (width - prefix), width)));
            case "subnetmask":
                if (args[0].Kind == SheetValueKind.Network && args[0].Network.Form == NetworkForm.Prefix) return new(new NetworkValue(args[0].Network.Address));
                return new(new NetworkValue(Subnet(args[0]).Mask));
            case "cidr":
                if (args[0].Kind == SheetValueKind.Network && args[0].Network.Form == NetworkForm.Prefix) return args[0];
                if (args[0].Kind == SheetValueKind.Network && args[0].Network.Form == NetworkForm.Subnet)
                { var subnet = args[0].Network.Subnet!; return new(new NetworkValue(subnet.Mask, subnet.Prefix)); }
                var mask = Address(args[0]); var count = 0; var zero = false;
                for (var bit = mask.BitWidth - 1; bit >= 0; bit--)
                {
                    Step(); var one = (mask.Number & (BigInteger.One << bit)) != 0;
                    if (one && zero) throw new ArithmeticException("Netmask must have contiguous leading one bits");
                    if (one) count++; else zero = true;
                }
                return new(new NetworkValue(mask, count));
            default:
                var info = Subnet(args[0]);
                return name.ToLowerInvariant() switch
                {
                    "network" or "firstip" => new(new NetworkValue(info.Network)), "lastip" => new(new NetworkValue(info.Last)),
                    "ipcount" => new(new Rational(info.AddressCount, 1)),
                    "hostcount" => info.HostCount is { } hosts ? new(new Rational(hosts, 1)) : throw new ArithmeticException("A general IPv6 usable-host count is not inferred"),
                    "firsthost" => new(new NetworkValue(info.FirstHost ?? throw new ArithmeticException("A general IPv6 usable-host range is not inferred"))),
                    "lasthost" => new(new NetworkValue(info.LastHost ?? throw new ArithmeticException("A general IPv6 usable-host range is not inferred"))),
                    "broadcast" => new(new NetworkValue(info.Broadcast ?? throw new ArithmeticException("This subnet model has no directed broadcast"))),
                    _ => throw new FormatException("Unknown network function")
                };
        }
    }
}
