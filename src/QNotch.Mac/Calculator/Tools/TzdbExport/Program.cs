// Exports NodaTime 3.3.7's embedded TZDB rules for the Swift engine, and checks the Swift port against NodaTime.
// Dev tool, never shipped. From the repository root:
//
//   dotnet run -c Release --project src/QNotch.Mac/Calculator/Tools/TzdbExport -- export \
//     src/QNotch.Mac/Calculator/Sources/CalculatorEngine/Resources/Tzdb.txt
//   dotnet run -c Release --project src/QNotch.Mac/Calculator/Tools/TzdbExport -- check \
//     src/QNotch.Mac/Calculator/Tests/CalculatorEngineTests/Vectors/TzdbCheck.txt 400 400 1900 2100
//
// EXPORT. NodaTime models a TZDB zone as either a fixed offset or a PrecalculatedDateTimeZone: an explicit
// list of zone intervals from the start of time, optionally followed by a "tail" StandardDaylightAlternatingMap
// (a standard offset plus two infinite ZoneRecurrences) from the end of the last interval on. The exporter reads
// exactly those objects (by reflection; they are internal) and writes them losslessly, so the Swift port can
// run NodaTime's own algorithms (DateTimeZone.MapLocal, ZoneRecurrence.Next/PreviousOrSame,
// ZoneYearOffset.GetOccurrenceForYear) on identical data. Interval names are dropped: the engine never shows them.
//
// File format (one zone per line, after '#' comment lines and one "V <VersionId>" line):
//   <id> =<id>                       same rules as an earlier line (a TZDB link or an identical zone)
//   <id> F<offset>                   fixed offset, seconds
//   <id> P<wall0> [<delta>:<wall>]... [T<delta> <standard> <recurrence> <recurrence>]
// P: the first interval starts at the beginning of time with wall offset <wall0>; every further interval
// starts <delta> seconds after the previous start (the first delta is from the Unix epoch). T: the tail starts
// <delta> seconds after the last interval start, with standard offset <standard>. A recurrence is
//   <mode>/<month>/<dayOfMonth>/<dayOfWeek>/<advance>/<millisecondOfDay>/<addDay>/<savings>
// with mode W (wall), S (standard) or U (UTC), ISO day of week (Monday 1 .. Sunday 7, 0 = any), flags 0/1.
// The first tail recurrence is NodaTime's standard recurrence (zero savings), the second the daylight one.
//
// CHECK. For every id, the checker draws pseudo-random instants and local date-times from a splitmix64 stream
// seeded with the FNV-1a hash of the id, walks every transition between two years, probes MapLocal around each,
// and writes "<id> <cases> <fnv>" with the FNV-1a hash of the results. Tests/CalculatorEngineTests/Core/
// TimeZoneRulesTests.swift regenerates the same cases from the Swift rules and compares hashes. Use larger
// arguments (e.g. "check out.txt 200000 200000 1 10000") for an exhaustive run; set TZDB_TRACE=<id> to print
// one zone's results for diffing.
using System.Globalization;
using System.Reflection;
using System.Text;
using NodaTime;

var I = CultureInfo.InvariantCulture;
const BindingFlags Any = BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.Instance;
var provider = DateTimeZoneProviders.Tzdb;
var ids = provider.Ids.OrderBy(id => id, StringComparer.Ordinal).ToList();

if (args.Length == 2 && args[0] == "export") Export(args[1]);
else if (args.Length == 6 && args[0] == "check") Check(args[1], int.Parse(args[2], I), int.Parse(args[3], I), int.Parse(args[4], I), int.Parse(args[5], I));
else { Console.Error.WriteLine("usage: export <file> | check <file> <instants> <locals> <fromYear> <toYear>"); return 2; }
return 0;

object Field(object target, string name) =>
    target.GetType().GetField(name, Any)?.GetValue(target) ?? target.GetType().GetProperty(name, Any)!.GetValue(target)!;

long Seconds(Instant instant)
{
    var ticks = instant.ToUnixTimeTicks();
    if (ticks % TimeSpan.TicksPerSecond != 0) throw new InvalidDataException("Transition not on a whole second: " + instant);
    return ticks / TimeSpan.TicksPerSecond;
}

string Recurrence(object recurrence)
{
    if ((int)Field(recurrence, "FromYear") != int.MinValue || (int)Field(recurrence, "ToYear") != int.MaxValue)
        throw new InvalidDataException("Tail recurrence is not infinite: " + recurrence);
    var offset = Field(recurrence, "YearOffset");
    var mode = Field(offset, "Mode").ToString() switch { "Wall" => "W", "Standard" => "S", "Utc" => "U", var other => throw new InvalidDataException(other) };
    var time = (LocalTime)Field(offset, "TimeOfDay");
    if (time.TickOfDay % TimeSpan.TicksPerMillisecond != 0) throw new InvalidDataException("Sub-millisecond rule time");
    return string.Join('/', mode, ((int)Field(offset, "monthOfYear")).ToString(I), ((int)Field(offset, "dayOfMonth")).ToString(I),
        ((int)Field(offset, "dayOfWeek")).ToString(I), (bool)Field(offset, "AdvanceDayOfWeek") ? "1" : "0",
        (time.TickOfDay / TimeSpan.TicksPerMillisecond).ToString(I), (bool)Field(offset, "addDay") ? "1" : "0",
        ((Offset)Field(recurrence, "Savings")).Seconds.ToString(I));
}

string Rules(DateTimeZone zone)
{
    if (zone.GetType().Name == "CachedDateTimeZone") zone = (DateTimeZone)Field(zone, "TimeZone");
    switch (zone.GetType().Name)
    {
        case "FixedDateTimeZone": return "F" + zone.MaxOffset.Seconds.ToString(I);
        case "PrecalculatedDateTimeZone":
            var periods = (NodaTime.TimeZones.ZoneInterval[])Field(zone, "periods");
            if (periods[0].HasStart) throw new InvalidDataException(zone.Id + ": first interval has a start");
            var text = new StringBuilder("P").Append(periods[0].WallOffset.Seconds.ToString(I));
            var previous = 0L;
            for (var i = 1; i < periods.Length; i++)
            {
                if (periods[i - 1].End != periods[i].Start) throw new InvalidDataException(zone.Id + ": intervals do not adjoin");
                var start = Seconds(periods[i].Start);
                text.Append(' ').Append((start - previous).ToString(I)).Append(':').Append(periods[i].WallOffset.Seconds.ToString(I));
                previous = start;
            }
            var tail = zone.GetType().GetField("tailZone", Any)!.GetValue(zone);
            if (tail is null)
            {
                if (periods[^1].HasEnd) throw new InvalidDataException(zone.Id + ": no tail and the last interval ends");
                return text.ToString();
            }
            if (tail.GetType().Name != "StandardDaylightAlternatingMap") throw new InvalidDataException(zone.Id + ": tail " + tail.GetType().Name);
            var tailStart = Seconds((Instant)Field(zone, "tailZoneStart"));
            return text.Append(" T").Append((tailStart - previous).ToString(I)).Append(' ')
                .Append(((Offset)Field(tail, "standardOffset")).Seconds.ToString(I)).Append(' ')
                .Append(Recurrence(Field(tail, "standardRecurrence"))).Append(' ').Append(Recurrence(Field(tail, "dstRecurrence"))).ToString();
        default: throw new InvalidDataException(zone.Id + ": unexpected zone type " + zone.GetType().Name);
    }
}

void Export(string path)
{
    var output = new StringBuilder();
    output.Append("# NodaTime 3.3.7 TZDB rules exported by Tools/TzdbExport (format described in its Program.cs); regenerate, do not edit.\n");
    output.Append("V ").Append(provider.VersionId).Append('\n');
    var seen = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var id in ids)
    {
        var zone = provider[id];
        if (zone.Id != id) throw new InvalidDataException("Zone id differs: " + id + " → " + zone.Id);
        var rules = Rules(zone);
        output.Append(id).Append(' ');
        if (seen.TryGetValue(rules, out var first)) output.Append('=').Append(first);
        else { seen[rules] = id; output.Append(rules); }
        output.Append('\n');
    }
    File.WriteAllText(path, output.ToString(), new UTF8Encoding(false));
    Console.WriteLine($"{ids.Count} ids, {seen.Count} distinct rule sets, {output.Length} characters");
}

void Check(string path, int instantCount, int localCount, int fromYear, int toYear)
{
    const long minTicks = -621_355_968_000_000_000L, maxTicks = 2_534_023_007_999_999_999L, maxLocal = 3_155_378_975_999_999_999L, epoch = 621_355_968_000_000_000L;
    long YearStart(int year) => year > 9999 ? maxTicks + 1 : new DateTime(year, 1, 1).Ticks - epoch;
    var trace = Environment.GetEnvironmentVariable("TZDB_TRACE");
    var output = new StringBuilder();
    output.Append("# NodaTime 3.3.7 rule checks from Tools/TzdbExport; regenerate, do not edit.\n");
    output.Append(FormattableString.Invariant($"C {instantCount} {localCount} {fromYear} {toYear}\n"));
    foreach (var id in ids)
    {
        var zone = provider[id];
        var lines = new List<string>();
        string Map(long local)
        {
            var mapping = zone.MapLocal(LocalDateTime.FromDateTime(new DateTime(local)));
            return mapping.Count switch
            {
                0 => "0",
                1 => "1 " + mapping.EarlyInterval.WallOffset.Seconds.ToString(I),
                _ => "2 " + mapping.EarlyInterval.WallOffset.Seconds.ToString(I) + " " + mapping.LateInterval.WallOffset.Seconds.ToString(I),
            };
        }
        var random = new SplitMix64(Fnv(id));
        for (var k = 0; k < instantCount; k++)
        {
            var ticks = minTicks + (long)(random.Next() % (ulong)(maxTicks - minTicks + 1));
            lines.Add("o " + ticks.ToString(I) + " " + zone.GetUtcOffset(Instant.FromUnixTimeTicks(ticks)).Seconds.ToString(I));
        }
        for (var k = 0; k < localCount; k++)
        {
            var local = (long)(random.Next() % (ulong)(maxLocal + 1));
            lines.Add("m " + local.ToString(I) + " " + Map(local));
        }
        long from = YearStart(fromYear), to = YearStart(toYear);
        var interval = zone.GetZoneInterval(Instant.FromUnixTimeTicks(from));
        while (interval.HasEnd && interval.End.ToUnixTimeTicks() < to)
        {
            var at = interval.End.ToUnixTimeTicks();
            var next = zone.GetZoneInterval(interval.End);
            int before = interval.WallOffset.Seconds, after = next.WallOffset.Seconds;
            lines.Add("t " + at.ToString(I) + " " + before.ToString(I) + " " + after.ToString(I));
            foreach (var wall in new[] { before, after })
                foreach (var delta in new[] { -TimeSpan.TicksPerSecond, -1, 0, 1, TimeSpan.TicksPerSecond })
                {
                    var local = at + epoch + wall * TimeSpan.TicksPerSecond + delta;
                    if (local >= 0 && local <= maxLocal) lines.Add("m " + local.ToString(I) + " " + Map(local));
                }
            interval = next;
        }
        if (id == trace) foreach (var line in lines) Console.WriteLine(line);
        output.Append(id).Append(' ').Append(lines.Count.ToString(I)).Append(' ').Append(Fnv(string.Join('\n', lines)).ToString("x16", I)).Append('\n');
    }
    File.WriteAllText(path, output.ToString(), new UTF8Encoding(false));
}

static ulong Fnv(string value)
{
    var hash = 0xcbf29ce484222325UL;
    foreach (var b in Encoding.UTF8.GetBytes(value)) { hash ^= b; hash *= 0x100000001b3UL; }
    return hash;
}

/// splitmix64, mirrored by Tests/CalculatorEngineTests/OracleVectors.swift.
sealed class SplitMix64(ulong seed)
{
    private ulong state = seed;
    public ulong Next()
    {
        var z = state += 0x9E3779B97F4A7C15UL;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
        return z ^ (z >> 31);
    }
}
