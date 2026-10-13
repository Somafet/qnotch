using System.ComponentModel;
using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Windows.Threading;

namespace QNotch.Core.Updates;

/// <summary>Shell lifecycle service. UI state stays on the dispatcher; network and package work stays on workers.</summary>
internal sealed class UpdateService : IDisposable
{
    readonly GeneralSettings _settings;
    readonly SettingsStore _store;
    readonly Dispatcher _dispatcher;
    readonly bool _readOnly;
    readonly Action _shutdown;
    readonly HttpClient _http;
    readonly Timer _timer;
    readonly CancellationTokenSource _lifetime = new();
    readonly Version _installed;
    readonly bool _selfContained;
    CancellationTokenSource? _operation;
    UpdateRelease? _release;
    bool _automaticCheck, _disposed;

    public UpdateState State { get; }
    public event Action? UpdateAvailable;
    public bool ShouldNotify => State.HasUpdate && _settings.LastNotifiedUpdateVersion != State.AvailableVersion;
    string ResultFile => Path.Combine(Paths.DataDir, "update-result.txt");

    public UpdateService(GeneralSettings settings, Dispatcher dispatcher, SettingsStore store, Action shutdown, HttpClient? http = null)
    {
        _settings = settings; _dispatcher = dispatcher; _store = store; _readOnly = store.ReadOnly; _shutdown = shutdown;
        _http = http ?? new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        // Introduce the default once for older settings as well. A recorded choice is never overridden.
        if (!settings.UpdateChecksChoiceMade) settings.CheckForUpdates = true;
        var assembly = typeof(UpdateService).Assembly;
        _installed = UpdateRelease.ParseVersion(assembly.GetName().Version?.ToString()) ?? new Version(0, 0, 0, 0);
        _selfContained = assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
            .Any(a => a.Key == "QNotchSelfContained" && string.Equals(a.Value, "true", StringComparison.OrdinalIgnoreCase));
        State = new UpdateState
        {
            CurrentVersion = UpdateRelease.DisplayVersion(_installed),
            NeedsPreferenceChoice = !settings.UpdateChecksChoiceMade,
            Status = settings.CheckForUpdates ? "Automatic checks are on. QNotch will check shortly after startup."
                : "Automatic checks are off. You can check manually at any time.",
        };
        _timer = new Timer(_ =>
        {
            if (!_disposed && !_dispatcher.HasShutdownStarted)
                _dispatcher.BeginInvoke(() => { if (!_disposed && _settings.CheckForUpdates) _ = CheckAsync(true); });
        }, null, Timeout.Infinite, Timeout.Infinite);
        if (_readOnly)
        {
            settings.CheckForUpdates = true;
            State.NeedsPreferenceChoice = true;
            State.AvailableVersion = "0.5.0";
            State.Status = "A new version is ready. QNotch will restart after you choose Update and restart.";
            return;
        }
        try
        {
            if (File.Exists(ResultFile)) { State.Status = File.ReadAllText(ResultFile); File.Delete(ResultFile); }
        }
        catch (Exception ex) { Log.Warn("Reading the update result failed", ex); }
        _settings.PropertyChanged += SettingsChanged;
    }

    public void Start()
    {
        if (!_readOnly && _settings.CheckForUpdates) Schedule(TimeSpan.FromSeconds(10));
    }

    public void ChooseAutomaticChecks(bool enabled)
    {
        if (_disposed || _readOnly) return;
        _settings.UpdateChecksChoiceMade = true;
        State.NeedsPreferenceChoice = false;
        _settings.CheckForUpdates = enabled;
        _store.Save("general", _settings);
    }

    public void MarkNotified()
    {
        if (_disposed || _readOnly || !State.HasUpdate) return;
        _settings.LastNotifiedUpdateVersion = State.AvailableVersion;
        _store.Save("general", _settings);
    }

    void SettingsChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(GeneralSettings.CheckForUpdates) || _disposed) return;
        // Changing the toggle is also an explicit answer to the first-run choice.
        _settings.UpdateChecksChoiceMade = true;
        State.NeedsPreferenceChoice = false;
        _store.Save("general", _settings);
        if (_settings.CheckForUpdates)
        {
            if (!State.IsBusy) _ = CheckAsync(true);
        }
        else
        {
            _timer.Change(Timeout.Infinite, Timeout.Infinite);
            if (_automaticCheck) _operation?.Cancel();
            if (!State.HasUpdate && !State.IsBusy) State.Status = "Automatic checks are off. You can check manually at any time.";
        }
    }

    void Schedule(TimeSpan delay)
    {
        if (!_disposed && !_readOnly && _settings.CheckForUpdates) _timer.Change(delay, Timeout.InfiniteTimeSpan);
    }

    public async Task CheckAsync(bool automatic = false)
    {
        if (_disposed || _readOnly || State.IsBusy || (automatic && !_settings.CheckForUpdates)) return;
        _timer.Change(Timeout.Infinite, Timeout.Infinite);
        State.IsBusy = true;
        State.Status = "Checking GitHub for updates…";
        _automaticCheck = automatic;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        cancellation.CancelAfter(TimeSpan.FromSeconds(20));
        _operation = cancellation;
        try
        {
            var client = new UpdateClient(_http);
            var release = await Task.Run(() => client.CheckAsync(_installed, _selfContained, cancellation.Token));
            cancellation.Token.ThrowIfCancellationRequested();
            _release = release;
            State.AvailableVersion = release is null ? "" : UpdateRelease.DisplayVersion(release.Version);
            State.Status = release is null ? $"You're up to date. Checked at {DateTime.Now:HH:mm}."
                : "A new version is ready. QNotch will restart after you choose Update and restart.";
            if (release is not null) UpdateAvailable?.Invoke();
        }
        catch (OperationCanceledException)
        {
            if (!_disposed) State.Status = automatic && !_settings.CheckForUpdates
                ? "Automatic checks are off." : "The update check timed out. Try again when you're online.";
        }
        catch (Exception ex)
        {
            Log.Warn("Checking for QNotch updates failed", ex);
            State.Status = "Could not check for updates. " + ex.Message;
        }
        finally
        {
            _automaticCheck = false; _operation = null;
            State.IsBusy = false;
            Schedule(TimeSpan.FromHours(6));
        }
    }

    public async Task InstallAsync()
    {
        if (_disposed || _readOnly || !State.CanUpdate || _release is not { } release) return;
        State.IsBusy = true; State.IsDownloading = true; State.DownloadPercent = 0;
        State.Status = "Downloading the update…";
        _timer.Change(Timeout.Infinite, Timeout.Infinite);
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        cancellation.CancelAfter(TimeSpan.FromMinutes(5));
        _operation = cancellation;
        string? directory = null;
        var handedOff = false;
        try
        {
            var target = Environment.ProcessPath ?? throw new IOException("Could not locate QNotch.exe.");
            directory = Path.Combine(Path.GetDirectoryName(target)!, ".qnotch-update-" + Guid.NewGuid().ToString("N"));
            var progress = new Progress<int>(p => { if (!_disposed) State.DownloadPercent = p; });
            await Task.Run(async () =>
            {
                Directory.CreateDirectory(directory);
                await new UpdateClient(_http).DownloadAsync(release, directory, progress, cancellation.Token);
                using var resource = typeof(UpdateService).Assembly.GetManifestResourceStream("QNotch.Core.Updates.ApplyUpdate.ps1")
                    ?? throw new IOException("The update helper is missing.");
                await using var file = File.Create(Path.Combine(directory, "apply.ps1"));
                await resource.CopyToAsync(file, cancellation.Token);
            });
            State.IsDownloading = false;
            State.Status = "Restarting QNotch to install the update…";
            await StartHelperAsync(target, directory, release.Tag, cancellation.Token);
            handedOff = true;
            _shutdown(); // OnExit flushes settings and releases the single-instance mutex.
        }
        catch (OperationCanceledException)
        {
            if (!_disposed) State.Status = "The update download timed out. Nothing was installed. Try again.";
        }
        catch (UnauthorizedAccessException ex)
        {
            Log.Warn("The QNotch install folder is not writable", ex);
            State.Status = "Could not write to the install folder. Move QNotch to a folder you can write to, then try again.";
        }
        catch (Exception ex)
        {
            Log.Warn("Installing the QNotch update failed", ex);
            State.Status = "Could not install the update. " + ex.Message;
        }
        finally
        {
            _operation = null;
            if (!handedOff)
            {
                // Only delete the exact directory we created, whose parent is the installed executable's directory.
                if (directory is not null) await Task.Run(() =>
                {
                    try { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
                    catch (Exception ex) { Log.Warn("Removing the staged update failed", ex); }
                });
                State.IsDownloading = false; State.IsBusy = false;
                Schedule(TimeSpan.FromHours(6));
            }
        }
    }

    async Task StartHelperAsync(string target, string directory, string version, CancellationToken cancellation)
    {
        var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"))
        { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
        using var parent = Process.GetCurrentProcess();
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File",
            Path.Combine(directory, "apply.ps1"), "-Target", target, "-WorkDir", directory, "-ParentId", parent.Id.ToString(),
            "-ParentStarted", parent.StartTime.ToUniversalTime().Ticks.ToString(), "-ResultFile", ResultFile, "-Version", version })
            info.ArgumentList.Add(argument);
        using var helper = Process.Start(info) ?? throw new IOException("Could not start the update helper.");
        try
        {
            for (var i = 0; i < 100; i++)
            {
                cancellation.ThrowIfCancellationRequested();
                if (helper.HasExited) throw new IOException("The update helper could not start. Nothing was installed.");
                if (File.Exists(Path.Combine(directory, "ready"))) return;
                await Task.Delay(100, cancellation);
            }
            throw new IOException("The update helper did not respond. Nothing was installed.");
        }
        catch
        {
            try { if (!helper.HasExited) { helper.Kill(); await helper.WaitForExitAsync(); } } catch { }
            throw;
        }
    }

    public void Dispose()
    {
        _disposed = true;
        _settings.PropertyChanged -= SettingsChanged;
        _timer.Dispose();
        _lifetime.Cancel();
        _http.Dispose();
    }
}
