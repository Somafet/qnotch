using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Calc.Core;

namespace Calc.Documents;

public enum ShareTheme { Light, Dark }
public enum ShareFigureKind { Bar, Pie, Trend, Plot }

/// <summary>One labelled chart magnitude with the sheet's own formatted value.</summary>
public sealed record ShareChartItem(string Label, double Magnitude, string Display);

/// <summary>A frozen figure. Charts keep magnitudes; plots keep points quantized to <see cref="ShareLink.PlotGrid"/> steps of their frame.</summary>
public sealed record ShareFigure(ShareFigureKind Kind, string Description)
{
    public IReadOnlyList<ShareChartItem> Items { get; init; } = [];
    public string? Total { get; init; }
    /// <summary>Plot frame as display text: x from, x to, y from, y to.</summary>
    public IReadOnlyList<string> Frame { get; init; } = [];
    /// <summary>Plot points as (x, y) grid coordinates; y may leave the frame and is clipped by the viewer.</summary>
    public IReadOnlyList<(int X, int Y)> Points { get; init; } = [];
    public IReadOnlyList<int> Segments { get; init; } = [];
}

/// <summary>One source line and what Calc showed for it when the link was made.</summary>
public sealed record ShareLine(string Source, string? Result = null, bool Error = false, string? Explanation = null, ShareFigure? Figure = null);

/// <summary>A frozen snapshot: source, results, theme and explanations as computed when shared. A viewer never recomputes it.</summary>
public sealed record ShareSnapshot(string Title, ShareTheme Theme, DateOnly? Date, IReadOnlyList<ShareLine> Lines);

public sealed class ShareLinkException(string message) : Exception(message);

/// <summary>Versioned share links: canonical UTF-8 JSON, raw DEFLATE, unpadded base64url, carried only in the URL fragment.
/// Fragments are not sent in HTTP requests, so a static viewer reads the sheet without any server seeing it.
/// The same limits bind the encoder here and the decoder in src/Calc.ShareViewer/codec.js.</summary>
public static class ShareLink
{
    public const int Version = 1;
    public const string Prefix = "c1.";
    public const int MaxFragmentCharacters = 65_536;
    public const int MaxPayloadBytes = 1_048_576;
    public const int MaxLines = 20_000;
    public const int MaxSourceCharacters = SheetStore.MaxCharacters;
    public const int MaxTitle = WorkspaceStore.MaxNameLength;
    public const int MaxResult = 8_192;
    public const int MaxExplanation = 32_768;
    public const int MaxDescription = 1_024;
    public const int MaxLabel = 64;
    public const int MaxItems = 512;
    public const int MaxPoints = 512;
    public const int PlotGrid = 4_096;

    /// <summary>Freezes what the sheet currently shows. <paramref name="explain"/> lets the host supply its own explanation text.</summary>
    public static ShareSnapshot Capture(string title, string source, IReadOnlyList<LineResult> results, bool dark, DateOnly? date = null, Func<LineResult, string>? explain = null)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (source.Length > MaxSourceCharacters) throw new ShareLinkException("Sheet too large to share as a link");
        var map = new SourceLineMap(source);
        if (map.Count > MaxLines) throw new ShareLinkException("Sheet too large to share as a link");
        var byLine = new Dictionary<int, LineResult>();
        foreach (var result in results) if (result.Line >= 0 && result.Line < map.Count) byLine[result.Line] = result;
        explain ??= DefaultExplanation;
        var lines = new ShareLine[map.Count];
        for (var i = 0; i < map.Count; i++)
        {
            var text = Clean(source[map.Start(i)..map.ContentEnd(i)]);
            if (!byLine.TryGetValue(i, out var answer)) { lines[i] = new(text); continue; }
            var display = answer.Display;
            if (display.Length == 0) { lines[i] = new(text); continue; }
            var error = answer.Error is not null;
            // Host text may use Environment.NewLine; the snapshot keeps one line-break form.
            var explanation = error ? null : Bound(Clean(explain(answer)).ReplaceLineEndings("\n").TrimEnd(), MaxExplanation);
            lines[i] = new(text, Bound(Clean(display), MaxResult), error, string.IsNullOrEmpty(explanation) ? null : explanation, error ? null : Figure(answer.Value));
        }
        var name = Bound(Clean(title).Trim(), MaxTitle);
        return new(name.Length == 0 ? "Sheet" : name, dark ? ShareTheme.Dark : ShareTheme.Light, date, lines);
    }

    /// <summary>Plain steps, assumptions and dependencies. Hosts with richer explanation text pass their own formatter.</summary>
    public static string DefaultExplanation(LineResult answer)
    {
        var text = new StringBuilder();
        foreach (var step in answer.Explanation)
        {
            text.Append(step.Operation).Append('(').Append(string.Join(", ", step.Operands)).Append(") = ").Append(step.Result).Append('\n');
            if (step.Assumption is not null) text.Append(step.Assumption).Append('\n');
        }
        if (answer.Dependencies.Count > 0) text.Append("Uses ").Append(string.Join(", ", answer.Dependencies.Take(16).Select(n => "L" + (n + 1).ToString(CultureInfo.InvariantCulture))));
        return text.ToString().TrimEnd();
    }

    private static ShareFigure? Figure(SheetValue? value)
    {
        if (value is { Kind: SheetValueKind.Chart } chart)
        {
            var c = chart.Chart;
            var kind = c.Kind switch { ChartKind.Bar => ShareFigureKind.Bar, ChartKind.Pie => ShareFigureKind.Pie, _ => ShareFigureKind.Trend };
            if (c.Items.Count > MaxItems) return null;
            return new(kind, Bound(Clean(c.Description), MaxDescription))
            {
                Items = c.Items.Select(item => new ShareChartItem(Bound(Clean(item.Label), MaxLabel), Finite(item.Magnitude), Bound(Clean(item.Display), MaxLabel))).ToArray(),
                Total = c.Kind == ChartKind.Trend ? null : Bound(Clean(c.Total), MaxLabel),
            };
        }
        if (value is { Kind: SheetValueKind.Plot } shown)
        {
            var p = shown.Plot;
            if (p.X.Count > MaxPoints || !(p.Upper > p.Lower) || !(p.YUpper > p.YLower)) return null;
            int Grid(double v, double low, double high) => (int)Math.Clamp(Math.Round((v - low) / (high - low) * PlotGrid), -PlotGrid, 2 * PlotGrid);
            var points = new (int, int)[p.X.Count];
            for (var i = 0; i < points.Length; i++) points[i] = (Grid(p.X[i], p.Lower, p.Upper), Grid(p.Y[i], p.YLower, p.YUpper));
            return new(ShareFigureKind.Plot, Bound(Clean(p.Description), MaxDescription))
            {
                Frame = [PlotValue.Number(p.Lower), PlotValue.Number(p.Upper), PlotValue.Number(p.YLower), PlotValue.Number(p.YUpper)],
                Points = points, Segments = p.SegmentStarts.Where(start => start >= 0 && start < points.Length).Distinct().Order().ToArray(),
            };
        }
        return null;
    }
    private static double Finite(double value) => double.IsFinite(value) ? value : throw new ShareLinkException("Chart value cannot be shared");

    /// <summary>Unpaired UTF-16 surrogates cannot be UTF-8 encoded; they become U+FFFD. Everything else is kept exactly.</summary>
    private static string Clean(string text)
    {
        StringBuilder? clean = null;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1])) { clean?.Append(c).Append(text[++i]); continue; }
            if (char.IsSurrogate(c)) { clean ??= new StringBuilder(text.Length).Append(text, 0, i); clean.Append('�'); }
            else clean?.Append(c);
        }
        return clean?.ToString() ?? text;
    }
    private static string Bound(string text, int limit)
    {
        if (text.Length <= limit) return text;
        var cut = limit - 1;
        if (char.IsHighSurrogate(text[cut - 1])) cut--;
        return text[..cut] + "…";
    }

    /// <summary>Canonical JSON: fixed property order, absent values omitted, no whitespace. Strings escape only '"', '\' and
    /// U+0000–U+001F (\b \f \n \r \t, otherwise \u00xx); every other character is literal UTF-8. Numbers use the shortest round-trip invariant form.</summary>
    public static byte[] Serialize(ShareSnapshot snapshot)
    {
        Validate(snapshot);
        var json = new StringBuilder();
        json.Append("{\"v\":").Append(Version);
        Field(json, "title", snapshot.Title);
        Field(json, "theme", snapshot.Theme == ShareTheme.Dark ? "dark" : "light");
        if (snapshot.Date is { } date) Field(json, "date", date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
        json.Append(",\"lines\":[");
        for (var i = 0; i < snapshot.Lines.Count; i++)
        {
            var line = snapshot.Lines[i];
            json.Append(i > 0 ? ",{\"s\":" : "{\"s\":"); Quote(json, line.Source);
            if (line.Result is not null) Field(json, "r", line.Result);
            if (line.Error) json.Append(",\"err\":true");
            if (line.Explanation is not null) Field(json, "x", line.Explanation);
            if (line.Figure is { } figure) WriteFigure(json, figure);
            json.Append('}');
        }
        json.Append("]}");
        byte[] bytes;
        try { bytes = new UTF8Encoding(false, true).GetBytes(json.ToString()); }
        catch (EncoderFallbackException) { throw new ShareLinkException("Sheet text cannot be shared"); }
        if (bytes.Length > MaxPayloadBytes) throw new ShareLinkException("Sheet too large to share as a link");
        return bytes;
    }
    private static void WriteFigure(StringBuilder json, ShareFigure figure)
    {
        json.Append(",\"fig\":{\"kind\":");
        Quote(json, figure.Kind switch { ShareFigureKind.Bar => "bar", ShareFigureKind.Pie => "pie", ShareFigureKind.Trend => "trend", _ => "plot" });
        Field(json, "desc", figure.Description);
        if (figure.Kind == ShareFigureKind.Plot)
        {
            json.Append(",\"frame\":[");
            for (var i = 0; i < figure.Frame.Count; i++) { if (i > 0) json.Append(','); Quote(json, figure.Frame[i]); }
            json.Append("],\"pts\":[");
            for (var i = 0; i < figure.Points.Count; i++)
                json.Append(i > 0 ? ",[" : "[").Append(figure.Points[i].X.ToString(CultureInfo.InvariantCulture)).Append(',')
                    .Append(figure.Points[i].Y.ToString(CultureInfo.InvariantCulture)).Append(']');
            json.Append("],\"seg\":[").AppendJoin(',', figure.Segments.Select(start => start.ToString(CultureInfo.InvariantCulture))).Append(']');
        }
        else
        {
            if (figure.Total is not null) Field(json, "total", figure.Total);
            json.Append(",\"items\":[");
            for (var i = 0; i < figure.Items.Count; i++)
            {
                var item = figure.Items[i];
                json.Append(i > 0 ? ",[" : "["); Quote(json, item.Label);
                json.Append(',').Append(item.Magnitude.ToString("R", CultureInfo.InvariantCulture)).Append(',');
                Quote(json, item.Display); json.Append(']');
            }
            json.Append(']');
        }
        json.Append('}');
    }
    private static void Field(StringBuilder json, string name, string value) { json.Append(",\"").Append(name).Append("\":"); Quote(json, value); }
    private static void Quote(StringBuilder json, string value)
    {
        json.Append('"');
        foreach (var c in value)
        {
            switch (c)
            {
                case '"': json.Append("\\\""); break;
                case '\\': json.Append("\\\\"); break;
                case '\b': json.Append("\\b"); break;
                case '\f': json.Append("\\f"); break;
                case '\n': json.Append("\\n"); break;
                case '\r': json.Append("\\r"); break;
                case '\t': json.Append("\\t"); break;
                case < ' ': json.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture)); break;
                default: json.Append(c); break;
            }
        }
        json.Append('"');
    }

    /// <summary>The fragment text, without '#'.</summary>
    public static string EncodeFragment(ShareSnapshot snapshot)
    {
        var json = Serialize(snapshot);
        using var compressed = new MemoryStream();
        using (var deflate = new DeflateStream(compressed, CompressionLevel.SmallestSize, leaveOpen: true)) deflate.Write(json);
        var fragment = Prefix + Base64Url(compressed.ToArray());
        if (fragment.Length > MaxFragmentCharacters) throw new ShareLinkException("Sheet too large to share as a link");
        return fragment;
    }

    /// <summary>Viewer URL plus the fragment. The viewer address is the only part that reaches a server when the link is opened.</summary>
    public static string Create(Uri viewer, ShareSnapshot snapshot) => ShareViewerAddress.Validate(viewer).AbsoluteUri + "#" + EncodeFragment(snapshot);

    /// <summary>Strict decoder with the same limits as the browser viewer: a full URL, "#fragment" or bare fragment.</summary>
    public static ShareSnapshot Decode(string link)
    {
        ArgumentNullException.ThrowIfNull(link);
        var hash = link.IndexOf('#');
        var fragment = hash >= 0 ? link[(hash + 1)..] : link;
        if (fragment.Length > MaxFragmentCharacters) throw new ShareLinkException("Link too large");
        if (!fragment.StartsWith(Prefix, StringComparison.Ordinal)) throw new ShareLinkException("Unsupported link version");
        var bytes = FromBase64Url(fragment[Prefix.Length..]);
        var json = Inflate(bytes);
        string text;
        try { text = new UTF8Encoding(false, true).GetString(json); }
        catch (DecoderFallbackException) { throw new ShareLinkException("Damaged link"); }
        try
        {
            using var parsed = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 8 });
            var snapshot = Read(parsed.RootElement);
            Validate(snapshot, "Damaged link");
            return snapshot;
        }
        catch (JsonException) { throw new ShareLinkException("Damaged link"); }
        catch (InvalidOperationException) { throw new ShareLinkException("Damaged link"); }
        catch (FormatException) { throw new ShareLinkException("Damaged link"); }
    }

    private static byte[] Inflate(byte[] bytes)
    {
        try
        {
            using var input = new MemoryStream(bytes);
            using var deflate = new DeflateStream(input, CompressionMode.Decompress);
            using var output = new MemoryStream();
            var chunk = new byte[16_384];
            int read;
            while ((read = deflate.Read(chunk)) > 0)
            {
                if (output.Length + read > MaxPayloadBytes) throw new ShareLinkException("Link expands beyond the size limit");
                output.Write(chunk, 0, read);
            }
            return output.ToArray();
        }
        catch (InvalidDataException) { throw new ShareLinkException("Damaged link"); }
    }

    private static ShareSnapshot Read(JsonElement root)
    {
        Keys(root, ["v", "title", "theme", "date", "lines"], ["v", "title", "theme", "lines"]);
        if (root.GetProperty("v").GetInt32() != Version) throw new ShareLinkException("Unsupported link version");
        var theme = Str(root.GetProperty("theme")) switch { "light" => ShareTheme.Light, "dark" => ShareTheme.Dark, _ => throw new ShareLinkException("Damaged link") };
        DateOnly? date = root.TryGetProperty("date", out var d) ? DateOnly.ParseExact(Str(d), "yyyy-MM-dd", CultureInfo.InvariantCulture) : null;
        var lines = new List<ShareLine>();
        foreach (var line in root.GetProperty("lines").EnumerateArray())
        {
            if (lines.Count == MaxLines) throw new ShareLinkException("Damaged link");
            Keys(line, ["s", "r", "err", "x", "fig"], ["s"]);
            var error = line.TryGetProperty("err", out var e) && (e.ValueKind == JsonValueKind.True ? true : throw new ShareLinkException("Damaged link"));
            lines.Add(new(Text(line, "s")!, Text(line, "r"), error, Text(line, "x"), line.TryGetProperty("fig", out var f) ? ReadFigure(f) : null));
        }
        return new(Text(root, "title")!, theme, date, lines);
    }
    private static ShareFigure ReadFigure(JsonElement figure)
    {
        var kind = figure.TryGetProperty("kind", out var k) ? Str(k) switch
        {
            "bar" => ShareFigureKind.Bar, "pie" => ShareFigureKind.Pie, "trend" => ShareFigureKind.Trend, "plot" => ShareFigureKind.Plot,
            _ => throw new ShareLinkException("Damaged link"),
        } : throw new ShareLinkException("Damaged link");
        if (kind == ShareFigureKind.Plot)
        {
            Keys(figure, ["kind", "desc", "frame", "pts", "seg"], ["kind", "desc", "frame", "pts", "seg"]);
            var points = figure.GetProperty("pts").EnumerateArray().Select(point => point.GetArrayLength() == 2 ? (point[0].GetInt32(), point[1].GetInt32()) : throw new ShareLinkException("Damaged link")).ToArray();
            return new(kind, Text(figure, "desc")!)
            {
                Frame = figure.GetProperty("frame").EnumerateArray().Select(Str).ToArray(),
                Points = points, Segments = figure.GetProperty("seg").EnumerateArray().Select(item => item.GetInt32()).ToArray(),
            };
        }
        Keys(figure, ["kind", "desc", "total", "items"], ["kind", "desc", "items"]);
        return new(kind, Text(figure, "desc")!)
        {
            Total = Text(figure, "total"),
            Items = figure.GetProperty("items").EnumerateArray().Select(item => item.GetArrayLength() == 3 && item[1].ValueKind == JsonValueKind.Number
                ? new ShareChartItem(Str(item[0]), item[1].GetDouble(), Str(item[2])) : throw new ShareLinkException("Damaged link")).ToArray(),
        };
    }
    private static void Keys(JsonElement element, string[] allowed, string[] required)
    {
        if (element.ValueKind != JsonValueKind.Object) throw new ShareLinkException("Damaged link");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
            if (!allowed.Contains(property.Name, StringComparer.Ordinal) || !seen.Add(property.Name)) throw new ShareLinkException("Damaged link");
        if (required.Any(name => !seen.Contains(name))) throw new ShareLinkException("Damaged link");
    }
    private static string? Text(JsonElement element, string name) => element.TryGetProperty(name, out var value) ? Str(value) : null;
    private static string Str(JsonElement value) => value.ValueKind == JsonValueKind.String ? value.GetString()! : throw new ShareLinkException("Damaged link");

    private static void Validate(ShareSnapshot snapshot, string failure = "Sheet too large to share as a link")
    {
        void Require(bool condition) { if (!condition) throw new ShareLinkException(failure); }
        Require(snapshot.Title.Length is > 0 and <= MaxTitle && snapshot.Lines.Count is > 0 and <= MaxLines);
        long source = 0;
        foreach (var line in snapshot.Lines)
        {
            source += line.Source.Length;
            Require(line.Source.IndexOfAny(['\r', '\n']) < 0 && (line.Result?.Length ?? 0) <= MaxResult && (line.Explanation?.Length ?? 0) <= MaxExplanation);
            Require(!(line.Error && (line.Result is null || line.Explanation is not null || line.Figure is not null)) && (line.Result is not null || line.Explanation is null && line.Figure is null));
            if (line.Figure is not { } figure) continue;
            Require(figure.Description.Length <= MaxDescription);
            if (figure.Kind == ShareFigureKind.Plot)
                Require(figure.Frame.Count == 4 && figure.Frame.All(text => text.Length <= MaxLabel) && figure.Points.Count is > 0 and <= MaxPoints &&
                    figure.Points.All(point => point.X is >= -PlotGrid and <= 2 * PlotGrid && point.Y is >= -PlotGrid and <= 2 * PlotGrid) &&
                    figure.Segments.Count <= MaxPoints && figure.Segments.All(start => start >= 0 && start < figure.Points.Count) &&
                    figure.Segments.Zip(figure.Segments.Skip(1)).All(pair => pair.First < pair.Second) && figure.Items.Count == 0 && figure.Total is null);
            else
                Require(figure.Items.Count is > 0 and <= MaxItems && figure.Items.All(item => item.Label.Length <= MaxLabel && item.Display.Length <= MaxLabel && double.IsFinite(item.Magnitude)) &&
                    (figure.Total?.Length ?? 0) <= MaxLabel && figure.Points.Count == 0 && figure.Frame.Count == 0 && figure.Segments.Count == 0);
        }
        Require(source <= MaxSourceCharacters);
    }

    private static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static byte[] FromBase64Url(string text)
    {
        if (text.Length == 0 || text.Length % 4 == 1 || text.Any(c => !(c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_')))
            throw new ShareLinkException("Damaged link");
        var padded = text.Replace('-', '+').Replace('_', '/') + new string('=', (4 - text.Length % 4) % 4);
        return Convert.FromBase64String(padded);
    }
}
