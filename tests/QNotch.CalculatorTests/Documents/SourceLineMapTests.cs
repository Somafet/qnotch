using Calc.Documents;

namespace Calc.Documents.Tests;

public class SourceLineMapTests
{
    [Theory]
    [InlineData("", 1)]
    [InlineData("a\n", 2)]
    [InlineData("a\r\nb\rc\nd", 4)]
    [InlineData("😀 é 日本語\r\nשלום\n", 3)]
    public void EveryUtf16CoordinateMapsToItsLogicalLine(string source, int count)
    {
        var map = new SourceLineMap(source); Assert.Equal(count, map.Count);
        for (var i = 0; i < count; i++)
        {
            Assert.Equal(i, map.LineAt(map.Start(i)));
            var end = i + 1 < count ? map.Start(i + 1) : source.Length;
            for (var c = map.Start(i); c < end; c++) Assert.Equal(i, map.LineAt(c));
            Assert.DoesNotContain('\n', source[map.Start(i)..map.ContentEnd(i)]);
            Assert.DoesNotContain('\r', source[map.Start(i)..map.ContentEnd(i)]);
        }
        Assert.Equal(count - 1, map.LineAt(source.Length));
    }
    [Fact]
    public void LargeSheetAndBounds()
    {
        var map = new SourceLineMap(string.Join("\r\n", Enumerable.Repeat("1+1", 10000)));
        Assert.Equal(10000, map.Count); Assert.Equal(49995, map.Start(9999));
        Assert.Throws<ArgumentOutOfRangeException>(() => map.LineAt(-1));
        Assert.Throws<ArgumentException>(() => new SourceLineMap(new string('a', 200001)));
    }
}
