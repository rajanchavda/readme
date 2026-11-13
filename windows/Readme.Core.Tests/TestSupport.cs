using Readme.Core.Model;

namespace Readme.Core.Tests;

/// <summary>A new, empty folder for one test, deleted when disposed.</summary>
sealed class TempFolder : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ReadmeCoreTests-" + Guid.NewGuid());

    public TempFolder() => Directory.CreateDirectory(Path);

    public string this[string name] => System.IO.Path.Combine(Path, name);

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); } catch (IOException) { }
    }
}

static class Fixtures
{
    public static string Root => Path.Combine(AppContext.BaseDirectory, "Fixtures");
    public static string Of(string name) => Path.Combine(Root, name);
    public static string Golden(string name) => Path.Combine(Root, "Golden", name);
}

static class Samples
{
    /// <summary>Seconds since 1970, as the Swift tests' <c>Date(timeIntervalSince1970:)</c>.</summary>
    public static DateTimeOffset At(double seconds) =>
        DateTimeOffset.UnixEpoch.AddTicks((long)(seconds * TimeSpan.TicksPerSecond));

    public static Book Book(string id, double added, double? read = null, string? title = null, string? author = null) => new()
    {
        Id = id,
        Title = title ?? id,
        Author = author,
        FileName = id + ".epub",
        HasCover = false,
        AddedAt = At(added),
        LastReadAt = read is { } r ? At(r) : null,
    };

    public static readonly ReaderLocation Place = new()
    {
        Cfi = "epubcfi(/6/14!/4/2/10)",
        Fraction = 0.42,
        ChapterTitle = "Chapter 7",
        ChapterMinutesLeft = 6.5,
        IsAtStart = false,
        IsAtEnd = false,
        Page = 210,
        PageCount = 500,
    };
}
