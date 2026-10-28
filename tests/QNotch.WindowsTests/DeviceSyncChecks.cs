using System.IO;
using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Windows.Threading;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Modules.Devices;

internal static class DeviceSyncChecks
{
    public static void Run()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
            dispatcher.BeginInvoke(async () =>
            {
                var folder = Path.Combine(Path.GetTempPath(), "qnotch-sync-runtime-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
                try { await Check(dispatcher, folder); }
                catch (Exception ex) { failure = ex; }
                finally { Directory.Delete(folder, true); dispatcher.BeginInvokeShutdown(DispatcherPriority.Background); }
            });
            Dispatcher.Run();
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA); thread.Start();
        if (!thread.Join(15000)) throw new TimeoutException("Device sync coordinator test timed out.");
        if (failure is not null) throw new InvalidOperationException("Device sync coordinator failed.", failure);
    }
    public static void MeasureIdle()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
            dispatcher.BeginInvoke(async () =>
            {
                var folder = Path.Combine(Path.GetTempPath(), "qnotch-devices-idle-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
                try
                {
                    using var a = new DeviceNode(DeviceProtocol.Id(), "Idle local", folder);
                    using var b = new DeviceNode(DeviceProtocol.Id(), "Idle remote", folder);
                    a.Start(0, IPAddress.Loopback); b.Start(0, IPAddress.Loopback);
                    var key = RandomNumberGenerator.GetBytes(32);
                    var peer = new DevicePeer(b.Id, "Idle remote", "127.0.0.1", b.Port, SyncNotes: true, SyncClipboard: true);
                    a.Restore(peer, key); b.Restore(new(a.Id, "Idle local", "127.0.0.1", a.Port), key);
                    var exchanges = 0;
                    b.Exchange = (_, input) => { Interlocked.Increment(ref exchanges); return Task.FromResult(input); };
                    var settings = new DevicesSettings { Id = a.Id, Peers = [peer] };
                    var ctx = new ModuleContext
                    {
                        Bus = new EventBus(dispatcher), Dispatcher = dispatcher, Settings = new SettingsStore(), Cards = new(), Tabs = new(),
                        SettingsSections = new(), Segments = new(), Search = new(), Shell = null!, Hotkeys = null!, Shortcuts = null!, Sounds = null!,
                    };
                    ctx.SharedText.Register(new("note", 10, () => "Idle note", _ => { }));
                    ctx.SharedText.Register(new("clipboard", 20, () => null, _ => { }));
                    using var runtime = new DeviceSyncRuntime(ctx, settings, () => a, Path.Combine(folder, "sync.json"));
                    await Ready(runtime); await Task.Delay(10000);
                    var initialExchanges = Volatile.Read(ref exchanges);
                    var process = Process.GetCurrentProcess(); var cpu = process.TotalProcessorTime; var elapsed = Stopwatch.StartNew();
                    await Task.Delay(30000); process.Refresh();
                    var percent = (process.TotalProcessorTime - cpu).TotalSeconds / elapsed.Elapsed.TotalSeconds * 100;
                    Console.WriteLine($"Devices-only idle: {percent:F3}% of one core; {process.WorkingSet64 / 1048576.0:F1} MiB resident; 30 s after 10 s warmup; two active socket listeners, enabled note/clipboard policy. Sync exchanges during measurement: {Volatile.Read(ref exchanges) - initialExchanges}.");
                    Require(percent <= 0.1 && process.WorkingSet64 < 80 * 1048576, "Devices-only idle exceeds the CPU/memory budget");
                }
                catch (Exception ex) { failure = ex; }
                finally { Directory.Delete(folder, true); dispatcher.BeginInvokeShutdown(DispatcherPriority.Background); }
            });
            Dispatcher.Run();
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA); thread.Start();
        if (!thread.Join(55000)) throw new TimeoutException("Devices idle measurement timed out.");
        if (failure is not null) throw new InvalidOperationException("Devices idle measurement failed.", failure);
    }
    static async Task Check(Dispatcher dispatcher, string folder)
    {
        var demoStore = new SettingsStore { ReadOnly = true };
        demoStore.Save("devices", new DevicesSettings { Enabled = true, Peers = [new(DeviceProtocol.Id(), "PRIVATE-DEVICE-MUST-NOT-APPEAR", "192.168.9.99", 45874)] });
        var demo = DevicesModule.ReadSettings(demoStore);
        Require(!demo.Enabled && demo.Peers.Count == 0, "diagnostic Devices settings must not expose saved device metadata");
        var localId = "00000000-0000-0000-0000-000000000001";
        var remoteId = "00000000-0000-0000-0000-000000000002";
        var settings = new DevicesSettings { Id = localId, Peers = [new(remoteId, "Other computer", "127.0.0.1", 45874, SyncNotes: true, SyncClipboard: true)] };
        var ctx = new ModuleContext
        {
            Bus = new EventBus(dispatcher), Dispatcher = dispatcher, Settings = new SettingsStore(), Cards = new(), Tabs = new(),
            SettingsSections = new(), Segments = new(), Search = new(), Shell = null!, Hotkeys = null!, Shortcuts = null!, Sounds = null!,
        };
        var localNote = "Existing local note"; var clipboardWrites = 0; var clipboardBusy = true;
        SharedTextSource? notes = null, clipboard = null;
        notes = new("note", 10, () => localNote, text => { localNote = text; notes!.Publish(text); });
        clipboard = new("clipboard", 20, () => null, text =>
        {
            if (clipboardBusy) { clipboardBusy = false; throw new IOException("Clipboard busy"); }
            clipboardWrites++; clipboard!.Publish(text);
        });
        ctx.SharedText.Register(notes); ctx.SharedText.Register(clipboard);
        var path = Path.Combine(folder, "sync.json");
        using (var runtime = new DeviceSyncRuntime(ctx, settings, () => null, path))
        {
            await Ready(runtime);
            var remote = new DeviceSync(remoteId, new()); remote.EditNote("Other computer note");
            var incoming = remote.Bundle(true, true) with { Clipboard = new(5, remoteId, "Private incoming clipboard") };
            var busyRejected = false;
            try { await runtime.Exchange(remoteId, DeviceProtocol.Encode(incoming)); } catch (IOException) { busyRejected = true; }
            Require(busyRejected && clipboardWrites == 0, "a failed clipboard write must leave the revision retryable");
            await runtime.Exchange(remoteId, DeviceProtocol.Encode(incoming));
            Require(runtime.Conflicts.Count == 2 && localNote == "Existing local note", "concurrent incoming note must not replace the editor");
            Require(clipboardWrites == 1, "remote clipboard must be applied once");
            await runtime.Exchange(remoteId, DeviceProtocol.Encode(incoming));
            Require(clipboardWrites == 1, "echo and duplicate clipboard events must be suppressed");
            runtime.Resolve(runtime.Conflicts.Single(i => i.Text == "Other computer note").Id);
            Require(localNote == "Other computer note" && runtime.Conflicts.Count == 0, "explicit conflict resolution must update the owning source");
            var response = DeviceProtocol.Decode<SyncBundle>(await runtime.Exchange(remoteId, DeviceProtocol.Encode(incoming)));
            Require(response.Notes.Count == 1 && response.Notes[0].Text == localNote, "resolved note must dominate the stale incoming branch");
        }
        var saved = File.ReadAllText(path);
        Require(!saved.Contains("Private incoming clipboard", StringComparison.Ordinal), "clipboard text must stay out of the journal");
        using (var restored = new DeviceSyncRuntime(ctx, settings, () => null, path))
        {
            await Ready(restored);
            var before = clipboardWrites;
            await restored.Exchange(remoteId, DeviceProtocol.Encode(new SyncBundle(true, true, [], new(5, remoteId, "Private incoming clipboard"))));
            Require(clipboardWrites == before && restored.Conflicts.Count == 0, "restart must preserve clipboard replay and note resolution state");
        }
        var corruptPath = Path.Combine(folder, "corrupt.json"); File.WriteAllText(corruptPath, "{not valid JSON");
        using (var corrupt = new DeviceSyncRuntime(ctx, settings, () => null, corruptPath))
        {
            for (var i = 0; i < 200 && !corrupt.Status.Contains("could not be read", StringComparison.Ordinal); i++) await Task.Delay(10);
            Require(!corrupt.IsReady && corrupt.Status.Contains("could not be read", StringComparison.Ordinal), "invalid journals must pause sync");
        }
        Require(File.ReadAllText(corruptPath) == "{not valid JSON", "invalid journal must be preserved for recovery");
    }
    static async Task Ready(DeviceSyncRuntime runtime)
    {
        for (var i = 0; i < 200 && !runtime.IsReady; i++) await Task.Delay(10);
        Require(runtime.IsReady, runtime.Status);
    }
    static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
