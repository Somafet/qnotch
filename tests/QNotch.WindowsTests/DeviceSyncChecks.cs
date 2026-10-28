using System.IO;
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
    static async Task Check(Dispatcher dispatcher, string folder)
    {
        var localId = "00000000-0000-0000-0000-000000000001";
        var remoteId = "00000000-0000-0000-0000-000000000002";
        var settings = new DevicesSettings { Id = localId, Peers = [new(remoteId, "Other computer", "127.0.0.1", 45874, SyncNotes: true, SyncClipboard: true)] };
        var ctx = new ModuleContext
        {
            Bus = new EventBus(dispatcher), Dispatcher = dispatcher, Settings = new SettingsStore(), Cards = new(), Tabs = new(),
            SettingsSections = new(), Segments = new(), Search = new(), Shell = null!, Hotkeys = null!, Shortcuts = null!, Sounds = null!,
        };
        var localNote = "Existing local note"; var clipboardWrites = 0;
        SharedTextSource? notes = null, clipboard = null;
        notes = new("note", 10, () => localNote, text => { localNote = text; notes!.Publish(text); });
        clipboard = new("clipboard", 20, () => null, text => { clipboardWrites++; clipboard!.Publish(text); });
        ctx.SharedText.Register(notes); ctx.SharedText.Register(clipboard);
        var path = Path.Combine(folder, "sync.json");
        using (var runtime = new DeviceSyncRuntime(ctx, settings, () => null, path))
        {
            await Ready(runtime);
            var remote = new DeviceSync(remoteId, new()); remote.EditNote("Other computer note");
            var incoming = remote.Bundle(true, true) with { Clipboard = new(5, remoteId, "Private incoming clipboard") };
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
    }
    static async Task Ready(DeviceSyncRuntime runtime)
    {
        for (var i = 0; i < 200 && !runtime.IsReady; i++) await Task.Delay(10);
        Require(runtime.IsReady, runtime.Status);
    }
    static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
