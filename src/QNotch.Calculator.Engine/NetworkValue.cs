using System.Globalization;
using System.Numerics;

namespace Calc.Core;

public enum NetworkForm { Address, Subnet, Prefix, Membership }

/// <summary>Bounded subnet facts. Address counts are calculated, never enumerated.</summary>
public sealed record SubnetInfo
{
    public IpAddressValue Input { get; }
    public int Prefix { get; }
    public IpAddressValue Network { get; }
    public IpAddressValue Last { get; }
    public IpAddressValue Mask { get; }
    public BigInteger AddressCount { get; }
    public IpAddressValue? Broadcast { get; }
    public BigInteger? HostCount { get; }
    public IpAddressValue? FirstHost { get; }
    public IpAddressValue? LastHost { get; }
    public string Cidr => Network.Text + "/" + Prefix.ToString(CultureInfo.InvariantCulture);
    public string Range => Network.Text + " – " + Last.Text;
    public string HostAssumption => Input.BitWidth == 128 ? "IPv6 has no broadcast; address allocation is not a general usable-host count. Anycast, reserved interface IDs, routing and assignment policy are not inferred" :
        Prefix == 31 ? "IPv4 /31 point-to-point model (RFC 3021): both endpoints are host slots; no directed broadcast. Link capability and actual assignment are not inferred" :
        Prefix == 32 ? "IPv4 /32 single-address host route; no directed broadcast. Actual assignment is not inferred" :
        "Conventional IPv4 host slots exclude network and directed broadcast. Reserved/special addresses are not filtered; routability and assignment are not inferred";
    public string Summary => "Mask: " + Mask.Text + "; /" + Prefix + "\n" + AddressCount.ToString(CultureInfo.InvariantCulture) + " addresses" +
        (HostCount is { } count ? "; " + count.ToString(CultureInfo.InvariantCulture) + " host slots\nHosts: " + FirstHost!.Text + " – " + LastHost!.Text : "\nIPv6 host assignment not inferred");
    public string Details => "IPv" + (Input.BitWidth == 32 ? "4" : "6") + " subnet: " + Cidr + "\nInput: " + Input.Text +
        (Input.Number != Network.Number ? " (host bits normalized)" : "") + "\nRange: " + Range + "\n" + Summary +
        (Broadcast is not null ? "\nBroadcast: " + Broadcast.Text : "") + "\n" + HostAssumption;
    internal SubnetInfo(IpAddressValue input, int prefix)
    {
        if (prefix < 0 || prefix > input.BitWidth) throw new ArithmeticException("Prefix is outside the address family's bit width");
        Input = input; Prefix = prefix;
        var hostBits = input.BitWidth - prefix;
        var wildcard = (BigInteger.One << hostBits) - 1;
        Mask = new(((BigInteger.One << input.BitWidth) - 1) ^ wildcard, input.BitWidth);
        Network = new(input.Number & Mask.Number, input.BitWidth); Last = new(Network.Number | wildcard, input.BitWidth);
        AddressCount = BigInteger.One << hostBits;
        if (input.BitWidth == 32)
        {
            Broadcast = prefix < 31 ? Last : null;
            HostCount = prefix < 31 ? AddressCount - 2 : AddressCount;
            FirstHost = new(Network.Number + (prefix < 31 ? 1 : 0), 32);
            LastHost = new(Last.Number - (prefix < 31 ? 1 : 0), 32);
        }
    }
    public bool Contains(IpAddressValue candidate) => candidate.BitWidth == Input.BitWidth && candidate.Number >= Network.Number && candidate.Number <= Last.Number;
}

/// <summary>IP addresses, subnet ranges, prefix lengths and membership remain distinct from numeric quantities.</summary>
public sealed record NetworkValue
{
    public NetworkForm Form { get; }
    public IpAddressValue Address { get; }
    public SubnetInfo? Subnet { get; }
    public int? Prefix { get; }
    public IpAddressValue? Candidate { get; }
    public bool? IsMember => Form == NetworkForm.Membership ? Subnet!.Contains(Candidate!) : null;
    public string Display => Form switch { NetworkForm.Subnet => Subnet!.Range, NetworkForm.Prefix => "/" + Prefix!.Value.ToString(CultureInfo.InvariantCulture), NetworkForm.Membership => IsMember == true ? "yes" : "no", _ => Address.Text };
    public string CopyText => Form switch { NetworkForm.Subnet => "(" + Subnet!.Input.Text + "/" + Subnet.Prefix + ")", NetworkForm.Prefix => "cidr(" + Address.Text + ")", NetworkForm.Membership => "contains(" + Subnet!.Input.Text + "/" + Subnet.Prefix + "," + Candidate!.Text + ")", _ => Address.Text };
    public string Details => Form switch
    {
        NetworkForm.Subnet => Subnet!.Details,
        NetworkForm.Membership => Candidate!.Text + (IsMember == true ? " belongs to " : " does not belong to ") + Subnet!.Cidr +
            (Candidate.BitWidth != Address.BitWidth ? " (different address families)" : "") + "\n" + Subnet.Details,
        NetworkForm.Prefix => "Contiguous IPv" + (Address.BitWidth == 32 ? "4" : "6") + " netmask: " + Address.Text + "; prefix /" + Prefix,
        _ => "IPv" + (Address.BitWidth == 32 ? "4" : "6") + " address: " + Address.Text
    };
    internal NetworkValue(IpAddressValue address) { Form = NetworkForm.Address; Address = address; }
    internal NetworkValue(SubnetInfo subnet, IpAddressValue? candidate = null)
    { Subnet = subnet; Address = subnet.Input; Prefix = subnet.Prefix; Candidate = candidate; Form = candidate is null ? NetworkForm.Subnet : NetworkForm.Membership; }
    internal NetworkValue(IpAddressValue mask, int prefix) { Form = NetworkForm.Prefix; Address = mask; Prefix = prefix; }
}
