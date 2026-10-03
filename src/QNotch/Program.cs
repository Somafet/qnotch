using System.Runtime.CompilerServices;
using QNotch.Modules;

namespace QNotch;

/// <summary>
/// Entry point. A command line verb (<see cref="ModuleList.Verbs"/>, for example <c>QNotch.exe notify</c>) runs and exits before any
/// WPF type loads, so scripts and hooks pay only the runtime start. Everything else starts the app.
/// </summary>
static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length > 0 && ModuleList.Verbs.TryGetValue(args[0], out var verb)) return verb(args[1..]);
        return RunApp();
    }

    [MethodImpl(MethodImplOptions.NoInlining)] // keeps App (and WPF) out of Main's JIT
    static int RunApp()
    {
        var app = new App();
        app.InitializeComponent();
        return app.Run();
    }
}
