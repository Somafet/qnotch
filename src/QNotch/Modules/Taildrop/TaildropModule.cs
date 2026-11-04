using System.Diagnostics;
using System.Net.Http;
using System.Windows.Threading;
using QNotch.Core;

namespace QNotch.Modules.Taildrop;

/// <summary>What the views show. UI thread only. <see cref="Changed"/> fires when devices or availability differ,
/// <see cref="TransferChanged"/> when the send or save line does.</summary>
internal sealed class TaildropState
{
    public TaildropAvailability Availability { get; private set; } = TaildropAvailability.Loading;
    public IReadOnlyList<TaildropDevice> Devices { get; private set; } = [];
    public IReadOnlyList<TaildropWaitingFile> Waiting { get; private set; } = [];
    /// <summary>The last refresh failed with this message (the previous lists stay).</summary>
    public string Error { get; private set; } = "";
    public event Action? Changed;

    public bool Busy { get; private set; }
    /// <summary>The device a send is going to, so its tile can show it.</summary>
    public string? BusyDevice { get; private set; }
    /// <summary>"Sending photo.jpg · 2 of 3", or the outcome of the last action ("Sent 3 files to pixel"). Empty when idle.</summary>
    public string Line { get; private set; } = "";
    /// <summary>Brush key for <see cref="Line"/>: TextSecondaryBrush, SuccessBrush or DangerBrush.</summary>
    public string LineBrush { get; private set; } = "TextSecondaryBrush";
    /// <summary>0..1 while a send runs, otherwise -1.</summary>
    public double Progress { get; private set; } = -1;
    /// <summary>The newest file a save moved to Downloads, for the Show button.</summary>
    public string? Saved { get; private set; }
    public event Action? TransferChanged;

    public void Set(TaildropAvailability availability, IReadOnlyList<TaildropDevice>? devices, IReadOnlyList<TaildropWaitingFile>? waiting, string error)
    {
        devices ??= availability == TaildropAvailability.Ready ? Devices : [];
        waiting ??= availability == TaildropAvailability.Ready ? Waiting : [];
        if (Availability == availability && Error == error && Devices.SequenceEqual(devices) && Waiting.SequenceEqual(waiting)) return;
        (Availability, Devices, Waiting, Error) = (availability, devices, waiting, error);
        Changed?.Invoke();
    }

    public void SetTransfer(bool busy, string? device, string line, string brush, double progress, string? saved = null)
    {
        saved ??= busy ? null : Saved;
        if (Busy == busy && BusyDevice == device && Line == line && LineBrush == brush && Progress.Equals(progress) && Saved == saved) return;
        (Busy, BusyDevice, Line, LineBrush, Progress, Saved) = (busy, device, line, brush, progress, saved);
        TransferChanged?.Invoke();
    }
}

/// <summary>
/// Taildrop: send files to your devices on Tailscale, and save files that wait in the Tailscale inbox. It talks to the local Tailscale
/// service only while the panel is open (a refresh when it opens, then every 10 s while the Taildrop tab or Home is showing) and while a
/// transfer the user started runs. Nothing runs while collapsed.
/// </summary>
public sealed class TaildropModule : INotchModule, ICadenceAware
{
    internal const string TabId = "taildrop", Icon = "";
    static readonly TimeSpan RefreshEvery = TimeSpan.FromSeconds(10);

    readonly TaildropState _st = new();
    ModuleContext _ctx = null!;
    TaildropClient? _client;
    DispatcherTimer? _timer;
    CancellationTokenSource? _transfer;
    Cadence _cadence = Cadence.Slow;
    bool _refreshing, _again;

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        ctx.Tabs.Register(new TabDescriptor(TabId, "Taildrop", Icon, 45, () => new TaildropTab(this, _st, ctx.Shell)));
        ctx.Cards.Register(new CardDescriptor(TabId, "Taildrop", 85, () => new TaildropCard(this, _st, ctx.Shell)));
        ctx.Drops.Register(new DropSourceDescriptor(TabId, "Taildrop", Icon, 20, files => DropTargets(_st, files, Directory.Exists, (d, paths) =>
        {
            Send(d, paths);
            ctx.Shell.SelectTab(TabId);
        })));
        if (ctx.Settings.ReadOnly) { Seed(); return; }
        _client = new TaildropClient();
        ctx.Shell.FileDragEntered += Refresh; // the drop screen asks again while it shows, so devices arrive in time
        ctx.Shell.TabChanged += _ => { UpdateTimer(); if (_cadence == Cadence.Fast && Watching) Refresh(); };
    }

    public void SetCadence(Cadence cadence)
    {
        _cadence = cadence;
        if (cadence == Cadence.Fast) Refresh();
        UpdateTimer();
    }

    bool Watching => _ctx.Shell.ActiveTab is TabId or "home";

    void UpdateTimer()
    {
        if (_client is null) return;
        var on = _cadence == Cadence.Fast && Watching;
        if (on && _timer is null)
        {
            _timer = new DispatcherTimer(DispatcherPriority.Background, _ctx.Dispatcher) { Interval = RefreshEvery };
            _timer.Tick += (_, _) => Refresh();
        }
        if (on) _timer!.Start(); else _timer?.Stop();
    }

    /// <summary>Reads availability, devices and waiting files on the thread pool. A refresh asked for while one runs follows it.</summary>
    internal void Refresh()
    {
        if (_client is not { } client) return;
        if (_refreshing) { _again = true; return; }
        _refreshing = true;
        Task.Run(async () =>
        {
            TaildropAvailability availability;
            IReadOnlyList<TaildropDevice>? devices = null;
            IReadOnlyList<TaildropWaitingFile>? waiting = null;
            var error = "";
            try
            {
                availability = await client.GetAvailabilityAsync(default).ConfigureAwait(false);
                if (availability == TaildropAvailability.Ready)
                {
                    devices = await client.GetTargetsAsync(default).ConfigureAwait(false);
                    try { waiting = await client.GetWaitingAsync(default).ConfigureAwait(false); }
                    catch (TaildropException) { waiting = []; } // the inbox is optional: a device that cannot list it still sends
                }
            }
            catch (Exception ex) when (IsUnreachable(ex)) { availability = TaildropClient.IsInstalled() ? TaildropAvailability.NotRunning : TaildropAvailability.NotInstalled; }
            catch (Exception ex)
            {
                Log.Warn("Taildrop: refresh failed", ex);
                availability = TaildropAvailability.Ready;
                error = ex is TaildropException ? ex.Message : "Tailscale could not be read.";
            }
            _ctx.Bus.Run(() =>
            {
                _st.Set(availability, devices, waiting, error);
                _refreshing = false;
                if (_again) { _again = false; Refresh(); }
            });
        });
    }

    static bool IsUnreachable(Exception ex) => ex is TimeoutException or IOException or HttpRequestException or OperationCanceledException
        || ex.InnerException is { } inner && IsUnreachable(inner);

    /// <summary>Sends the files among <paramref name="paths"/> to <paramref name="device"/>, one after another. Folders are skipped.</summary>
    internal void Send(TaildropDevice device, IReadOnlyList<string> paths)
    {
        if (_st.Busy || !device.Online) return;
        var files = paths.Where(File.Exists).ToList();
        var skipped = paths.Count - files.Count;
        if (files.Count == 0)
        {
            _st.SetTransfer(false, null, paths.Any(Directory.Exists) ? "Folders can't be sent. Send the files inside, or a zip." : "Nothing to send.", "DangerBrush", -1);
            return;
        }
        if (_client is not { } client)
        {
            _st.SetTransfer(false, null, $"Sent {Count(files.Count)} to {device.Name}", "SuccessBrush", -1); // snapshot: nothing leaves the machine
            return;
        }
        var cts = _transfer = new CancellationTokenSource();
        var total = files.Sum(f => new FileInfo(f).Length);
        _st.SetTransfer(true, device.Id, Sending(files, 0, device), "TextSecondaryBrush", 0);
        Task.Run(async () =>
        {
            long before = 0;
            var lastPercent = -1;
            var sent = 0;
            string? failure = null;
            try
            {
                for (var i = 0; i < files.Count; i++)
                {
                    var index = i;
                    var text = Sending(files, index, device);
                    await client.SendAsync(device.Id, files[i], done =>
                    {
                        var percent = total > 0 ? (int)Math.Min(100, (before + done) * 100 / total) : 100;
                        if (percent == lastPercent) return;
                        lastPercent = percent;
                        _ctx.Bus.Run(() => { if (_transfer == cts) _st.SetTransfer(true, device.Id, text, "TextSecondaryBrush", percent / 100.0); });
                    }, cts.Token).ConfigureAwait(false);
                    before += new FileInfo(files[i]).Length;
                    sent++;
                }
            }
            catch (OperationCanceledException) when (cts.IsCancellationRequested) { failure = sent > 0 ? $"Stopped after {Count(sent)}." : "Sending stopped."; }
            catch (Exception ex)
            {
                Log.Warn($"Taildrop: send to {device.Name} failed", ex);
                failure = ex is TaildropException ? ex.Message : IsUnreachable(ex) ? "Tailscale stopped answering." : "The file could not be sent.";
            }
            _ctx.Bus.Run(() =>
            {
                if (_transfer == cts) _transfer = null;
                cts.Dispose();
                if (failure is null)
                {
                    var done = $"Sent {Count(sent)} to {device.Name}" + (skipped > 0 ? $" ({Count(skipped, "folder")} skipped)" : "");
                    _st.SetTransfer(false, null, done, "SuccessBrush", -1);
                    _ctx.Shell.Peek(Icon, done, "SuccessBrush");
                }
                else
                {
                    _st.SetTransfer(false, null, failure, "DangerBrush", -1);
                    if (!cts.IsCancellationRequested) _ctx.Shell.Peek(Icon, $"Taildrop: {failure}", "DangerBrush");
                }
            });
        });
    }

    internal void Cancel() => _transfer?.Cancel();

    /// <summary>The drop screen tiles: one per device while Tailscale is ready, otherwise one disabled tile that says why.</summary>
    internal static IReadOnlyList<DropTarget> DropTargets(TaildropState st, IReadOnlyList<string> files, Func<string, bool> isFolder, Action<TaildropDevice, string[]> send)
    {
        if (TaildropEmpty.For(st) is { } empty) return [new DropTarget("unavailable", empty.Title, Icon, _ => { }, Enabled: false)];
        if (st.Availability != TaildropAvailability.Ready) return [new DropTarget("unavailable", "Checking Tailscale", Icon, _ => { }, "One moment", Enabled: false)];
        var folders = files.Count > 0 && files.All(isFolder);
        return st.Devices.Select(d =>
        {
            var reason = st.Busy ? "Busy sending" : !d.Online ? "Offline" : folders ? "Folders can't be sent" : null;
            var os = TaildropUi.OsName(d.Os);
            return new DropTarget(d.Id, d.Name, TaildropUi.DeviceGlyph(d), paths => send(d, paths), reason ?? (os.Length > 0 ? os : "Online"), Enabled: reason is null);
        }).ToList();
    }

    /// <summary>Moves every waiting file into Downloads.</summary>
    internal void SaveWaiting()
    {
        if (_st.Busy || _st.Waiting.Count == 0) return;
        var names = _st.Waiting.Select(w => w.Name).ToList();
        if (_client is not { } client)
        {
            _st.SetTransfer(false, null, $"Saved {Count(names.Count)} to Downloads", "SuccessBrush", -1);
            return;
        }
        _st.SetTransfer(true, null, $"Saving {Count(names.Count)} to Downloads", "TextSecondaryBrush", -1);
        Task.Run(async () =>
        {
            var folder = TaildropNative.DownloadsFolder();
            string? last = null, failure = null;
            var saved = 0;
            foreach (var name in names)
            {
                try { last = await client.SaveWaitingAsync(name, folder, default).ConfigureAwait(false); saved++; }
                catch (Exception ex)
                {
                    Log.Warn($"Taildrop: saving a waiting file failed", ex);
                    failure = ex is TaildropException ? ex.Message : "A file could not be saved to Downloads.";
                }
            }
            _ctx.Bus.Run(() =>
            {
                _st.SetTransfer(false, null, failure ?? $"Saved {Count(saved)} to Downloads", failure is null ? "SuccessBrush" : "DangerBrush", -1, last);
                Refresh();
            });
        });
    }

    internal void ShowSaved()
    {
        if (_st.Saved is not { } path) return;
        try { Process.Start(new ProcessStartInfo("explorer.exe") { Arguments = $"/select,\"{path}\"", UseShellExecute = true }); }
        catch (Exception ex) { Log.Warn("Taildrop: show saved file failed", ex); }
    }

    internal void OpenTailscale()
    {
        if (_client is null) return;
        var exe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Tailscale", "tailscale-ipn.exe");
        try { Process.Start(new ProcessStartInfo(File.Exists(exe) ? exe : "https://tailscale.com/download/windows") { UseShellExecute = true }); }
        catch (Exception ex) { Log.Warn("Taildrop: open Tailscale failed", ex); }
    }

    static string Sending(List<string> files, int index, TaildropDevice device) =>
        $"Sending {Path.GetFileName(files[index])} to {device.Name}" + (files.Count > 1 ? $" · {index + 1} of {files.Count}" : "");

    internal static string Count(int n, string noun = "file") => n == 1 ? $"1 {noun}" : $"{n} {noun}s";

    void Seed()
    {
        _st.Set(TaildropAvailability.Ready,
        [
            new("demo-phone", "pixel-8", "android", true),
            new("demo-laptop", "work-laptop", "windows", true),
            new("demo-tablet", "ipad-air", "iOS", true),
            new("demo-nas", "home-nas", "linux", false),
        ], [new("holiday-photos.zip", 48_200_000)], "");
    }
}
