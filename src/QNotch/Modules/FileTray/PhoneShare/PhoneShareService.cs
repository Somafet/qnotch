using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Windows;
using System.Windows.Threading;
using QNotch.Core;

namespace QNotch.Modules.FileTray;

/// <summary>A LAN address the phone can try, with the adapter it belongs to.</summary>
public sealed record ShareAddress(string Ip, string Adapter)
{
    public override string ToString() => $"{Ip}  ({Adapter})";
}

/// <summary>
/// Phone sharing, UI thread API. Starts a session (token, frozen file list, listener on a free port), shows its URL as a QR code, ends it
/// on Stop, expiry (one-shot timer) or application exit. Server callbacks arrive on the thread pool and reach the state through the bus.
/// Received files land in <c>Downloads\QNotch</c> and join the tray once complete. Nothing listens while no session runs.
/// </summary>
public sealed class PhoneShareService : IPhoneShareEvents
{
    static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(15), MaxLeft = TimeSpan.FromHours(2);
    static readonly string[] Virtual = ["Hyper-V", "VMware", "VirtualBox", "WSL", "vEthernet", "Loopback"];
    const int MaxRows = 50;

    readonly ModuleContext _ctx;
    readonly FileTrayState _tray;
    readonly FileTrayService _traySvc;
    readonly PhoneShareState _s;
    readonly Dictionary<int, PhoneTransfer> _rows = new();
    readonly HashSet<IPAddress> _devices = new();
    readonly HashSet<string> _unchecked = new(StringComparer.OrdinalIgnoreCase);
    PhoneShareSession? _session;
    int _port, _nextId;
    System.Threading.Timer? _expiry;
    DispatcherTimer? _tick;
    bool _fast, _scanning;

    public PhoneShareService(ModuleContext ctx, FileTrayState tray, FileTrayService traySvc)
    {
        _ctx = ctx;
        _tray = tray;
        _traySvc = traySvc;
        _s = tray.Share;
        _s.PropertyChanged += OnStateChanged;
        _tray.Items.CollectionChanged += (_, _) => { if (_s.IsOpen && !_s.IsActive) Rebuild(); };
        if (ctx.Settings.ReadOnly) { Seed(); return; } // snapshot run: demo state, never listens
        Application.Current.Exit += (_, _) => _session?.Stop(waitMs: 1000);
    }

    // ---------- view ----------

    /// <summary>Shows the sharing view in the Files tab.</summary>
    public void Open()
    {
        if (!_s.IsActive) Rebuild();
        _s.IsOpen = true;
        if (!_s.IsActive) FindAddresses();
    }

    /// <summary>Shows the sharing view with only <paramref name="item"/> selected (the tile's context menu). A running session keeps its files.</summary>
    public void OpenWith(TrayItem item)
    {
        if (_s.IsActive)
        {
            Open();
            if (!_s.Choices.Any(c => c.Item == item)) SetStatus($"Already sharing other files. Stop sharing to share {item.Name}.", true);
            return;
        }
        _unchecked.Clear();
        foreach (var it in _tray.Items) if (it != item) _unchecked.Add(it.Path);
        Open();
    }

    /// <summary>Back to the tray. A running session keeps running.</summary>
    public void Close() => _s.IsOpen = false;

    public void SelectAll(bool on)
    {
        if (_s.IsActive) return;
        foreach (var c in _s.Choices) if (c.CanShare) c.IsChecked = on;
    }

    /// <summary>The panel opened (Fast) or closed: the countdown text only ticks while it can be seen.</summary>
    public void SetCadence(Cadence c)
    {
        _fast = c == Cadence.Fast;
        UpdateTimeLeft();
    }

    void Rebuild()
    {
        foreach (var c in _s.Choices) c.PropertyChanged -= OnChoiceChanged;
        _s.Choices.Clear();
        foreach (var it in _tray.Items)
        {
            var c = new ShareChoice(it);
            if (_unchecked.Contains(it.Path)) c.IsChecked = false;
            c.PropertyChanged += OnChoiceChanged;
            _s.Choices.Add(c);
        }
        Summarize();
    }

    void OnChoiceChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (sender is not ShareChoice c || e.PropertyName != nameof(ShareChoice.IsChecked)) return;
        if (c.IsChecked) _unchecked.Remove(c.Item.Path); else _unchecked.Add(c.Item.Path);
        Summarize();
    }

    void Summarize()
    {
        _s.HasChoices = _s.Choices.Count > 0;
        var n = _s.Choices.Count(c => c.IsChecked && c.CanShare);
        _s.SelectionText = _s.IsActive
            ? n == 0 ? "Receiving only" : n == 1 ? "Sharing 1 file" : $"Sharing {n} files"
            : _s.Choices.Count == 0 ? "No files in the tray" : $"{n} of {_s.Choices.Count(c => c.CanShare)} files selected";
    }

    void OnStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(PhoneShareState.Address) && _s.IsActive) ShowUrl();
    }

    // ---------- network ----------

    void FindAddresses()
    {
        if (_scanning) return;
        _scanning = true;
        Task.Run(() =>
        {
            List<ShareAddress> found;
            try { found = Candidates(); }
            catch (Exception ex) { Log.Warn("Phone sharing: listing network adapters failed", ex); found = []; }
            _ctx.Bus.Run(() =>
            {
                _scanning = false;
                var keep = _s.Address?.Ip;
                _s.Addresses.Clear();
                foreach (var a in found) _s.Addresses.Add(a);
                _s.Address = found.FirstOrDefault(a => a.Ip == keep) ?? found.FirstOrDefault();
                _s.HasManyAddresses = found.Count > 1;
                _s.CanStart = found.Count > 0;
                if (!_s.IsActive) SetStatus(found.Count > 0 ? "" : "This PC is not connected to a network.", found.Count == 0);
            });
        });
    }

    /// <summary>IPv4 addresses of working, physical adapters: those with a default gateway first, virtual switches and VPN-like tunnels skipped.</summary>
    static List<ShareAddress> Candidates()
    {
        var list = new List<(ShareAddress A, bool Gateway)>();
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
            if (Virtual.Any(v => ni.Name.Contains(v, StringComparison.OrdinalIgnoreCase) || ni.Description.Contains(v, StringComparison.OrdinalIgnoreCase))) continue;
            var props = ni.GetIPProperties();
            var gateway = props.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any));
            foreach (var ua in props.UnicastAddresses)
            {
                var ip = ua.Address;
                if (ip.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(ip)) continue;
                var b = ip.GetAddressBytes();
                if (b[0] == 169 && b[1] == 254) continue; // link-local: no DHCP answer, unreachable from a phone
                list.Add((new ShareAddress(ip.ToString(), ni.Name), gateway));
            }
        }
        return list.OrderBy(x => x.Gateway ? 0 : 1).Select(x => x.A).DistinctBy(a => a.Ip).ToList();
    }

    // ---------- session ----------

    public void Start()
    {
        if (_s.IsActive || _ctx.Settings.ReadOnly || _s.Address is null) return;
        var shared = _s.Choices.Where(c => c.IsChecked && c.CanShare).ToList();
        var folder = Path.Combine(PhoneShareNative.DownloadsFolder(), "QNotch");
        var session = new PhoneShareSession(shared.Select(c => c.Item.Path), folder, DateTime.UtcNow + Lifetime);
        var server = new PhoneShareServer(session, this);
        try { server.Start(); }
        catch (SocketException ex)
        {
            Log.Warn("Phone sharing: could not listen", ex);
            SetStatus("Could not start: no free network port. Try again.", true);
            return;
        }
        _session = session;
        _port = server.Port;
        _devices.Clear();
        _rows.Clear();
        _s.Transfers.Clear();
        _s.HasTransfers = false;

        // Freeze: the view lists exactly what the phone can download.
        foreach (var c in _s.Choices.Where(c => !shared.Contains(c)).ToList()) { c.PropertyChanged -= OnChoiceChanged; _s.Choices.Remove(c); }
        _s.IsActive = true;
        _s.CanExtend = true;
        Summarize();
        ShowUrl();
        SetStatus("Waiting for your phone. Point its camera at the code.", false);
        ArmExpiry();
        UpdateTimeLeft();
        Log.Info($"Phone sharing started on port {_port} with {shared.Count} file(s)");
    }

    public void Stop() => End("Sharing stopped.");

    /// <summary>Adds 15 minutes (at most two hours left).</summary>
    public void Extend()
    {
        if (_session is not { } s) return;
        var now = DateTime.UtcNow;
        var deadline = s.Deadline + Lifetime;
        if (deadline - now > MaxLeft) deadline = now + MaxLeft;
        s.Deadline = deadline;
        _s.CanExtend = deadline - now < MaxLeft - TimeSpan.FromMinutes(1);
        ArmExpiry();
        UpdateTimeLeft();
    }

    void End(string reason)
    {
        if (_session is not { } s) return;
        _session = null;
        s.Stop();
        _expiry?.Dispose();
        _expiry = null;
        _tick?.Stop();
        _s.IsActive = false;
        _s.Url = "";
        _s.Qr = null;
        _s.TimeLeft = "";
        _s.CanExtend = false;
        foreach (var r in _s.Transfers.Where(r => r.IsRunning)) Fail(r, "Stopped");
        SetStatus(reason, false);
        Rebuild();
        if (_s.IsOpen) FindAddresses();
        Log.Info("Phone sharing ended: " + reason);
    }

    void ShowUrl()
    {
        if (_session is null || _s.Address is null) return;
        _s.Url = $"http://{_s.Address.Ip}:{_port}/s/{_session.Token}/";
        _s.Qr = QrImage.Create(QrCode.Encode(_s.Url));
    }

    void ArmExpiry()
    {
        if (_session is not { } s) return;
        var due = s.Deadline - DateTime.UtcNow;
        if (due < TimeSpan.Zero) due = TimeSpan.Zero;
        _expiry ??= new System.Threading.Timer(_ => _ctx.Bus.Run(OnExpiry));
        _expiry.Change(due + TimeSpan.FromMilliseconds(50), Timeout.InfiniteTimeSpan);
    }

    void OnExpiry()
    {
        if (_session is not { } s) return;
        if (DateTime.UtcNow >= s.Deadline) End("Sharing ended after the time ran out.");
        else ArmExpiry(); // extended meanwhile
    }

    /// <summary>"14 min left", re-armed for the moment the minute changes, only while the panel is open.</summary>
    void UpdateTimeLeft()
    {
        _tick?.Stop();
        if (_session is not { } s) return;
        var left = s.Deadline - DateTime.UtcNow;
        var mins = Math.Max(1, (int)Math.Ceiling(left.TotalMinutes));
        _s.TimeLeft = mins == 1 ? "Ends in 1 min" : $"Ends in {mins} min";
        if (!_fast) return;
        var next = left - TimeSpan.FromMinutes(mins - 1) + TimeSpan.FromMilliseconds(50);
        if (next < TimeSpan.FromMilliseconds(200)) next = TimeSpan.FromMilliseconds(200);
        if (_tick is null)
        {
            _tick = new DispatcherTimer(DispatcherPriority.Background);
            _tick.Tick += (_, _) => UpdateTimeLeft();
        }
        _tick.Interval = next;
        _tick.Start();
    }

    void SetStatus(string text, bool error)
    {
        _s.Status = text;
        _s.IsError = error;
    }

    // ---------- transfers ----------

    public void Reveal(PhoneTransfer t)
    {
        if (t.SavedPath is not { } p) return;
        Task.Run(() =>
        {
            try { Process.Start(new ProcessStartInfo("explorer.exe") { Arguments = $"/select,\"{p}\"" })?.Dispose(); }
            catch (Exception ex) { Log.Warn("Phone sharing: could not show the received file", ex); }
        });
    }

    void Fail(PhoneTransfer r, string reason)
    {
        if (r.IsDone) return;
        r.IsFailed = true;
        r.Detail = reason;
    }

    void IPhoneShareEvents.Seen(IPAddress device) => _ctx.Bus.Run(() =>
    {
        if (!_s.IsActive || !_devices.Add(device)) return;
        SetStatus(_devices.Count == 1 ? "Phone connected." : $"{_devices.Count} devices connected.", false);
    });

    int IPhoneShareEvents.Begin(string name, bool upload, long total)
    {
        var id = Interlocked.Increment(ref _nextId);
        _ctx.Bus.Run(() =>
        {
            var row = new PhoneTransfer(name, upload, total);
            _rows[id] = row;
            _s.Transfers.Insert(0, row);
            while (_s.Transfers.Count > MaxRows)
            {
                var old = _s.Transfers[^1];
                _s.Transfers.RemoveAt(_s.Transfers.Count - 1);
                foreach (var k in _rows.Where(kv => kv.Value == old).Select(kv => kv.Key).ToList()) _rows.Remove(k);
            }
            _s.HasTransfers = true;
        });
        return id;
    }

    void IPhoneShareEvents.Progress(int id, int percent) => _ctx.Bus.Run(() =>
    {
        if (!_rows.TryGetValue(id, out var r) || !r.IsRunning) return;
        r.Percent = percent;
        r.Detail = $"{percent}% of {FileTrayService.FormatSize(r.Total)}";
    });

    void IPhoneShareEvents.Done(int id, string? savedPath) => _ctx.Bus.Run(() =>
    {
        if (savedPath is not null)
        {
            _traySvc.Add([savedPath]);
            var name = Path.GetFileName(savedPath);
            _ctx.Shell.Peek("\uE896", $"Received {name}", "AccentBrush");
        }
        if (!_rows.TryGetValue(id, out var r)) return;
        r.Percent = 100;
        r.IsDone = true;
        r.IsFailed = false;
        r.SavedPath = savedPath;
        r.Detail = savedPath is null ? "Sent" : $"Saved as {Path.GetFileName(savedPath)}";
    });

    void IPhoneShareEvents.Failed(int id, string reason) => _ctx.Bus.Run(() =>
    {
        if (_rows.TryGetValue(id, out var r)) Fail(r, reason);
    });

    // ---------- snapshot ----------

    void Seed()
    {
        TrayItem Item(string path, string size, bool folder = false) => new(path) { SizeText = size, IsFolder = folder };
        foreach (var it in new[] { Item(@"C:\Users\demo\Documents\Quarterly report.pdf", "2.4 MB"), Item(@"C:\Users\demo\Pictures\Boarding pass.png", "312 KB") })
            _s.Choices.Add(new ShareChoice(it));
        _s.HasChoices = true;
        _s.IsActive = true;
        _s.IsOpen = true;
        _s.SelectionText = "Sharing 2 files";
        _s.Url = "http://192.168.1.24:51327/s/q7LmZ2xV0cRj8sPwK4nYtA/";
        _s.Qr = QrImage.Create(QrCode.Encode(_s.Url));
        _s.TimeLeft = "Ends in 14 min";
        _s.CanExtend = true;
        _s.Address = new ShareAddress("192.168.1.24", "Wi-Fi");
        _s.Addresses.Add(_s.Address);
        _s.Status = "Phone connected.";
        _s.Transfers.Add(new PhoneTransfer("Quarterly report.pdf", false, 2_516_582) { Percent = 64, Detail = "64% of 2.4 MB" });
        _s.Transfers.Add(new PhoneTransfer("IMG_2041.HEIC", true, 1_843_200) { Percent = 100, IsDone = true, Detail = "Saved as IMG_2041.HEIC", SavedPath = @"C:\Users\demo\Downloads\QNotch\IMG_2041.HEIC" });
        _s.Transfers.Add(new PhoneTransfer("IMG_2040.HEIC", true, 1_731_100) { IsFailed = true, Detail = "Cancelled on the phone" });
        _s.HasTransfers = true;
    }
}
