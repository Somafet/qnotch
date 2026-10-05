using System.Collections.ObjectModel;
using QNotch.Core;
using System.Windows.Media;
using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Modules.Ai;

public enum UsageStatus { Pending, Ok, Unavailable }

/// <summary>One usage window as reported by a provider (for example the 5-hour window).</summary>
public sealed record UsageWindow(string Label, double UsedPercent, DateTime? ResetsAt);

/// <summary>Usage resets banked on a Claude subscription: how many are usable now, and when the next one expires.</summary>
public sealed record BankedResets(int Count, DateTime? ExpiresAt);

/// <summary>Provider outcome. Unavailable never carries numbers, so it can never render as 0%.</summary>
public sealed record UsageResult(UsageStatus Status, IReadOnlyList<UsageWindow> Windows, string? Plan, DateTime AsOf, string? Reason, BankedResets? Banked = null)
{
    public static UsageResult Ok(IReadOnlyList<UsageWindow> windows, string? plan, DateTime asOf, BankedResets? banked = null) => new(UsageStatus.Ok, windows, plan, asOf, null, banked);
    public static UsageResult Unavailable(string reason) => new(UsageStatus.Unavailable, [], null, DateTime.Now, reason);
}

/// <summary>A usage source. Each one is isolated: own timeout, own try/catch, never affects the others.</summary>
public interface IUsageProvider
{
    string Id { get; }
    string Name { get; }
    Task<UsageResult> FetchAsync(CancellationToken ct);
}

public sealed partial class AiAppItem : ObservableObject
{
    public AiAppItem(string id, string name, string target, bool isCustom)
    {
        Id = id; _name = name; Target = target; IsCustom = isCustom;
    }

    public string Id { get; }
    /// <summary>Path to an exe or .lnk, or shell:AppsFolder\AUMID for Store apps.</summary>
    public string Target { get; }
    public bool IsCustom { get; }

    [ObservableProperty] private string _name;
    [ObservableProperty] private ImageSource? _icon;
    [ObservableProperty] private int _slot;
    [ObservableProperty] private bool _hotkeyConflict;
    /// <summary>The gesture of the slot's shortcut, empty without a slot or when the user turned it off.</summary>
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Tooltip))] private string _hotkey = "";
    [ObservableProperty] private string _error = "";

    public string Initial => Name.Length > 0 ? Name[..1].ToUpperInvariant() : "?";
    public string Tooltip => Name
        + (Hotkey.Length > 0 ? $"\n{Hotkey}" + (HotkeyConflict ? " (taken by another app)" : "") : "")
        + (Error.Length > 0 ? "\n" + Error : "");

    partial void OnNameChanged(string value) { OnPropertyChanged(nameof(Initial)); OnPropertyChanged(nameof(Tooltip)); }
    partial void OnSlotChanged(int value) => OnPropertyChanged(nameof(Tooltip));
    partial void OnHotkeyConflictChanged(bool value) => OnPropertyChanged(nameof(Tooltip));
    partial void OnErrorChanged(string value) => OnPropertyChanged(nameof(Tooltip));
}

public sealed partial class AiWindowItem : ObservableObject
{
    DateTime? _resetsAt;

    [ObservableProperty] private string _label = "";
    [ObservableProperty] private double _usedPercent;
    [ObservableProperty] private string _usedText = "";
    [ObservableProperty] private string _leftText = "";
    [ObservableProperty] private string _resetText = "";
    [ObservableProperty] private string _resetTip = "";

    public void Set(UsageWindow w)
    {
        Label = w.Label;
        UsedPercent = w.UsedPercent;
        UsedText = $"{(int)Math.Round(w.UsedPercent)}%";
        LeftText = $"{(int)Math.Round(100 - w.UsedPercent)}% left";
        _resetsAt = w.ResetsAt;
        RefreshReset();
    }

    /// <summary>Recomputes the relative reset text (cheap; called on refresh and when the panel opens).</summary>
    public void RefreshReset()
    {
        if (_resetsAt is not { } at) { ResetText = ""; ResetTip = ""; return; }
        var left = at - DateTime.Now;
        ResetText = left <= TimeSpan.Zero ? "Reset, refresh for a new reading" : "Resets " + AiFormat.In(left);
        ResetTip = "Resets " + AiFormat.When(at);
    }
}

/// <summary>One sign-in of a provider. Id is the usage provider id, Dir its config folder, Name what the user calls it.</summary>
public sealed partial class AiAccount(string id, string name, string dir) : ObservableObject
{
    public string Id { get; } = id;
    public string Dir { get; } = dir;
    [ObservableProperty] private string _name = name;
}

public sealed partial class AiProviderItem : ObservableObject
{
    public AiProviderItem(string id, string name) { Id = id; Name = name; }

    public string Id { get; }
    public string Name { get; }
    public ObservableCollection<AiWindowItem> Windows { get; } = new();

    /// <summary>Accounts to choose from; the row shows the selected one. A dropdown appears with two or more.</summary>
    public IReadOnlyList<AiAccount> Accounts { get; init; } = [];
    public bool HasAccounts => Accounts.Count > 1;
    public Action<AiAccount>? AccountChanged { get; set; }
    [ObservableProperty] private AiAccount? _account;
    // A ComboBox writes null while its row unloads; that is not a choice.
    partial void OnAccountChanged(AiAccount? value) { if (value is not null) AccountChanged?.Invoke(value); }

    [ObservableProperty] private UsageStatus _status = UsageStatus.Pending;
    [ObservableProperty] private string _reason = "";
    [ObservableProperty] private string _plan = "";
    [ObservableProperty] private string _updatedText = "";
    [ObservableProperty] private string _headlineText = "";
    [ObservableProperty] private double _headlinePercent;
    [ObservableProperty] private string _subText = "";
    [ObservableProperty] private string _bankedText = "";
    [ObservableProperty] private string _bankedTip = "";
    BankedResets? _banked;

    public bool IsOk => Status == UsageStatus.Ok;
    public bool IsUnavailable => Status == UsageStatus.Unavailable;
    public bool IsPending => Status == UsageStatus.Pending;
    public bool HasPlan => Plan.Length > 0;
    public string Tooltip => IsOk ? UpdatedText : IsUnavailable ? Reason : "Waiting for the first reading";

    partial void OnStatusChanged(UsageStatus value)
    {
        OnPropertyChanged(nameof(IsOk)); OnPropertyChanged(nameof(IsUnavailable)); OnPropertyChanged(nameof(IsPending)); OnPropertyChanged(nameof(Tooltip));
    }
    partial void OnPlanChanged(string value) => OnPropertyChanged(nameof(HasPlan));
    partial void OnReasonChanged(string value) => OnPropertyChanged(nameof(Tooltip));
    partial void OnUpdatedTextChanged(string value) => OnPropertyChanged(nameof(Tooltip));
    partial void OnBankedTextChanged(string value) => OnPropertyChanged(nameof(HasBanked));
    public bool HasBanked => BankedText.Length > 0;

    public void Apply(UsageResult r)
    {
        if (r.Status == UsageStatus.Ok && r.Windows.Count > 0)
        {
            while (Windows.Count > r.Windows.Count) Windows.RemoveAt(Windows.Count - 1);
            for (var i = 0; i < r.Windows.Count; i++)
            {
                if (i == Windows.Count) Windows.Add(new AiWindowItem());
                Windows[i].Set(r.Windows[i]);
            }
            Plan = r.Plan ?? "";
            Reason = "";
            UpdatedText = "Updated " + AiFormat.When(r.AsOf);
            _banked = r.Banked;
            Status = UsageStatus.Ok;
        }
        else
        {
            Windows.Clear();
            Plan = "";
            Reason = r.Reason ?? "No data";
            UpdatedText = "";
            _banked = null;
            Status = UsageStatus.Unavailable;
        }
        RefreshCard();
    }

    public void RefreshTexts()
    {
        foreach (var w in Windows) w.RefreshReset();
        RefreshCard();
    }

    void RefreshCard()
    {
        RefreshBanked();
        if (Status == UsageStatus.Ok && Windows.Count > 0)
        {
            var w0 = Windows[0];
            HeadlineText = w0.UsedText;
            HeadlinePercent = w0.UsedPercent;
            var reset = w0.ResetText.Length > 0 ? w0.ResetText.ToLowerInvariant() : w0.Label;
            SubText = Windows.Count > 1 ? $"{Windows[1].Label} {Windows[1].UsedText}  ·  {reset}" : reset;
        }
        else
        {
            HeadlineText = Status == UsageStatus.Pending ? "Checking" : "Unavailable";
            HeadlinePercent = 0;
            SubText = Status == UsageStatus.Pending ? "" : Reason;
        }
    }

    void RefreshBanked()
    {
        if (_banked is not { Count: > 0 } b) { BankedText = ""; BankedTip = ""; return; }
        var text = b.Count == 1 ? "1 banked reset" : $"{b.Count} banked resets";
        if (b.ExpiresAt is { } at && at > DateTime.Now) text += "  ·  expires " + AiFormat.In(at - DateTime.Now);
        BankedText = text;
        BankedTip = b.ExpiresAt is { } e ? "Next one expires " + e.ToString("d MMM HH:mm", UiCulture.Value) : "Does not expire";
    }
}

static class AiFormat
{
    public static string When(DateTime t) => t.Date == DateTime.Today ? t.ToString("HH:mm", UiCulture.Value) : t.ToString("ddd HH:mm", UiCulture.Value);

    public static string In(TimeSpan d) =>
        d.TotalMinutes < 1 ? "in under a minute"
        : d.TotalHours < 1 ? $"in {(int)d.TotalMinutes}m"
        : d.TotalDays < 1 ? $"in {(int)d.TotalHours}h {d.Minutes}m"
        : $"in {(int)d.TotalDays}d {d.Hours}h";
}
