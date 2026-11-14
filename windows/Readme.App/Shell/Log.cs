using System.Diagnostics;

namespace Readme.App;

/// <summary>
/// A plain-text log, written only when README_DATA_DIR is set (the self-checks); otherwise to the
/// debugger alone. Nothing about the books read goes to it beyond what's needed to debug.
/// </summary>
static class Log
{
    static readonly string? Path = Environment.GetEnvironmentVariable("README_DATA_DIR") is { } folder
        ? System.IO.Path.Combine(folder, "log.txt") : null;
    static readonly Lock Gate = new();
    static readonly Stopwatch Clock = Stopwatch.StartNew();

    public static void Write(string message)
    {
        var line = $"{Clock.ElapsedMilliseconds,7} {message}";
        Debug.WriteLine(line);
        if (Path == null) return;
        lock (Gate)
        {
            try { File.AppendAllText(Path, line + Environment.NewLine); }
            catch (IOException) { }
        }
    }
}
