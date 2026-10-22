using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using static QNotch.Modules.Terminal.ConPtyNative;

namespace QNotch.Modules.Terminal;

/// <summary>Owned ConPTY + kill-on-close job. Separate blocking reader/writer threads; no idle polling and no UI-thread I/O.</summary>
internal sealed class ConPtySession : IAsyncDisposable
{
    readonly object _gate = new();
    readonly BlockingCollection<Input> _input = new(64);
    readonly Action<string, Action<string>> _output;
    readonly Action _exited;
    readonly Thread _reader, _writer;
    SafeFileHandle? _read, _write, _job;
    Process? _process;
    nint _console;
    Task? _stop;
    readonly TaskCompletionSource _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    bool _writerStarted, _readerStarted;
    internal int ProcessId { get; private set; }
    internal Task Completion => _completion.Task;
    readonly record struct Input(string? Text, int Columns = 0, int Rows = 0);

    ConPtySession(Action<string, Action<string>> output, Action exited)
    {
        _output = output; _exited = exited;
        _reader = new Thread(Read) { IsBackground = true, Name = "QNotch terminal output" };
        _writer = new Thread(Write) { IsBackground = true, Name = "QNotch terminal input" };
    }

    internal static ConPtySession Start(string executable, string arguments, string directory, int columns, int rows,
        Action<string, Action<string>> output, Action exited)
    {
        var session = new ConPtySession(output, exited);
        try { session.Create(executable, arguments, directory, columns, rows); return session; }
        catch { session.DisposeAsync().AsTask().GetAwaiter().GetResult(); throw; }
    }

    void Create(string executable, string arguments, string directory, int columns, int rows)
    {
        if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable)) throw new FileNotFoundException("Windows shell is unavailable.", executable);
        Check(CreatePipe(out var inputRead, out var inputWrite, 0, 0));
        _write = inputWrite;
        using (inputRead)
        {
            Check(CreatePipe(out var outputRead, out var outputWrite, 0, 0));
            _read = outputRead;
            using (outputWrite)
            {
                // Drain before console creation and keep draining throughout ClosePseudoConsole's final frame.
                _reader.Start();
                _readerStarted = true;
                Marshal.ThrowExceptionForHR(CreatePseudoConsole(Size(columns, rows), inputRead, outputWrite, 0, out _console));
                nuint bytes = 0;
                InitializeProcThreadAttributeList(0, 1, 0, ref bytes);
                var attrs = Marshal.AllocHGlobal(checked((int)bytes));
                var initialized = false;
                try
                {
                    Check(InitializeProcThreadAttributeList(attrs, 1, 0, ref bytes));
                    initialized = true;
                    Check(UpdateProcThreadAttribute(attrs, 0, 0x20016, _console, (nuint)nint.Size, 0, 0));
                    _job = CreateJobObject(0, null);
                    if (_job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                    var limits = new ExtendedLimits { Basic = new BasicLimits { Flags = 0x2000 } }; // KILL_ON_JOB_CLOSE
                    Check(SetInformationJobObject(_job, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>()));
                    // Null standard handles with STARTF_USESTDHANDLES let ConPTY supply console handles even when
                    // the host itself has redirected stdio (tests, packaged launchers). Never inherit the host's pipes.
                    var startup = new StartupInfoEx { StartupInfo = new StartupInfo { Size = Marshal.SizeOf<StartupInfoEx>(), Flags = 0x100 }, Attributes = attrs };
                    Check(CreateProcess(executable, new StringBuilder('"' + executable + "\" " + arguments), 0, 0, false,
                        0x80000 | 0x4 | 0x400, 0, directory, ref startup, out var info));
                    try
                    {
                        // Suspended until ownership is guaranteed. Descendants cannot escape the job via a startup race.
                        if (!AssignProcessToJobObject(_job, info.Process))
                        {
                            var error = Marshal.GetLastWin32Error();
                            TerminateProcess(info.Process, 1);
                            throw new Win32Exception(error);
                        }
                        ProcessId = info.ProcessId;
                        _process = Process.GetProcessById(ProcessId);
                        _process.EnableRaisingEvents = true;
                        _process.Exited += (_, _) => { _ = StopTask(); };
                        _writer.Start();
                        _writerStarted = true;
                        if (ResumeThread(info.Thread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                    finally { CloseHandle(info.Thread); CloseHandle(info.Process); }
                }
                finally
                {
                    if (initialized) DeleteProcThreadAttributeList(attrs);
                    Marshal.FreeHGlobal(attrs);
                }
            }
        }
    }

    static Coord Size(int columns, int rows) => new((short)Math.Clamp(columns, 20, 240), (short)Math.Clamp(rows, 2, 100));
    static void Check(bool ok) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }

    internal bool Send(string text)
    {
        // Bound pasted input as well as the queue. Split long user pastes at the view, never queue unbounded output.
        if (text.Length > 16384) return false;
        try { return _input.TryAdd(new Input(text)); } catch (Exception ex) when (ex is InvalidOperationException or ObjectDisposedException) { return false; }
    }
    void Reply(string text) => Send(text);
    internal void Resize(int columns, int rows)
    {
        try { _input.TryAdd(new Input(null, columns, rows)); } catch (Exception ex) when (ex is InvalidOperationException or ObjectDisposedException) { }
    }

    void Read()
    {
        try
        {
            using var stream = new FileStream(_read!, FileAccess.Read, 4096, false);
            var decoder = Encoding.UTF8.GetDecoder();
            var bytes = new byte[4096];
            var chars = new char[8192];
            int count;
            while ((count = stream.Read(bytes)) > 0)
            {
                var length = decoder.GetChars(bytes, 0, count, chars, 0);
                if (length > 0) _output(new string(chars, 0, length), Reply);
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException) { }
    }

    void Write()
    {
        try
        {
            using var stream = new FileStream(_write!, FileAccess.Write, 4096, false);
            foreach (var command in _input.GetConsumingEnumerable())
            {
                if (command.Text is { } text) { stream.Write(Encoding.UTF8.GetBytes(text)); stream.Flush(); }
                else lock (_gate) if (_console != 0) ResizePseudoConsole(_console, Size(command.Columns, command.Rows));
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException) { }
    }

    Task StopTask()
    {
        lock (_gate) return _stop ??= Task.Run(() =>
        {
            _input.CompleteAdding();
            _job?.Dispose(); // only this session's shell and descendants; never a process-name kill
            nint console;
            lock (_gate) { console = _console; _console = 0; }
            if (console != 0) ClosePseudoConsole(console); // reader stays alive to drain, never waits for the dispatcher
            _write?.Dispose();
            if (_writerStarted) _writer.Join();
            if (_readerStarted) _reader.Join();
            _read?.Dispose();
            if (_process is { } process) { process.WaitForExit(); process.Dispose(); }
            _input.Dispose();
            _exited();
            _completion.TrySetResult();
        });
    }

    public ValueTask DisposeAsync() => new(StopTask());
}
