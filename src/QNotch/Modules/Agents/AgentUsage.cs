using System.Globalization;
using System.Text.Json;

namespace QNotch.Modules.Agents;

/// <summary>Tokens and what they would cost at API list prices. <see cref="Unpriced"/>: some tokens came from a model the price table does not know.</summary>
internal readonly record struct Usage(long Tokens, double Cost, bool Unpriced = false)
{
    public static Usage operator +(Usage a, Usage b) => new(a.Tokens + b.Tokens, a.Cost + b.Cost, a.Unpriced || b.Unpriced);
    public static Usage operator -(Usage a, Usage b) => new(a.Tokens - b.Tokens, a.Cost - b.Cost, a.Unpriced);

    /// <summary>"1.9M tokens · $2.14", empty when there is nothing to show.</summary>
    public override string ToString() => Tokens == 0 ? "" : $"{FormatTokens(Tokens)} tokens · {FormatCost(this)}";

    public static string FormatTokens(long n) => n switch
    {
        >= 10_000_000 => $"{n / 1_000_000}M",
        >= 1_000_000 => (n / 1_000_000d).ToString("0.#", CultureInfo.InvariantCulture) + "M",
        >= 1_000 => $"{n / 1_000}K",
        _ => n.ToString(CultureInfo.InvariantCulture),
    };

    public static string FormatCost(Usage u) => u.Cost == 0 && u.Unpriced ? "price unknown"
        : u.Cost >= 100 ? "$" + u.Cost.ToString("0", CultureInfo.InvariantCulture)
        : "$" + u.Cost.ToString("0.00", CultureInfo.InvariantCulture);
}

/// <summary>
/// API list prices in USD per million tokens. Cache writes cost 1.25x input (5 minute cache) or 2x (1 hour cache), fast mode 2x everything.
/// First matching prefix wins, so a specific id goes before the family it belongs to. Source: platform.claude.com pricing, October 2026.
/// </summary>
internal static class AgentPrices
{
    static readonly (string Prefix, double In, double Out, double CacheRead)[] Table =
    [
        ("claude-fable-5-1", 10, 50, 0.25),
        ("claude-mythos-5-1", 10, 50, 0.25),
        ("claude-fable-5", 10, 50, 1),
        ("claude-mythos-5", 10, 50, 1),
        ("claude-opus-5-5", 4, 20, 0.20),
        ("claude-opus-5", 5, 25, 0.50),
        ("claude-opus-4-5", 5, 25, 0.50),
        ("claude-opus-4-6", 5, 25, 0.50),
        ("claude-opus-4-7", 5, 25, 0.50),
        ("claude-opus-4-8", 5, 25, 0.50),
        ("claude-opus-4", 15, 75, 1.50), // 4.0 and 4.1
        ("claude-sonnet-5", 2, 10, 0.20), // 5 and 5.5
        ("claude-sonnet-4", 3, 15, 0.30),
        ("claude-3-7-sonnet", 3, 15, 0.30),
        ("claude-haiku-4", 1, 5, 0.10),
        ("claude-3-5-haiku", 0.80, 4, 0.08),
    ];

    /// <summary>The cost of one message's <c>usage</c>, or null for a model not in the table.</summary>
    public static double? Cost(string model, long input, long write5m, long write1h, long read, long output, bool fast)
    {
        foreach (var p in Table)
        {
            if (!model.StartsWith(p.Prefix, StringComparison.Ordinal)) continue;
            var usd = (input * p.In + write5m * p.In * 1.25 + write1h * p.In * 2 + read * p.CacheRead + output * p.Out) / 1_000_000;
            return fast ? usd * 2 : usd;
        }
        return null;
    }
}

/// <summary>
/// Reads one session's token usage from the transcripts Claude Code writes (the session's .jsonl and its subagents' files), picking up
/// where the last read stopped. Not thread safe: the module runs one read per session at a time, on the thread pool.
/// </summary>
internal sealed class UsageReader
{
    const int Chunk = 256 * 1024;
    static readonly byte[] AssistantMark = "\"type\":\"assistant\""u8.ToArray();

    /// <summary>
    /// Per file: where the next read starts, and the reply counted last. Each content block of a reply is its own line with the same
    /// message id, written one after the other; some versions grow <c>output_tokens</c> from line to line, so the last line counts.
    /// </summary>
    readonly Dictionary<string, (long Offset, string? Id, DateOnly Day, Usage Usage)> _files = [];
    readonly Dictionary<DateOnly, Usage> _days = [];

    /// <summary>Bytes the last <see cref="Read"/> went through: the first read of a long session can be megabytes.</summary>
    public long BytesRead { get; private set; }

    /// <summary>Usage per local day, a copy the UI thread may keep.</summary>
    public Dictionary<DateOnly, Usage> Read(string transcript)
    {
        BytesRead = 0;
        ReadFile(transcript);
        var subagents = Path.Combine(Path.ChangeExtension(transcript, null), "subagents");
        if (Directory.Exists(subagents))
            foreach (var f in Directory.EnumerateFiles(subagents, "*.jsonl")) ReadFile(f);
        return new(_days);
    }

    void ReadFile(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var state = _files.GetValueOrDefault(path);
            if (fs.Length < state.Offset) return; // rewritten: leave the counts alone rather than count it twice
            fs.Position = state.Offset;
            var buf = new byte[Math.Min(Chunk, fs.Length - state.Offset)];
            for (int carry = 0, n; buf.Length > 0 && (n = fs.Read(buf, carry, buf.Length - carry)) > 0;)
            {
                var data = buf.AsSpan(0, carry + n);
                var done = 0;
                for (int nl; (nl = data[done..].IndexOf((byte)'\n')) >= 0; done += nl + 1)
                    if (data.Slice(done, nl).IndexOf(AssistantMark) >= 0) Add(data.Slice(done, nl), ref state);
                state.Offset += done; // a line still being written waits for the next read
                BytesRead += done;
                carry = data.Length - done;
                if (done == 0) Array.Resize(ref buf, buf.Length * 2); // one line longer than the buffer
                else data[done..].CopyTo(buf);
            }
            _files[path] = state;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { /* gone or locked: try again on the next change */ }
    }

    void Add(ReadOnlySpan<byte> line, ref (long Offset, string? Id, DateOnly Day, Usage Usage) last)
    {
        try
        {
            using var doc = JsonDocument.Parse(line.ToArray());
            var root = doc.RootElement;
            if (!root.TryGetProperty("message", out var m) || !m.TryGetProperty("usage", out var u) || u.ValueKind != JsonValueKind.Object) return;

            long N(JsonElement o, string name) => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(name, out var v) && v.TryGetInt64(out var n) ? n : 0;
            long input = N(u, "input_tokens"), read = N(u, "cache_read_input_tokens"), output = N(u, "output_tokens"), write = N(u, "cache_creation_input_tokens");
            var cc = u.TryGetProperty("cache_creation", out var c) ? c : default;
            long write1h = N(cc, "ephemeral_1h_input_tokens"), write5m = Math.Max(0, write - write1h);
            var tokens = input + write + read + output;
            if (tokens == 0) return;

            var model = m.TryGetProperty("model", out var mo) ? mo.GetString() ?? "" : "";
            var fast = u.TryGetProperty("speed", out var sp) && sp.ValueEquals("fast");
            var cost = AgentPrices.Cost(model, input, write5m, write1h, read, output, fast);
            var usage = new Usage(tokens, cost ?? 0, cost is null);
            var id = m.TryGetProperty("id", out var i) ? i.GetString() : null;
            if (id is not null && id == last.Id) _days[last.Day] = _days[last.Day] - last.Usage; // a later line of the same reply replaces it
            else
                last.Day = root.TryGetProperty("timestamp", out var ts) && ts.TryGetDateTime(out var t) ? DateOnly.FromDateTime(t.ToLocalTime()) : DateOnly.FromDateTime(DateTime.Now);
            last.Id = id;
            last.Usage = usage;
            _days[last.Day] = _days.GetValueOrDefault(last.Day) + usage;
        }
        catch (JsonException) { }
    }
}
