using Readme.Core.Model;
using Readme.Core.Storage;

namespace Readme.Core.Reader;

/// <summary>
/// Where the app opens (LaunchRoute.swift): straight into the book last read, at its place, or the
/// library when no book has been read yet or the last one's file has gone.
/// </summary>
public abstract record LaunchRoute
{
    public sealed record Library : LaunchRoute;
    public sealed record Read(Book Book, string? Cfi) : LaunchRoute;

    /// <summary>A book that was read but whose place was never kept opens at its start.</summary>
    public static LaunchRoute Resolve(LibraryStore library, Func<string, ReaderLocation?> position, Func<string, bool> fileExists)
    {
        if (library.Current is not { LastReadAt: not null } book || !fileExists(library.FilePath(book)))
            return new Library();
        return new Read(book, position(book.Id)?.Cfi);
    }
}

/// <summary>
/// Writes places to a store one at a time, off the UI thread, so a reader turning pages quickly never
/// waits on the disk (PlaceWriter in PositionStore.swift). Of a book's places waiting, only the newest
/// is written.
/// </summary>
public sealed class PlaceWriter(PositionStore store)
{
    readonly Lock _lock = new();
    readonly Dictionary<string, ReaderLocation> _unsaved = [];
    Task _saving = Task.CompletedTask;
    bool _running;

    public void Save(ReaderLocation location, string bookId)
    {
        lock (_lock)
        {
            _unsaved[bookId] = location;
            if (_running) return;
            _running = true;
            _saving = Task.Run(Drain);
        }
    }

    void Drain()
    {
        while (true)
        {
            KeyValuePair<string, ReaderLocation> next;
            lock (_lock)
            {
                if (_unsaved.Count == 0)
                {
                    _running = false;
                    return;
                }
                next = _unsaved.First();
                _unsaved.Remove(next.Key);
            }
            try { store.Save(next.Value, next.Key); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>Returns once every place given so far is written.</summary>
    public async Task WrittenAsync()
    {
        while (true)
        {
            Task saving;
            lock (_lock)
            {
                if (!_running && _unsaved.Count == 0) return;
                saving = _saving;
            }
            await saving.ConfigureAwait(false);
        }
    }
}

/// <summary>
/// The soft shadow where the two pages meet (SpineShadow.swift): a gradient on each page, darkest at
/// the spine, as the mockup's inset shadow.
/// </summary>
public static class SpineShadow
{
    /// <summary>How far the shadow reaches into each page.</summary>
    public const double Reach = 32;

    /// <summary>Its darkness, as a share of the colour's, from the page side (0) to the spine (1).</summary>
    public static readonly IReadOnlyList<(double Location, double Share)> Falloff =
        [(0, 0), (0.375, 0.14), (0.625, 0.32), (0.8125, 0.5), (1, 0.68)];

    /// <summary>The shadow's share of its colour <paramref name="distance"/> pixels from the spine.</summary>
    public static double ShareAt(double distance)
    {
        var location = 1 - Math.Max(0, distance) / Reach;
        if (location <= 0) return 0;
        for (var i = 1; i < Falloff.Count; i++)
        {
            var (lowerAt, lowerShare) = Falloff[i - 1];
            var (upperAt, upperShare) = Falloff[i];
            if (location <= upperAt) return lowerShare + (upperShare - lowerShare) * (location - lowerAt) / (upperAt - lowerAt);
        }
        return Falloff[^1].Share;
    }
}
