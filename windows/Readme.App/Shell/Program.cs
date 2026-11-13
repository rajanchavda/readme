using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Windows.ApplicationModel.Activation;

namespace Readme.App;

/// <summary>
/// The app's own entry point, in place of the one XAML generates, so that a second launch never
/// becomes a second window. Double-clicking a book while Readme is open, or opening it again from the
/// Start menu, hands the files to the running app (as the Mac's Dock does) and quits before any
/// window appears. Instances are told apart by their library folder, so a self-check with its own
/// data folder never lands in the reader's app, or the reverse.
/// </summary>
static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        var main = AppInstance.FindOrRegisterForKey(InstanceKey);
        if (!main.IsCurrent)
        {
            Redirect(main, activation);
            return 0;
        }
        // Files and command lines given to a later launch, handed on to this one.
        main.Activated += (_, redirected) => Activated?.Invoke(Paths(redirected, null));
        var paths = Paths(activation, args);
        Application.Start(_ =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            new App(paths);
        });
        return 0;
    }

    /// <summary>Raised, off the UI thread, with the files of a launch redirected here.</summary>
    public static event Action<IReadOnlyList<string>>? Activated;

    /// <summary>One app per library folder.</summary>
    static string InstanceKey =>
        "Readme-" + Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(Path.GetFullPath(AppPaths.Library).ToLowerInvariant())))[..16];

    /// <summary>
    /// What a launch was given: the files of a file activation (a double-click, or Open with), or the
    /// arguments of a command line. <paramref name="args"/> is the first launch's own command line,
    /// which is fuller than the activation's string.
    /// </summary>
    static IReadOnlyList<string> Paths(AppActivationArguments activation, string[]? args)
    {
        if (activation.Kind == ExtendedActivationKind.File && activation.Data is IFileActivatedEventArgs file)
            return file.Files.Select(f => f.Path).Where(p => !string.IsNullOrEmpty(p)).ToList();
        if (args != null) return args;
        if (activation.Kind == ExtendedActivationKind.Launch && activation.Data is ILaunchActivatedEventArgs launch)
            return SplitCommandLine(launch.Arguments);
        return [];
    }

    /// <summary>A command line as Windows splits it, quotes and all. The program's own name, if there, is left out.</summary>
    internal static IReadOnlyList<string> SplitCommandLine(string? line)
    {
        if (string.IsNullOrWhiteSpace(line)) return [];
        var argv = CommandLineToArgvW(line, out var count);
        if (argv == 0) return [];
        try
        {
            var parts = new List<string>();
            for (var i = 0; i < count; i++) parts.Add(Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size)) ?? "");
            if (parts.Count > 0 && parts[0].EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) parts.RemoveAt(0);
            return parts;
        }
        finally
        {
            LocalFree(argv);
        }
    }

    /// <summary>
    /// Hands the launch to the app already running, and lets it come to the front. The redirect is
    /// waited for while still pumping COM, as an STA thread must.
    /// </summary>
    static void Redirect(AppInstance main, AppActivationArguments activation)
    {
        AllowSetForegroundWindow(main.ProcessId);
        var done = CreateEvent(0, true, false, null);
        _ = Task.Run(async () =>
        {
            try { await main.RedirectActivationToAsync(activation); }
            finally { SetEvent(done); }
        });
        CoWaitForMultipleObjects(0, 0xFFFFFFFF, 1, [done], out _);
        CloseHandle(done);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern nint CommandLineToArgvW(string line, out int count);
    [DllImport("kernel32.dll")] static extern nint LocalFree(nint memory);
    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern nint CreateEvent(nint attributes, bool manualReset, bool initialState, string? name);
    [DllImport("kernel32.dll")] static extern bool SetEvent(nint handle);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(nint handle);
    [DllImport("ole32.dll")] static extern int CoWaitForMultipleObjects(uint flags, uint timeout, uint count, nint[] handles, out uint index);
}
