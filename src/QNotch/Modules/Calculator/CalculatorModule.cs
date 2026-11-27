using System.Windows;
using Calc.Documents;
using Calc.Windows;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Calculator;

/// <summary>
/// A notepad calculator: a tab of saved sheets with live answers, and answers in Search. Costs nothing until first used: the engine, the
/// editor and the saved sheets all load when the tab is first shown, its Settings page opens or Search first sees a calculation.
/// </summary>
public sealed class CalculatorModule : INotchModule, ICadenceAware, IDisposable
{
    internal const string Id = "calculator", Icon = "\uE8EF";
    static readonly string[] ImportExtensions = [".numi", ".slvr", ".txt"];

    ModuleContext _ctx = null!;
    CalculatorSearch _search = null!;
    Task<CalculatorEngine>? _engine;
    Task<CalculatorSurface>? _surface;
    CalculatorSurface? _built;
    string? _demoDirectory;
    volatile object? _functions;

    internal bool Demo => _ctx.Settings.ReadOnly;

    /// <summary>The saved functions, when the workspace is already open. Search never opens it just for this.</summary>
    internal object? Functions => _functions;

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        _search = new CalculatorSearch(ctx, this);

        ctx.Tabs.Register(new TabDescriptor(Id, L.T("Calculator"), Icon, 25, () => new CalculatorTab(this)));
        ctx.Search.Register(new SearchSource(Id, L.T("Calculator"), Icon, 1, _search.Find));
        ctx.SettingsSections.Register(new SettingsSectionDescriptor(Id, L.T("Calculator"), Icon, 35, () => new CalculatorSettingsPage(this)));
        ctx.Drops.Register(new DropSourceDescriptor(Id, L.T("Calculator"), Icon, 30, ImportTargets));
        Application.Current.Exit += (_, _) => Shutdown();
    }

    internal bool PanelOpen { get; private set; }
    internal event Action? PanelOpened;

    public void SetCadence(Cadence cadence)
    {
        PanelOpen = cadence == Cadence.Fast;
        if (PanelOpen) { PanelOpened?.Invoke(); return; }
        _search.Forget();
        _built?.Flush();
    }

    public void Dispose() => Shutdown();

    void Shutdown()
    {
        // Quitting must not fail because of a sheet: whatever could not be written is still in its last saved state.
        try { _built?.Shutdown(); }
        catch (Exception ex) { Log.Error("Calculator did not shut down cleanly", ex); }
        if (_demoDirectory is { } demo)
        {
            _demoDirectory = null;
            try { Directory.Delete(demo, true); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Log.Warn("Calculator: demo folder not removed", ex); }
        }
    }

    string DataDirectory => Path.Combine(Paths.DataDir, "calculator");

    /// <summary>The engine for Search answers, created once on the thread pool.</summary>
    internal Task<CalculatorEngine> GetEngine() => _engine ??= Task.Run(() => new CalculatorEngine(DataDirectory, Demo));

    /// <summary>The sheet view with its open workspace. Built once, on the UI thread, after the files were read off it.</summary>
    internal Task<CalculatorSurface> GetSurface() => _surface ??= Demo ? Task.FromResult(CreateDemoSurface()) : CreateSurface();

    async Task<CalculatorSurface> CreateSurface()
    {
        var directory = DataDirectory;
        var session = await Task.Run(() => CalculatorSession.Open(directory));
        return _built = new CalculatorSurface(this, session);
    }

    CalculatorSurface CreateDemoSurface()
    {
        _demoDirectory = Path.Combine(Paths.DataDir, "calculator-demo-" + Guid.NewGuid().ToString("N"));
        return _built = new CalculatorSurface(this, CalculatorSession.OpenDemo(_demoDirectory));
    }

    internal void TakeKeyboard() => _ctx.Shell.OpenPanelWithKeyboard(Id);
    internal IDisposable HoldOpen() => _ctx.Shell.HoldOpen();
    internal void OpenSettings() => _ctx.Shell.OpenSettings(Id);

    /// <summary>The saved functions changed. Search answers can use them from now on.</summary>
    internal void FunctionsChanged(object functions)
    {
        if (ReferenceEquals(_functions, functions)) return;
        _functions = functions;
        _search.Forget();
    }

    /// <summary>The sheet saved new exchange rates: Search answers read them again.</summary>
    internal void RatesChanged()
    {
        _search.Forget();
        if (_engine is not { } engine) return;
        _ = engine.ContinueWith(done => { if (done.IsCompletedSuccessfully) done.Result.ReloadRates(); }, TaskScheduler.Default);
    }

    /// <summary>Files dragged over the notch: a tile when any of them can become a sheet. Only looks at the names.</summary>
    IReadOnlyList<DropTarget> ImportTargets(IReadOnlyList<string> files)
    {
        if (files.Count == 0 || !files.Any(CanImport)) return [];
        return [new DropTarget("calculator.import", L.T("Import as sheets"), Icon, ImportDropped)];
    }

    static bool CanImport(string path) => ImportExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    async void ImportDropped(string[] files)
    {
        try
        {
            _ctx.Shell.SelectTab(Id);
            (await GetSurface()).ImportDropped(files);
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or System.Text.Json.JsonException)
        { Log.Error("Calculator import failed", ex); }
    }
}

/// <summary>The Settings page's cheap host: the calculator loads when the page is first shown.</summary>
internal sealed class CalculatorSettingsPage : System.Windows.Controls.ContentControl
{
    readonly CalculatorModule _module;
    bool _started;

    public CalculatorSettingsPage(CalculatorModule module)
    {
        _module = module;
        Focusable = false;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        if (module.Demo) Build();
        else Loaded += (_, _) => Build();
    }

    async void Build()
    {
        if (_started) return;
        _started = true;
        try
        {
            var surface = _module.Demo ? _module.GetSurface().GetAwaiter().GetResult() : await _module.GetSurface();
            Content = surface.CreateSettingsPage();
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or System.Text.Json.JsonException or UnsupportedDocumentVersionException)
        {
            Log.Error("Calculator settings failed to open", ex);
            Content = Placeholder.Create(CalculatorModule.Icon, L.T("Calculator unavailable"), L.T("Your sheets were not changed. See the log for details."));
        }
    }
}
