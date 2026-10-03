using System.Collections.ObjectModel;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Media;
using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Modules.Notifications;

public enum NoteLevel { Info, Success, Warning, Error }

// ---------- wire format (pipe line, HTTP body, CLI) ----------

/// <summary>One request: <c>op</c> is "notify" (default) or "dismiss". Only <c>title</c> is required for a notify.</summary>
public sealed class NotifyRequest
{
    public string? Op { get; set; }
    /// <summary>Posting an existing id replaces that notification; "dismiss" removes it.</summary>
    public string? Id { get; set; }
    public string? App { get; set; }
    public string? Title { get; set; }
    public string? Body { get; set; }
    /// <summary>Image path, exe or shortcut path (its icon is used) or a glyph name (see NotifyIcons.Glyphs).</summary>
    public string? Icon { get; set; }
    public string? Level { get; set; }
    /// <summary>Toast seconds; 0 shows no toast. Ignored while the notification waits for an answer.</summary>
    public double? Ttl { get; set; }
    /// <summary>Keep the connection open and answer with the clicked action.</summary>
    public bool Wait { get; set; }
    /// <summary>Seconds a waiting request may stay open; missing or 0 means until answered.</summary>
    public double? Timeout { get; set; }
    public List<NotifyAction>? Actions { get; set; }
}

/// <summary>A button. With <c>url</c> it opens a link, with <c>focusPid</c> it brings that process's window forward; with neither it only answers a waiting request.</summary>
public sealed class NotifyAction
{
    public string? Id { get; set; }
    public string? Label { get; set; }
    public string? Url { get; set; }
    public int? FocusPid { get; set; }
}

internal sealed class ReplyBody
{
    public bool Ok { get; set; }
    public string? Id { get; set; }
    /// <summary>Waiting requests only: "clicked", "dismissed" or "timeout".</summary>
    public string? Result { get; set; }
    public string? Action { get; set; }
    public string? Error { get; set; }
}

/// <summary>What goes back to the sender: an HTTP status and one JSON line.</summary>
internal sealed record Reply(int Status, string Json)
{
    public static Reply Ok(string id, string? result = null, string? action = null) =>
        new(200, JsonSerializer.Serialize(new ReplyBody { Ok = true, Id = id, Result = result, Action = action }, Wire.Json));
    public static Reply Fail(int status, string error) => new(status, JsonSerializer.Serialize(new ReplyBody { Error = error }, Wire.Json));
}

internal static class Wire
{
    public const int MaxMessage = 64 * 1024;

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        AllowTrailingCommas = true,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>QNOTCH_INSTANCE keeps parallel test runs apart, like the single-instance mutex.</summary>
    public static string PipeName => "QNotch.Notify" + (Environment.GetEnvironmentVariable("QNOTCH_INSTANCE") is { Length: > 0 } i ? "." + i : "");
}

/// <summary>Sender mistake (bad field, too many actions): answered as HTTP 400 with the message.</summary>
internal sealed class NotifyException(string message) : Exception(message);

// ---------- settings and history files ----------

public sealed class NotificationSettings
{
    /// <summary>Default toast time in the glance strip; 0 turns toasts off (waiting notifications still show).</summary>
    public int ToastSeconds { get; set; } = 6;
    public int RetentionDays { get; set; } = 7;
    public bool OpenOnError { get; set; } = true;
    /// <summary>While an app uses the microphone: no toasts (except for notifications waiting for an answer) and no automatic panel. The history and unread count still update.</summary>
    public bool QuietDuringCalls { get; set; } = true;
    public bool HttpEnabled { get; set; } = true;
    public int HttpPort { get; set; } = 47821;
    /// <summary>Apps that still land in the history but never toast, count as unread or open the panel.</summary>
    public List<string> MutedApps { get; set; } = new();
}

public sealed class NotificationHistory
{
    public List<SavedNote> Items { get; set; } = new();
}

public sealed class SavedNote
{
    public string Id { get; set; } = "";
    public string App { get; set; } = "";
    public string Title { get; set; } = "";
    public string Body { get; set; } = "";
    public string? Icon { get; set; }
    public NoteLevel Level { get; set; }
    public DateTime Created { get; set; }
    public bool Read { get; set; }
    public string Status { get; set; } = "";
    /// <summary>Was still waiting for an answer when saved: shown as expired after a restart.</summary>
    public bool Pending { get; set; }
    /// <summary>Link actions only: windows and waiting senders do not survive a restart.</summary>
    public List<NotifyAction> Actions { get; set; } = new();
}

// ---------- UI model (UI thread only) ----------

public sealed class NoteAction
{
    public required Note Owner { get; init; }
    public required string Id { get; init; }
    public required string Label { get; init; }
    public string? Url { get; init; }
    /// <summary>Window to bring forward, resolved from focusPid when the notification arrived (the sender is often gone by click time).</summary>
    public nint Hwnd { get; init; }
    public bool AnswersOnly => Url is null && Hwnd == 0;
}

internal sealed record WaitResult(string Result, string? Action = null);

/// <summary>One notification. Content is immutable; icon, read flag, status and the action list change.</summary>
public sealed partial class Note : ObservableObject
{
    public required string Id { get; init; }
    public required string App { get; init; }
    public required string Title { get; init; }
    public string Body { get; init; } = "";
    public NoteLevel Level { get; init; }
    public DateTime Created { get; init; } = DateTime.Now;
    /// <summary>The icon value as sent, kept for the history file.</summary>
    public string? IconSpec { get; init; }
    /// <summary>Shown when there is no image icon: a named glyph or the level glyph.</summary>
    public string Glyph { get; init; } = NotifyIcons.Bell;
    public bool HasBody => Body.Length > 0;

    [ObservableProperty, NotifyPropertyChangedFor(nameof(HasIcon))] ImageSource? _icon;
    [ObservableProperty] bool _read;
    /// <summary>Waiting for an answer from the user.</summary>
    [ObservableProperty] bool _pending;
    /// <summary>"Waiting for your answer", "Answered: Approve", "Expired", or empty.</summary>
    [ObservableProperty, NotifyPropertyChangedFor(nameof(Meta))] string _status = "";
    [ObservableProperty, NotifyPropertyChangedFor(nameof(HasActions))] IReadOnlyList<NoteAction> _actions = [];

    public bool HasIcon => Icon is not null;
    public bool HasActions => Actions.Count > 0;
    /// <summary>"Claude Code · 5 min ago · Waiting for your answer". Relative for the first 30 minutes (the module refreshes it while the panel is open), then "14:32".</summary>
    public string Meta
    {
        get
        {
            var age = DateTime.Now - Created;
            var time = age >= TimeSpan.Zero && age.TotalMinutes < 1 ? "just now"
                : age >= TimeSpan.Zero && age.TotalMinutes < 30 ? $"{(int)age.TotalMinutes} min ago"
                : Created.Date == DateTime.Today ? Created.ToString("HH:mm", Core.UiCulture.Value) : Created.ToString("MMM d, HH:mm", Core.UiCulture.Value);
            return Status.Length > 0 ? $"{App} · {time} · {Status}" : $"{App} · {time}";
        }
    }

    internal void RefreshMeta() => OnPropertyChanged(nameof(Meta));

    internal TaskCompletionSource<WaitResult>? Waiter;
}

/// <summary>Notification history and what the pill, glance strip and game bar show. Only touched on the UI thread; the module mutates it.</summary>
public sealed partial class NotificationsState : ObservableObject
{
    /// <summary>Newest first.</summary>
    public ObservableCollection<Note> Items { get; } = new();

    [ObservableProperty] bool _hasUnread;
    [ObservableProperty] string _unreadText = "";
    [ObservableProperty] bool _isEmpty = true;
    [ObservableProperty] bool _canClear;
    [ObservableProperty] string _countText = "";
    /// <summary>The notification in the glance strip right now, or null.</summary>
    [ObservableProperty] Note? _toast;
    [ObservableProperty] string _pipeStatus = "Starting";
    [ObservableProperty] string _httpStatus = "Starting";
    /// <summary>"Quiet now: Zoom is using the microphone." while a call keeps notifications quiet, otherwise empty.</summary>
    [ObservableProperty, NotifyPropertyChangedFor(nameof(IsQuiet))] string _quietStatus = "";
    public bool IsQuiet => QuietStatus.Length > 0;

    /// <summary>Call after any change to Items or a read flag. Every write is set-if-changed.</summary>
    public void Recount()
    {
        int n = Items.Count, unread = Items.Count(i => !i.Read);
        HasUnread = unread > 0;
        UnreadText = unread > 99 ? "99+" : unread.ToString(Core.UiCulture.Value);
        IsEmpty = n == 0;
        CanClear = Items.Any(i => !i.Pending);
        CountText = n == 1 ? "1 notification" : $"{n} notifications";
    }
}
