using System.Globalization;
using System.Numerics;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class NetworkTests
{
    private static LineResult Last(string source)
    {
        var result = SheetEvaluator.Evaluate(source)[^1]; Assert.Null(result.Error); Assert.NotNull(result.Value); return result;
    }
    public static IEnumerable<object[]> OracleCases()
    {
        using var stream = typeof(NetworkTests).Assembly.GetManifestResourceStream("Calc.NetworkOracle")!;
        using var json = JsonDocument.Parse(stream);
        return json.RootElement.GetProperty("cases").EnumerateArray().Select(row => new object[] { row.GetRawText() }).ToArray();
    }
    [Theory, MemberData(nameof(OracleCases))]
    public void IndependentIpAddressOracle(string json)
    {
        using var parsed = JsonDocument.Parse(json); var row = parsed.RootElement;
        var source = row.GetProperty("input").GetString() + "/" + row.GetProperty("prefix").GetInt32();
        var result = Last(source).Value!.Value.Network; var info = result.Subnet!;
        Assert.Equal(row.GetProperty("cidr").GetString(), info.Cidr);
        Assert.Equal(row.GetProperty("first").GetString(), info.Network.Text);
        Assert.Equal(row.GetProperty("last").GetString(), info.Last.Text);
        Assert.Equal(row.GetProperty("mask").GetString(), info.Mask.Text);
        Assert.Equal(BigInteger.Parse(row.GetProperty("addresses").GetString()!, CultureInfo.InvariantCulture), info.AddressCount);
        Assert.Equal(row.GetProperty("hosts").GetString(), info.HostCount?.ToString(CultureInfo.InvariantCulture));
        Assert.Equal(row.GetProperty("firstHost").GetString(), info.FirstHost?.Text);
        Assert.Equal(row.GetProperty("lastHost").GetString(), info.LastHost?.Text);
        Assert.Equal(row.GetProperty("broadcast").GetString(), info.Broadcast?.Text);
        Assert.Equal(result, Last(result.CopyText).Value!.Value.Network);
        Assert.Equal(info.Mask.Text, Last($"netmask({info.Prefix},{row.GetProperty("family").GetInt32()})").Display);
        var reversed = Last(info.Mask.Text + " in cidr").Value!.Value.Network;
        Assert.Equal(info.Prefix, reversed.Prefix); Assert.Equal(reversed, Last(reversed.CopyText).Value!.Value.Network);
        foreach (var check in row.GetProperty("membership").EnumerateArray())
        {
            var member = Last(check.GetProperty("address").GetString() + " in (" + source + ")").Value!.Value.Network;
            Assert.Equal(check.GetProperty("member").GetBoolean(), member.IsMember);
            Assert.Equal(member, Last(member.CopyText).Value!.Value.Network);
        }
    }
    [Theory]
    [InlineData("192.168.1.0/24", "192.168.1.0 – 192.168.1.255")]
    [InlineData("10.0.0.5 in 10.0.0.0/8", "yes")]
    [InlineData("11.0.0.5 in 10.0.0.0/8", "no")]
    [InlineData("/24 mask", "255.255.255.0")]
    [InlineData("255.255.255.0 in cidr", "/24")]
    [InlineData("192.168.1.17/24", "192.168.1.0 – 192.168.1.255")]
    [InlineData("hostcount(192.0.2.0/30)", "2")]
    [InlineData("hostcount(192.0.2.0/31)", "2")]
    [InlineData("hostcount(192.0.2.1/32)", "1")]
    [InlineData("ipcount(::/0)", "340282366920938463463374607431768211456")]
    [InlineData("/64 ipv6 mask", "ffff:ffff:ffff:ffff::")]
    [InlineData("ffff:ffff:ffff:ffff:: in cidr", "/64")]
    [InlineData("2001:DB8:0:0:0:0:0:1", "2001:db8::1")]
    [InlineData("2001:0:0:1:0:0:0:1", "2001:0:0:1::1")]
    [InlineData("2001:0:0:1:0:0:1:1", "2001::1:0:0:1:1")]
    [InlineData("2001:db8:0:1:1:1:1:1", "2001:db8:0:1:1:1:1:1")]
    [InlineData("::ffff:192.0.2.1", "::ffff:c000:201")]
    [InlineData("192.0.2.1 in ::ffff:c000:200/120", "no")]
    [InlineData("::ffff:192.0.2.1 in ::ffff:c000:200/120", "yes")]
    [InlineData("firsthost(192.0.2.0/31)", "192.0.2.0")]
    [InlineData("lasthost(192.0.2.1/32)", "192.0.2.1")]
    [InlineData("broadcast(192.0.2.17/28)", "192.0.2.31")]
    [InlineData("network(192.0.2.17/28)", "192.0.2.16")]
    [InlineData("lastip(::/0)", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")]
    [InlineData("firstip(2001:db8::1/64)", "2001:db8::")]
    [InlineData("192.0.2.17/28 in mask", "255.255.255.240")]
    [InlineData("192.0.2.17/28 in cidr", "/28")]
    [InlineData("net=192.0.2.0/24\naddr=192.0.2.42\naddr in net", "yes")]
    [InlineData("Subnet 192.0.2.1/32", "192.0.2.1 – 192.0.2.1")]
    [InlineData("width=24\naddr=192.0.2.1\naddr/width", "192.0.2.0 – 192.0.2.255")]
    [InlineData("net=192.0.2.0/24\nfirstip(net) in net", "yes")]
    [InlineData("10:00:30", "10:00:30")]
    [InlineData("2027-03-01", "2027-03-01")]
    [InlineData("prefix=255.255.255.0 in cidr\nsubnet(192.0.2.17,prefix)", "192.0.2.0 – 192.0.2.255")]
    [InlineData("192.0.2.17 / (255.255.255.0 in cidr)", "192.0.2.0 – 192.0.2.255")]
    [InlineData("netmask(cidr(255.255.255.0),4)", "255.255.255.0")]
    [InlineData("cidr(cidr(255.255.255.0))", "/24")]
    [InlineData("m=7\n10 cm in m", "0.1 m")]
    [InlineData("1/2", "0.5")]
    [InlineData("1.25+2.75", "4")]
    [InlineData("1 << 4", "16")]
    public void PublishedExamplesCanonicalFormsAndInteroperability(string source, string expected) => Assert.Equal(expected, Last(source).Display);

    [Theory]
    [InlineData("256.0.0.1")][InlineData("01.2.3.4")][InlineData("0x1.2.3.4")][InlineData("1.2.3.4abc")][InlineData("1.2.3.4.5")]
    [InlineData("192.0.2.1/33")][InlineData("192.0.2.1/-1")][InlineData("192.0.2.1/1.5")][InlineData("192.0.2.1/24%")]
    [InlineData("2001:db8::1/129")][InlineData("2001:db8:::1")][InlineData("fe80::1%2")][InlineData("[::1]:80")]
    [InlineData("::ffff:192.000.2.1")][InlineData("2001:db8::xyz")][InlineData("2001:db8::1::2")]
    [InlineData("255.0.255.0 in cidr")][InlineData("::1 in cidr")][InlineData("/33 mask")][InlineData("/129 ipv6 mask")]
    [InlineData("netmask(24,5)")][InlineData("subnet(1,24)")][InlineData("contains(192.0.2.0/24,1)")][InlineData("192.0.2.1 in 192.0.2.0")]
    [InlineData("hostcount(::/64)")][InlineData("firsthost(::/127)")][InlineData("broadcast(::/0)")][InlineData("broadcast(192.0.2.0/31)")]
    [InlineData("192.0.2.1+1")][InlineData("192.0.2.0/24+1")][InlineData("1/192.0.2.1")][InlineData("192.0.2.1 << 1")]
    [InlineData("subnet(::1,cidr(255.255.255.0))")][InlineData("netmask(cidr(255.255.255.0),6)")]
    [InlineData("cidr()")][InlineData("netmask(24)")][InlineData("subnet(192.0.2.1)")][InlineData("contains(192.0.2.0/24)")]
    public void InvalidNetworksAndTypedArithmeticFail(string source) => Assert.NotNull(SheetEvaluator.Evaluate(source)[^1].Error);

    [Fact]
    public void FactsKeepHostModelAndNormalizationExplicit()
    {
        var ipv4 = Last("192.0.2.17/28").Value!.Value.Network;
        Assert.Contains("host bits normalized", ipv4.Details); Assert.Contains("Reserved/special addresses are not filtered", ipv4.Details);
        Assert.Contains("RFC 3021", Last("192.0.2.0/31").Value!.Value.Network.Details);
        Assert.Contains("no broadcast", Last("::/0").Value!.Value.Network.Details);
        Assert.Null(Last("::/0").Value!.Value.Network.Subnet!.HostCount);
    }
    [Fact]
    public void SavedFunctionsAndIncrementalMembershipPreserveTypes()
    {
        var library = new FunctionLibrary([new("office", ["x"], "x in 192.0.2.0/24"),new("block", ["p"], "subnet(192.0.2.17,p)")]);
        var result = new SheetEvaluationSession().EvaluateWithFunctions("office(192.0.2.1)\nblock(28)",library,[]);
        Assert.Equal("yes", result.Results[0].Display); Assert.Equal("192.0.2.16 – 192.0.2.31", result.Results[1].Display);
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("bad",[],"netmask(24)")]));
        var session = new SheetEvaluationSession();session.Evaluate("n=192.0.2.0/24\na=192.0.2.1\na in n\n2+2");
        var changed = session.Evaluate("n=192.0.3.0/24\na=192.0.2.1\na in n\n2+2");
        Assert.Equal("no",changed[2].Display);Assert.Equal(1,session.LastStatistics.ParsedLines);Assert.True(session.LastStatistics.ReusedResults>0);
    }
    [Fact]
    public void CountsAreBoundedAndCultureIndependentWithoutEnumeratingHosts()
    {
        var culture = CultureInfo.CurrentCulture;
        try { CultureInfo.CurrentCulture = new("ar-SA"); Assert.Equal("340282366920938463463374607431768211456",Last("ipcount(::/0)").Display); Assert.Equal("255.255.255.0",Last("/24 mask").Display); }
        finally { CultureInfo.CurrentCulture = culture; }
        using var cancellation = new CancellationTokenSource();cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(()=>SheetEvaluator.Evaluate("::/0",cancellation.Token));
        Assert.NotNull(SheetEvaluator.Evaluate(new string('f',130)+"::1")[0].Error);
    }
}
