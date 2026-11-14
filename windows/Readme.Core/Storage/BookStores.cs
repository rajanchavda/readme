using System.Security.Cryptography;
using Readme.Core.Model;

namespace Readme.Core.Storage;

/// <summary>
/// Where the reader left each book (PositionStore.swift): one small file a book, replaced whole on
/// each save. One that can't be read is as good as none. Safe to use from several threads.
/// </summary>
public sealed class PositionStore(string directory)
{
    readonly Lock _lock = new();

    public string Directory { get; } = directory;

    public void Save(ReaderLocation location, string bookId)
    {
        lock (_lock) Files.WriteJson(FileFor(bookId), location, Json.Library);
    }

    public ReaderLocation? Location(string bookId)
    {
        lock (_lock) return Files.ReadJson<ReaderLocation>(FileFor(bookId), Json.Library);
    }

    public void Remove(string bookId)
    {
        lock (_lock) Files.DeleteIfPresent(FileFor(bookId));
    }

    string FileFor(string bookId) => Path.Combine(Directory, Files.SafeName(bookId) + ".json");
}

/// <summary>
/// The highlights of each book (HighlightStore.swift), one small file a book, replaced whole on each
/// change. A file that can't be read is as good as none.
/// </summary>
public sealed class HighlightStore(string directory)
{
    readonly Lock _lock = new();

    public string Directory { get; } = directory;

    /// <summary>A book's highlights in reading order: by fraction, then by when they were made.</summary>
    public IReadOnlyList<Highlight> Highlights(string bookId)
    {
        lock (_lock) return Read(bookId);
    }

    /// <summary>Adds it. Marking the same passage again leaves the first as it is.</summary>
    public void Add(Highlight highlight, string bookId)
    {
        lock (_lock)
        {
            var all = Read(bookId);
            if (all.Any(h => h.Cfi == highlight.Cfi)) return;
            all.Add(highlight);
            Write(all, bookId);
        }
    }

    /// <summary>
    /// Adds those that are new here: neither their id nor their passage is marked already. Nothing
    /// already here changes. Returns how many were added.
    /// </summary>
    public int Merge(IEnumerable<Highlight> incoming, string bookId)
    {
        lock (_lock)
        {
            var all = Read(bookId);
            var before = all.Count;
            foreach (var highlight in incoming)
                if (!all.Any(h => h.Id == highlight.Id || h.Cfi == highlight.Cfi)) all.Add(highlight);
            if (all.Count == before) return 0;
            Write(all, bookId);
            return all.Count - before;
        }
    }

    public void Remove(Guid id, string bookId)
    {
        lock (_lock)
        {
            var all = Read(bookId);
            var kept = all.Where(h => h.Id != id).ToList();
            if (kept.Count != all.Count) Write(kept, bookId);
        }
    }

    /// <summary>Deletes every highlight of the book.</summary>
    public void Remove(string bookId)
    {
        lock (_lock) Files.DeleteIfPresent(FileFor(bookId));
    }

    List<Highlight> Read(string bookId) =>
        (Files.ReadJson<List<Highlight>>(FileFor(bookId), Json.Iso) ?? [])
            .OrderBy(h => h.Fraction).ThenBy(h => h.Created).ToList();

    void Write(List<Highlight> all, string bookId) => Files.WriteJson(FileFor(bookId), all, Json.Iso);

    string FileFor(string bookId) => Path.Combine(Directory, Files.SafeName(bookId) + ".json");
}

/// <summary>
/// Each book's marker (MarkerStore.swift), one small file a book. Setting it again moves it. A file
/// that can't be read is as good as none.
/// </summary>
public sealed class MarkerStore(string directory)
{
    readonly Lock _lock = new();

    public string Directory { get; } = directory;

    public Marker? Marker(string bookId)
    {
        lock (_lock) return Files.ReadJson<Marker>(FileFor(bookId), Json.Iso);
    }

    public void Set(Marker marker, string bookId)
    {
        lock (_lock) Files.WriteJson(FileFor(bookId), marker, Json.Iso);
    }

    /// <summary>Sets it only if the book has no marker yet. Returns whether it did.</summary>
    public bool SetIfNone(Marker marker, string bookId)
    {
        lock (_lock)
        {
            if (Files.ReadJson<Marker>(FileFor(bookId), Json.Iso) != null) return false;
            Files.WriteJson(FileFor(bookId), marker, Json.Iso);
            return true;
        }
    }

    public void Remove(string bookId)
    {
        lock (_lock) Files.DeleteIfPresent(FileFor(bookId));
    }

    string FileFor(string bookId) => Path.Combine(Directory, Files.SafeName(bookId) + ".json");
}

/// <summary>How an imported place is weighed against the one already here.</summary>
public static class ImportMerge
{
    /// <summary>Whether <paramref name="incoming"/> is further into the book, or there's no place here.</summary>
    public static bool IsFurther(ReaderLocation incoming, ReaderLocation? existing) =>
        existing == null || incoming.Fraction > existing.Fraction;
}

/// <summary>
/// A book's ID: the SHA-256 of the file's contents in lower-case hex, so the same book has the same
/// ID wherever it's kept, whatever it's called, and on either platform.
/// </summary>
public static class BookId
{
    public static async Task<string> OfAsync(string path, CancellationToken cancellation = default)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            bufferSize: 1 << 20, useAsync: true);
        return Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, cancellation));
    }

    /// <summary>64 lower-case hex digits, as <see cref="OfAsync"/> makes them.</summary>
    public static bool IsValid(string id) =>
        id.Length == 64 && id.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
}
