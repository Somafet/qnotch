using System.ComponentModel;
using QNotch.Core;

namespace QNotch.Modules.Terminal;

/// <summary>Default-off Windows ConPTY terminal. Sessions survive panel close; owned jobs end on disable/quit/new session.</summary>
public sealed partial class TerminalModule : INotchModule, IDisposable
{
    internal const string Id = "terminal";
    internal readonly TerminalBuffer Buffer = new();
    ModuleContext _ctx = null!;
    GeneralSettings _general = null!;
    TerminalView? _view;
    ConPtySession? _session;
    Task<ConPtySession>? _starting;
    bool _disabled, _disposed, _restarting;
    internal bool Demo => _ctx.Settings.ReadOnly;

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        _general = ctx.Settings.Get<GeneralSettings>("general");
        ctx.Tabs.Register(new TabDescriptor(Id, "Terminal", "", 70, () => _view ??= new TerminalView(this, Buffer)));
        if (Demo)
        {
            Buffer.Feed("\u001b[32mPS C:\\Users\\Alex>\u001b[0m Get-Date\r\nThursday, October 22, 2026 09:41:00\r\n\r\n\u001b[32mPS C:\\Users\\Alex>\u001b[0m ");
            return;
        }
        _general.PropertyChanged += OnSettings;
    }

    internal static (string Executable, string Arguments) Shell()
    {
        var pwsh = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        return File.Exists(pwsh) ? (pwsh, "-NoLogo -NoProfile") :
            (Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoLogo -NoProfile");
    }

    internal void EnsureSession()
    {
        if (Demo || _disposed || _disabled || _starting is not null || _session is not null) return;
        _view?.SetStatus("Starting shell…");
        var shell = Shell();
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _starting = Task.Run(() => ConPtySession.Start(shell.Executable, shell.Arguments, home, Buffer.Columns, Buffer.Rows,
            (text, reply) => { Buffer.Feed(text, reply); _view?.Input.OutputChanged(); },
            () => _ctx.Dispatcher.BeginInvoke(() => { if (!_disposed) _view?.SetStatus("Session ended. Choose New session to start again."); })));
        FinishStart(_starting);
    }

    async void FinishStart(Task<ConPtySession> starting)
    {
        try
        {
            var session = await starting;
            if (_disposed || _disabled) { await session.DisposeAsync(); return; }
            _session = session;
            _view?.SetStatus("PowerShell · session retained while closed · Ctrl+Shift+C copies screen");
        }
        catch (Exception ex)
        {
            Log.Warn("Terminal could not start", ex);
            if (!_disposed) _view?.SetStatus("Shell unavailable: " + ex.Message);
        }
    }

    internal void Send(string text)
    {
        if (Demo || _disabled || _disposed) return;
        if (_session?.Send(text) != true) _view?.SetStatus("Shell is not ready or input is full. Choose New session if it ended.");
    }
    internal void Resize(int columns, int rows) { if (!Demo) _session?.Resize(columns, rows); }
    internal void TakeKeyboard() => _ctx.Shell.OpenPanelWithKeyboard(Id);

    internal async Task Restart()
    {
        if (Demo || _disabled || _disposed || _restarting) return;
        _restarting = true;
        try
        {
            await CloseSession();
            _session = null; _starting = null;
            Buffer.Feed("\u001bc");
            EnsureSession();
            _view?.FocusInput();
        }
        finally { _restarting = false; }
    }
    async Task CloseSession()
    {
        try
        {
            var session = _session ?? (_starting is not null ? await _starting.ConfigureAwait(false) : null);
            if (session is not null) await session.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception ex) { Log.Warn("Terminal cleanup failed", ex); }
    }
    void OnSettings(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(GeneralSettings.LocalEnabledModules) || _general.LocalEnabledModules.Contains(Id, StringComparer.OrdinalIgnoreCase)) return;
        _disabled = true;
        _view?.SetStatus("Terminal disabled. Owned processes are stopping; restart QNotch to remove the tab.");
        _ = CloseSession();
    }
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _general.PropertyChanged -= OnSettings;
        CloseSession().GetAwaiter().GetResult();
    }
}
