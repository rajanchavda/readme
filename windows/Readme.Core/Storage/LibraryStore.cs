using Readme.Core.Model;

namespace Readme.Core.Storage;

/// <summary>
/// The books in the library (LibraryStore.swift), kept in <see cref="Directory"/>: <c>library.json</c>,
/// the copies in <c>Books</c> and the covers in <c>Covers</c>, with places, highlights and markers in
/// folders beside them. Every change is written at once, replacing the file whole. A library file that
/// can't be read is as good as none. Safe to use from several threads.
/// </summary>
public sealed class LibraryStore
{
    readonly Lock _lock = new();
    readonly Func<DateTimeOffset> _now;
    List<Book> _books;

    /// <summary>The app's own library: <c>Documents\Readme</c>, so it survives an uninstall.</summary>
    public static string DefaultDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Readme");

    public string Directory { get; }
    public PositionStore Positions { get; }
    public HighlightStore Highlights { get; }
    public MarkerStore Markers { get; }

    /// <summary>Raised after any change to <see cref="Books"/>, on the thread that made it.</summary>
    public event Action? Changed;

    /// <summary>
    /// Hears a book being taken out, after it's off the list and before its files go: the place for
    /// the app to drop anything else it keeps for the book, such as its last spread.
    /// </summary>
    public event Action<string>? Removing;

    public LibraryStore(string directory, PositionStore? positions = null, HighlightStore? highlights = null,
        MarkerStore? markers = null, Func<DateTimeOffset>? now = null)
    {
        Directory = directory;
        Positions = positions ?? new PositionStore(Path.Combine(directory, "Positions"));
        Highlights = highlights ?? new HighlightStore(Path.Combine(directory, "Highlights"));
        Markers = markers ?? new MarkerStore(Path.Combine(directory, "Markers"));
        var clock = now ?? (() => DateTimeOffset.UtcNow);
        // Every date the store sets is one the file can hold exactly, so the books in memory are
        // the books a restart reads back.
        _now = () => ReferenceDateConverter.Normalize(clock());
        _books = Files.ReadJson<List<Book>>(LibraryFile, Json.Library) ?? [];
    }

    public string LibraryFile => Path.Combine(Directory, "library.json");
    public string BooksDirectory => Path.Combine(Directory, "Books");
    public string CoversDirectory => Path.Combine(Directory, "Covers");

    public IReadOnlyList<Book> Books
    {
        get { lock (_lock) return _books.ToList(); }
    }

    /// <summary>The book last read, or if none has been, the one added last.</summary>
    public Book? Current
    {
        get { lock (_lock) return CurrentOf(_books); }
    }

    static Book? CurrentOf(List<Book> books) =>
        books.Where(b => b.LastReadAt != null).MaxBy(b => b.LastReadAt) ?? books.MaxBy(b => b.AddedAt);

    /// <summary>
    /// The rest of the shelf: the pinned ones first, the latest pin first, then the others latest
    /// first. The current book is on the ledge above, pinned or not, and isn't repeated here.
    /// </summary>
    public IReadOnlyList<Book> Others
    {
        get
        {
            lock (_lock)
            {
                var current = CurrentOf(_books);
                var rest = _books.Where(b => b.Id != current?.Id).ToList();
                return rest.Where(b => b.PinnedAt != null).OrderByDescending(b => b.PinnedAt)
                    .Concat(rest.Where(b => b.PinnedAt == null).OrderByDescending(b => b.Recency))
                    .ToList();
            }
        }
    }

    public Book? Book(string id)
    {
        lock (_lock) return _books.FirstOrDefault(b => b.Id == id);
    }

    /// <summary>A book already in the library stays as it is.</summary>
    public void Add(Book book) => Change(books =>
    {
        if (books.Any(b => b.Id == book.Id)) return false;
        books.Add(book with
        {
            AddedAt = ReferenceDateConverter.Normalize(book.AddedAt),
            LastReadAt = book.LastReadAt is { } read ? ReferenceDateConverter.Normalize(read) : null,
            PinnedAt = book.PinnedAt is { } pinned ? ReferenceDateConverter.Normalize(pinned) : null,
        });
        return true;
    });

    /// <summary>
    /// Pins the books to the front of the shelf, or unpins them. A book pinned already keeps its pin,
    /// and so its place among the pins. IDs not in the library are passed over.
    /// </summary>
    public void SetPinned(IEnumerable<string> ids, bool pinned)
    {
        var moment = _now();
        var wanted = ids.ToHashSet();
        Change(books =>
        {
            var changed = false;
            for (var i = 0; i < books.Count; i++)
            {
                if (!wanted.Contains(books[i].Id)) continue;
                DateTimeOffset? value = pinned ? books[i].PinnedAt ?? moment : null;
                if (books[i].PinnedAt == value) continue;
                books[i] = books[i] with { PinnedAt = value };
                changed = true;
            }
            return changed;
        });
    }

    /// <summary>Pins the book as it was pinned elsewhere, at <paramref name="date"/>, for an import.</summary>
    public void RestorePin(string id, DateTimeOffset date) =>
        Update(id, b => b with { PinnedAt = ReferenceDateConverter.Normalize(date) });

    public void MarkRead(string id, ReaderLocation location)
    {
        var moment = _now();
        Update(id, b => b with
        {
            LastReadAt = moment,
            ChapterTitle = location.ChapterTitle,
            ChapterMinutesLeft = location.ChapterMinutesLeft,
        });
    }

    /// <summary>
    /// What an imported bundle says about a book: when it was added, if given; the later of the two
    /// read dates; and, with <paramref name="location"/>, the chapter the shelf shows.
    /// </summary>
    public void ApplyImported(string id, DateTimeOffset? addedAt, DateTimeOffset? lastReadAt, ReaderLocation? location) =>
        Update(id, b =>
        {
            if (addedAt != null) b = b with { AddedAt = ReferenceDateConverter.Normalize(addedAt.Value) };
            if (lastReadAt != null && (b.LastReadAt == null || lastReadAt > b.LastReadAt))
                b = b with { LastReadAt = ReferenceDateConverter.Normalize(lastReadAt.Value) };
            if (location != null) b = b with { ChapterTitle = location.ChapterTitle, ChapterMinutesLeft = location.ChapterMinutesLeft };
            return b;
        });

    /// <summary>The title and author the shelf shows, as another machine's shelf showed them.</summary>
    public void SetDetails(string id, string title, string? author) =>
        Update(id, b => b with { Title = title, Author = author });

    /// <summary>Takes out, quietly, every book whose copy has gone, and returns them.</summary>
    public IReadOnlyList<Book> RemoveMissing(Func<string, bool> fileExists)
    {
        var missing = Books.Where(b => !fileExists(FilePath(b))).ToList();
        foreach (var book in missing) Remove(book.Id);
        return missing;
    }

    /// <summary>
    /// Takes the book out, and deletes its copy, its cover, its saved place, its highlights and its
    /// marker. <see cref="Removing"/> is raised first, for anything else the app keeps for it.
    /// </summary>
    public void Remove(string id)
    {
        Book? book = null;
        Change(books =>
        {
            book = books.FirstOrDefault(b => b.Id == id);
            return book != null && books.Remove(book);
        });
        if (book == null) return;
        Removing?.Invoke(id);
        Files.DeleteIfPresent(FilePath(book));
        Files.DeleteIfPresent(CoverPath(book));
        Positions.Remove(id);
        Highlights.Remove(id);
        Markers.Remove(id);
    }

    public string FilePath(Book book) => Path.Combine(BooksDirectory, book.FileName);

    public string CoverPath(Book book) => Path.Combine(CoversDirectory, book.Id + ".png");

    void Update(string id, Func<Book, Book> change) => Change(books =>
    {
        var index = books.FindIndex(b => b.Id == id);
        if (index < 0) return false;
        books[index] = change(books[index]);
        return true;
    });

    /// <summary>Applies <paramref name="change"/> and, if it says it changed anything, saves.</summary>
    void Change(Func<List<Book>, bool> change)
    {
        lock (_lock)
        {
            if (!change(_books)) return;
            // As on Mac, a failed save keeps the change in memory; the next one tries again.
            try
            {
                Files.WriteJson(LibraryFile, _books, Json.Library);
                LastSaveError = null;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                LastSaveError = error;
            }
        }
        Changed?.Invoke();
    }

    /// <summary>Why the last save failed, or null if it worked.</summary>
    public Exception? LastSaveError { get; private set; }
}
