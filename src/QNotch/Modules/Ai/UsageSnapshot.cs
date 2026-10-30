using System.Text.Json.Serialization;
using QNotch.Core.Consumers;

namespace QNotch.Modules.Ai;

internal sealed record UsageSnapshot(UsageAccountSnapshot[] Accounts);
internal sealed record UsageAccountSnapshot(string Provider, string AccountId, string Status, string? Plan, bool Refreshing,
    DateTime? CheckedAt, DateTime? ObservedAt, string Source, ConsumerError? Error, UsageWindowSnapshot[] Windows, BankedSnapshot BankedResets,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Label);
internal sealed record UsageWindowSnapshot(string Id, string Label, int? DurationSeconds, double UsedPercent, DateTime? ResetsAt);
internal sealed record BankedSnapshot(string Status, int? Count, DateTime? NextExpiresAt, string Source, DateTime? CheckedAt);

internal static class UsageProjection
{
    public static UsageAccountSnapshot Account(string provider, string accountId, bool enabled, bool refreshing, UsageResult? result, string? label, DateTime now)
    {
        var source = provider == "claude" ? "provider_api" : "session_log";
        var windows = enabled && result?.Status == UsageStatus.Ok
            ? result.Windows.Where(w => w.ResetsAt is null || w.ResetsAt.Value.ToUniversalTime() > now)
                .Select(w => new UsageWindowSnapshot(w.Id ?? "unknown", w.Label, w.DurationSeconds, w.UsedPercent, w.ResetsAt?.ToUniversalTime())).ToArray() : [];
        var status = !enabled ? "disabled" : result is null ? "pending" : result.Status == UsageStatus.Ok && windows.Length > 0 ? "ok" : "unavailable";
        ConsumerError? error = status != "unavailable" ? null : result?.Status == UsageStatus.Ok
            ? new("expired_reading", "No unexpired quota windows remain. Wait for a provider update.")
            : new(result?.ErrorCode ?? "unavailable", result?.Reason ?? "Quota reading is unavailable.");
        var banked = enabled ? result?.Banked : null;
        var bankedStatus = !enabled ? "unknown" : banked is { Count: > 0 } ? "available" : result?.BankedStatus ?? "unknown";
        // A cached credit count past its next expiry cannot establish the remaining usable count.
        if (banked?.ExpiresAt?.ToUniversalTime() <= now) { banked = null; bankedStatus = "unknown"; }
        return new(provider, accountId, status, status == "ok" ? result?.Plan : null, enabled && refreshing,
            enabled ? result?.CheckedAt?.ToUniversalTime() : null, status == "ok" ? result?.AsOf.ToUniversalTime() : null, source, error,
            windows, new(bankedStatus, bankedStatus == "available" ? banked?.Count : bankedStatus == "none" ? 0 : null,
                banked?.ExpiresAt?.ToUniversalTime(), provider == "claude" ? "provider_api" : "codex_app_server", enabled ? result?.BankedCheckedAt?.ToUniversalTime() : null),
            ConsumerProtocol.Text(label));
    }
}

public sealed partial class AiModule
{
    ConsumerIdentity _consumerIdentity = null!;

    UsageSnapshot CaptureUsage(ConsumerRequest request)
    {
        var now = DateTime.UtcNow;
        if (_providers.Length > 1024) throw new ConsumerException("size_limit", "Too many accounts for one snapshot.");
        var accounts = _providers.Select(p =>
        {
            var group = Group(p);
            var directory = p is ClaudeCodeProvider c ? c.Dir : Environment.GetEnvironmentVariable("CODEX_HOME") is { Length: > 0 } home
                ? home : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
            var identity = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant();
            var id = _consumerIdentity.Id("account:" + group, identity);
            var label = request.Details ? p is ClaudeCodeProvider claude ? _s.AccountNames.GetValueOrDefault(p.Id) ?? claude.Account : p.Name : null;
            return UsageProjection.Account(group, id, _s.IsEnabled(group), _refreshing, _results.GetValueOrDefault(p.Id), label, now);
        }).Where(a => request.Provider is null || a.Provider == request.Provider).ToArray();
        if (request.Account is not null)
        {
            accounts = accounts.Where(a => a.AccountId == request.Account).ToArray();
            if (accounts.Length == 0) throw new ConsumerException("invalid_arguments", "Unknown account for the selected provider.");
        }
        return new(accounts);
    }
}
