namespace Calc.Documents;

/// <summary>Logical source lines in UTF-16 coordinates. Wrapping does not create source lines.</summary>
public sealed class SourceLineMap
{
    private readonly int[] starts;
    public string Source { get; }
    public int Count => starts.Length;
    public SourceLineMap(string source)
    {
        if (source.Length > SheetStore.MaxCharacters) throw new ArgumentException("Source exceeds document limit");
        Source = source;
        var positions = new List<int> { 0 };
        for (var i = 0; i < source.Length; i++)
        {
            if (source[i] == '\r')
            {
                if (i + 1 < source.Length && source[i + 1] == '\n') i++;
                positions.Add(i + 1);
            }
            else if (source[i] == '\n') positions.Add(i + 1);
        }
        starts = positions.ToArray();
    }
    public int Start(int line) => starts[line];
    public int ContentEnd(int line)
    {
        var end = line + 1 < Count ? starts[line + 1] : Source.Length;
        while (end > starts[line] && Source[end - 1] is '\r' or '\n') end--;
        return end;
    }
    public int LineAt(int character)
    {
        if (character < 0 || character > Source.Length) throw new ArgumentOutOfRangeException(nameof(character));
        var found = Array.BinarySearch(starts, character);
        return found >= 0 ? found : ~found - 1;
    }
}
