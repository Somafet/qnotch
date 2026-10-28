using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using Microsoft.Win32;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Devices;

public sealed class DevicesSettings
{
    public string Id { get; set; } = DeviceProtocol.Id();
    public bool Enabled { get; set; }
    public int Port { get; set; } = 45874;
    public List<DevicePeer> Peers { get; set; } = [];
}

public sealed class DevicesModule : INotchModule
{
    ModuleContext ctx = null!;
    DevicesSettings settings = null!;
    DeviceNode? node;
    string status = "Local sharing is off.", latest = "";
    Action? refresh;
    readonly List<(string Name, string Path)> received = [];
    CancellationTokenSource? operation;
    public void Initialize(ModuleContext context)
    {
        ctx = context; settings = ctx.Settings.Get<DevicesSettings>("devices");
        ctx.SettingsSections.Register(new("devices", "Devices", "", 35, MakePage));
        if (ctx.Settings.ReadOnly) { status = "Local sharing is off. Add a Mac or Windows PC to get started."; return; }
        Application.Current.Exit += (_, _) => { operation?.Cancel(); node?.Dispose(); };
        if (settings.Enabled) _ = Start();
    }
    void Save() => ctx.Settings.Save("devices", settings);
    void Update(string text) { status = text; refresh?.Invoke(); }
    async Task Start()
    {
        if (node is not null) return;
        var fresh = new DeviceNode(settings.Id, Environment.MachineName[..Math.Min(80, Environment.MachineName.Length)],
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "QNotch", "Devices"));
        try
        {
            node = fresh;
            foreach (var peer in settings.Peers)
            {
                var key = await Task.Run(() => DeviceCredentials.Read(peer.Id));
                if (key is not null) { try { fresh.Restore(peer, Convert.FromBase64String(key)); } catch (FormatException) { } }
                if (node != fresh) { fresh.Dispose(); return; }
            }
            fresh.Approve = peer => ctx.Dispatcher.InvokeAsync(() => MessageBox.Show(
                $"Add {peer.Name} ({peer.Host})?\n\nThis device can send text and files to your QNotch inbox. Only approve a device you are pairing now.",
                "Add device", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes).Task;
            fresh.Persist = async (peer, key) =>
            {
                if (!await ctx.Dispatcher.InvokeAsync(() => node == fresh)) return false;
                if (!await Task.Run(() => DeviceCredentials.Write(peer.Id, Convert.ToBase64String(key)))) return false;
                var saved = await ctx.Dispatcher.InvokeAsync(() => { if (node != fresh) return false; settings.Peers.RemoveAll(p => p.Id == peer.Id); settings.Peers.Add(peer); Save(); return true; });
                if (!saved) await Task.Run(() => DeviceCredentials.Delete(peer.Id));
                return saved;
            };
            fresh.Changed = () => ctx.Bus.Run(() => { if (node == fresh) { latest = ""; refresh?.Invoke(); } });
            fresh.Received = (name, path, _) => ctx.Bus.Run(() =>
            {
                received.Insert(0, (name, path)); if (received.Count > 20) received.RemoveAt(20);
                Update($"Received from {name}. Saved to Downloads/QNotch/Devices.");
            });
            await Task.Run(() => fresh.Start(settings.Port));
            if (node != fresh) { fresh.Dispose(); return; }
            settings.Enabled = true; Save(); Update("Ready. Add a device or send to a paired device.");
        }
        catch (Exception ex) when (ex is SocketException or IOException or ArgumentException)
        { if (node != fresh) return; fresh.Dispose(); node = null; settings.Enabled = false; Save(); Update("Could not start sharing. Check the port and firewall, then try again."); }
    }
    FrameworkElement MakePage()
    {
        var page = UiKit.Page("Devices");
        var enabled = UiKit.Toggle(settings.Enabled && node is not null, async on =>
        {
            if (ctx.Settings.ReadOnly) return;
            if (on) await Start();
            else { operation?.Cancel(); node?.Dispose(); node = null; latest = ""; settings.Enabled = false; Save(); Update("Local sharing is off."); }
        });
        page.Children.Add(UiKit.Row("Local sharing", "Encrypted text and files between paired Macs and Windows PCs on your network.", enabled));
        var port = new TextBox { Text = settings.Port.ToString(), Width = 90 };
        port.LostKeyboardFocus += (_, _) => { if (node is null && int.TryParse(port.Text, out var value) && value is > 0 and <= 65535) { settings.Port = value; Save(); } else port.Text = settings.Port.ToString(); };
        page.Children.Add(UiKit.Row("Listening port", "Change while sharing is off. Allow this port on private networks in your firewall.", port));
        var address = new ComboBox { MinWidth = 180 };
        if (!ctx.Settings.ReadOnly)
            foreach (var ip in NetworkInterface.GetAllNetworkInterfaces().Where(n => n.OperationalStatus == OperationalStatus.Up)
                .SelectMany(n => n.GetIPProperties().UnicastAddresses).Select(a => a.Address.ToString()).Where(DeviceProtocol.LocalAddress).Distinct()) address.Items.Add(ip);
        if (address.Items.Count == 0) address.Items.Add("127.0.0.1"); address.SelectedIndex = 0;
        page.Children.Add(UiKit.Row("This device's address", "Choose the adapter reachable from your other computer. Both devices must enable local sharing.", address));
        var invitation = new TextBox { IsReadOnly = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 76, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        AutomationProperties.SetName(invitation, "Invitation to this device");
        var invite = new Button { Content = "Create invitation" };
        invite.Click += (_, _) => { try { latest = node?.Invite((string)address.SelectedItem).Code ?? ""; invitation.Text = latest; Update("Invitation lasts five minutes. Send it privately; approve the device here when it connects."); } catch (IOException ex) { Update(ex.Message); } };
        page.Children.Add(UiKit.Row("Add another device", "Create an invitation, then paste it into Settings, Devices on the other computer.", invite));
        invitation.Margin = new Thickness(0, 0, 0, 12); page.Children.Add(invitation);
        var code = new TextBox { MaxLength = 4096, TextWrapping = TextWrapping.Wrap, MaxHeight = 76 };
        AutomationProperties.SetName(code, "Invitation from another device");
        page.Children.Add(UiKit.Text("Or paste an invitation from another device:")); page.Children.Add(code);
        var add = new Button { Content = "Add device", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 16) };
        add.Click += async (_, _) => await Run(async token => { var value = code.Text.Trim(); code.Clear(); await node!.Pair(value, token); }, "Device paired.");
        page.Children.Add(add);
        var result = UiKit.Text(status); result.Margin = new Thickness(0, 0, 0, 12); page.Children.Add(result);
        var peers = new ComboBox { MinWidth = 180, DisplayMemberPath = "Name" };
        page.Children.Add(UiKit.Row("Paired devices", "Use Check connection to verify reachability. If its address changes, remove it and pair again.", peers));
        var receive = new CheckBox { Content = "Allow incoming text and files", Margin = new Thickness(0, 0, 0, 8) };
        page.Children.Add(receive);
        void Receive(bool on)
        {
            if (peers.SelectedItem is not DevicePeer peer) return;
            node?.SetReceive(peer.Id, on); settings.Peers.RemoveAll(p => p.Id == peer.Id); settings.Peers.Add(peer with { Receive = on }); Save();
        }
        receive.Checked += (_, _) => Receive(true); receive.Unchecked += (_, _) => Receive(false);
        peers.SelectionChanged += (_, _) => { if (peers.SelectedItem is DevicePeer p) receive.IsChecked = settings.Peers.FirstOrDefault(v => v.Id == p.Id)?.Receive ?? p.Receive; };
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        var check = new Button { Content = "Check connection" }; var remove = new Button { Content = "Remove device", Margin = new Thickness(8, 0, 0, 0) };
        actions.Children.Add(check); actions.Children.Add(remove); page.Children.Add(actions);
        check.Click += async (_, _) => { if (peers.SelectedItem is DevicePeer p) await Run(t => node!.Send(p.Id, ct: t), "Device is reachable."); };
        remove.Click += async (_, _) => { if (peers.SelectedItem is DevicePeer p) { node?.Remove(p.Id); settings.Peers.RemoveAll(v => v.Id == p.Id); Save(); await Task.Run(() => DeviceCredentials.Delete(p.Id)); Update("Device removed. Pair again to reconnect."); } };
        var text = new TextBox { AcceptsReturn = true, Height = 70, MaxLength = 16000, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 8) };
        AutomationProperties.SetName(text, "Text to send"); page.Children.Add(text);
        var sendActions = new StackPanel { Orientation = Orientation.Horizontal };
        var send = new Button { Content = "Send text" }; var file = new Button { Content = "Send file", Margin = new Thickness(8, 0, 0, 0) }; var cancel = new Button { Content = "Cancel", Margin = new Thickness(8, 0, 0, 0) };
        sendActions.Children.Add(send); sendActions.Children.Add(file); sendActions.Children.Add(cancel); page.Children.Add(sendActions);
        send.Click += async (_, _) => { if (peers.SelectedItem is DevicePeer p) { var value = text.Text; await Run(t => node!.Send(p.Id, text: value, ct: t), "Text sent."); } };
        file.Click += async (_, _) =>
        {
            if (peers.SelectedItem is not DevicePeer p) return;
            var dialog = new OpenFileDialog { Title = "Send file to " + p.Name };
            var lastPercent = -1;
            if (dialog.ShowDialog() == true) await Run(t => node!.Send(p.Id, path: dialog.FileName,
                progress: (sent, total) => { var percent = (int)(sent * 100 / Math.Max(1, total)); if (percent != lastPercent) { lastPercent = percent; ctx.Bus.Run(() => { result.Text = $"Sending {percent}%"; }); } }, ct: t), "File sent.");
        };
        cancel.Click += (_, _) => operation?.Cancel();
        var inbox = new StackPanel { Margin = new Thickness(0, 16, 0, 0) }; page.Children.Add(inbox);
        void Refresh()
        {
            result.Text = status; invitation.Text = latest;
            invitation.Visibility = latest.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            var selected = (peers.SelectedItem as DevicePeer)?.Id;
            peers.ItemsSource = node?.Peers ?? settings.Peers.ToArray();
            peers.SelectedItem = peers.Items.Cast<DevicePeer>().FirstOrDefault(p => p.Id == selected) ?? peers.Items.Cast<DevicePeer>().FirstOrDefault();
            var ready = node is not null && !ctx.Settings.ReadOnly;
            invite.IsEnabled = add.IsEnabled = ready && operation is null;
            send.IsEnabled = file.IsEnabled = check.IsEnabled = ready && operation is null && peers.SelectedItem is not null;
            cancel.IsEnabled = operation is not null; port.IsEnabled = node is null; remove.IsEnabled = peers.SelectedItem is not null && operation is null && !ctx.Settings.ReadOnly;
            receive.IsEnabled = ready && peers.SelectedItem is not null;
            inbox.Children.Clear(); inbox.Children.Add(UiKit.Text("Received items are saved in Downloads/QNotch/Devices. Text is never copied automatically."));
            foreach (var item in received)
            {
                var show = new Button { Content = "Show in folder" };
                show.Click += (_, _) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"/select,\"{item.Path}\"") { UseShellExecute = true });
                inbox.Children.Add(UiKit.Row(item.Name, Path.GetFileName(item.Path), show));
            }
        }
        page.Loaded += (_, _) => { refresh += Refresh; Refresh(); };
        page.Unloaded += (_, _) => refresh -= Refresh;
        Refresh(); return page;
    }
    async Task Run(Func<CancellationToken, Task> work, string success)
    {
        if (node is null || operation is not null || ctx.Settings.ReadOnly) return;
        using var current = new CancellationTokenSource(); operation = current; Update("Connecting...");
        try { await work(current.Token); Update(success); }
        catch (Exception ex) when (ex is IOException or SocketException or OperationCanceledException or FormatException or ArgumentException or System.Security.Cryptography.CryptographicException or ObjectDisposedException)
        { Update(ex is OperationCanceledException ? "Transfer cancelled or timed out." : "Could not connect or transfer. Check both devices, the invitation and private-network firewall permissions."); }
        finally { operation = null; refresh?.Invoke(); }
    }
}
