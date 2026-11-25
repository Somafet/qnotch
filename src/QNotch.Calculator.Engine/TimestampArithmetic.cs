using System.Numerics;
using NodaTime;

namespace Calc.Core;

internal sealed class TimestampArithmetic(EvaluationContext context, ContextReads reads)
{
    internal static SheetValue Join(SheetValue date, SheetValue time)
    {
        try { return new(new LocalTimestamp(date.Date.ToDateTime(TimeOnly.MinValue).AddTicks(time.Time.TotalTicks))); }
        catch (ArgumentOutOfRangeException) { throw new ArithmeticException("Timestamp range exceeded"); }
    }
    internal SheetValue Now()
    {
        reads.Dependencies |= ContextDependency.Instant | ContextDependency.SecondTick;
        return new(new ZonedMoment(context.RequireNow(), DateTimeZone.Utc, "fixed offset"));
    }
    internal SheetValue Zone(SheetValue value, string id, bool conversion, string ambiguity)
    {
        var zone = ZoneCatalog.Resolve(id, context, reads, out var version);
        if (conversion)
        {
            if (value.Kind != SheetValueKind.ZonedMoment) value = Local(value, ambiguity);
            return new(new ZonedMoment(value.Moment.Instant, zone, version));
        }
        if (value.Kind == SheetValueKind.Time)
        {
            reads.Dependencies |= ContextDependency.Date;
            value = Join(new(context.RequireToday()), value);
        }
        if (value.Kind == SheetValueKind.Date) value = Join(value, new(new ClockTime(TimeOnly.MinValue)));
        return Resolve(value.Timestamp.Value, zone, version, ambiguity);
    }
    internal SheetValue Local(SheetValue value, string ambiguity = "")
    {
        var local = context.RequireLocalZone(reads);
        if (value.Kind == SheetValueKind.Time)
        {
            reads.Dependencies |= ContextDependency.Date;
            value = Join(new(context.RequireToday()), value);
        }
        if (value.Kind == SheetValueKind.Date) value = Join(value, new(new ClockTime(TimeOnly.MinValue)));
        return Resolve(value.Timestamp.Value, local.Rules, local.Version, ambiguity);
    }
    private static SheetValue Resolve(DateTime local, DateTimeZone zone, string version, string ambiguity = "")
    {
        var mapping = zone.MapLocal(LocalDateTime.FromDateTime(local));
        if (mapping.Count == 0) throw new ArithmeticException("Skipped local time in " + zone.Id);
        if (mapping.Count == 2 && ambiguity == "") throw new ArithmeticException("Ambiguous local time; specify earlier or later in " + zone.Id);
        var zoned = ambiguity == "later" ? mapping.Last() : mapping.First();
        return new(new ZonedMoment(zoned.ToInstant(), zone, version));
    }
    internal static SheetValue Unix(SheetValue value, bool export)
    {
        if (export) return new(new Rational(value.Moment.Instant.ToUnixTimeTicks(), TimeSpan.TicksPerSecond));
        if (value.IsPercentage || value.Number.IsApproximate) throw new ArithmeticException("Unix seconds require an exact plain rational");
        var ticks = value.Scalar * new Rational(TimeSpan.TicksPerSecond, 1);
        if (ticks.Denominator != 1) throw new ArithmeticException("Unix precision is at most 100 nanoseconds");
        if (ticks.Numerator < -621355968000000000L || ticks.Numerator > 2534023007999999999L) throw new ArithmeticException("Unix timestamp range exceeded");
        return new(new ZonedMoment(Instant.FromUnixTimeTicks((long)ticks.Numerator), DateTimeZone.Utc, "fixed offset"));
    }
    internal static bool IsTimestamp(SheetValue value) => value.Kind is SheetValueKind.LocalTimestamp or SheetValueKind.ZonedMoment;
    internal static SheetValue Binary(string operation, SheetValue left, SheetValue right)
    {
        try
        {
            if (IsTimestamp(left) && IsTimestamp(right))
            {
                if (operation != "-" || left.Kind != right.Kind) throw new ArithmeticException("Subtract timestamps of the same type");
                return TimeArithmetic.Duration(left.Kind == SheetValueKind.LocalTimestamp ? (left.Timestamp.Value - right.Timestamp.Value).Ticks :
                    left.Moment.Instant.ToUnixTimeTicks() - right.Moment.Instant.ToUnixTimeTicks());
            }
            if (operation is not "+" and not "-" || operation == "-" && !IsTimestamp(left)) throw new ArithmeticException("Invalid timestamp arithmetic");
            var stamp = IsTimestamp(left) ? left : right; var offset = IsTimestamp(left) ? right : left; var sign = operation == "-" ? -1 : 1;
            if (offset.Kind == SheetValueKind.CalendarPeriod)
            {
                var period = offset.Period;
                var local = stamp.Kind == SheetValueKind.LocalTimestamp ? stamp.Timestamp.Value : stamp.Moment.Instant.InZone(stamp.Moment.Zone).LocalDateTime.ToDateTimeUnspecified();
                local = local.AddMonths(period.Months * sign).AddDays(period.Days * sign);
                return stamp.Kind == SheetValueKind.LocalTimestamp ? new(new LocalTimestamp(local)) : Resolve(local, stamp.Moment.Zone, stamp.Moment.RuleVersion);
            }
            var ticks = TimeArithmetic.Ticks(offset) * sign;
            if (BigInteger.Abs(ticks) > DateTime.MaxValue.Ticks) throw new ArithmeticException("Timestamp shift range exceeded");
            return stamp.Kind == SheetValueKind.LocalTimestamp ? new(new LocalTimestamp(stamp.Timestamp.Value.AddTicks((long)ticks))) :
                new(new ZonedMoment(stamp.Moment.Instant + Duration.FromTicks((long)ticks), stamp.Moment.Zone, stamp.Moment.RuleVersion));
        }
        catch (Exception error) when (error is ArgumentOutOfRangeException or OverflowException) { throw new ArithmeticException("Timestamp range exceeded"); }
    }
}
