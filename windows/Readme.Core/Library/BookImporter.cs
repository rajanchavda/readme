using System.Security.Cryptography;
using Readme.Core.Model;
using Readme.Core.Storage;
using Readme.Core.Zip;

namespace Readme.Core.Library;

/// <summary>What opening a staged book in a hidden view found: its title, author and cover as PNG.</summary>
public sealed record BookDetails(string? Title, string? Author, byte[]? CoverPng);

/// <summary>
/// Adds books to a library (BookImporter.swift): checks the file, copies it in, reads its title,
/// author and cover with a view nobody sees, and records it. The same book twice is one book.
/// The view is the app's: it's passed in as <c>details</c>, which throws for a book that won't open.
/// </summary>
public sealed class BookImporter(LibraryStore store, Func<string, Task<BookDetails>> details)
{
    readonly Dictionary<string, Task<Book>> _running = [];
    readonly Lock _lock = new();

    public async Task<Book> ImportAsync(string path)
    {
        if (!File.Exists(path)) throw new ImportException(ImportError.Unreadable);
        await Task.Run(() => EpubInspector.Check(path));

        var staged = Path.Combine(store.BooksDirectory, $".importing-{Guid.NewGuid():N}");
        try
        {
            try
            {
                await Task.Run(() =>
                {
                    Directory.CreateDirectory(store.BooksDirectory);
                    File.Copy(path, staged);
                });
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                throw new ImportException(ImportError.Unreadable);
            }
            // The copy is what's hashed, so the id is of what's kept.
            string id;
            try { id = await BookId.OfAsync(staged); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw new ImportException(ImportError.Unreadable); }
            if (store.Book(id) is { } existing) return existing;

            Task<Book> task;
            lock (_lock)
            {
                // The same book arriving twice at once waits for the first.
                if (!_running.TryGetValue(id, out task!))
                {
                    task = FinishAsync(staged, id, Path.GetFileNameWithoutExtension(path));
                    _running[id] = task;
                    staged = null!;
                }
            }
            try { return await task; }
            finally { lock (_lock) _running.Remove(id); }
        }
        finally
        {
            if (staged != null) Files.DeleteIfPresent(staged);
        }
    }

    /// <summary>Reads the staged copy's details, moves it into place and records the book.</summary>
    async Task<Book> FinishAsync(string staged, string id, string fallbackTitle)
    {
        try
        {
            BookDetails found;
            try { found = await details(staged); }
            catch (Exception error) when (error is not ImportException) { throw new ImportException(ImportError.Unreadable); }
            // Another import may have added it while the book was being read.
            if (store.Book(id) is { } existing) return existing;
            var book = new Book
            {
                Id = id,
                Title = string.IsNullOrWhiteSpace(found.Title) ? fallbackTitle : found.Title.Trim(),
                Author = string.IsNullOrWhiteSpace(found.Author) ? null : found.Author.Trim(),
                FileName = id + ".epub",
                HasCover = false,
                AddedAt = DateTimeOffset.UtcNow,
            };
            try
            {
                var hasCover = await Task.Run(() =>
                {
                    // A copy left by an import that never finished is replaced.
                    File.Move(staged, store.FilePath(book), overwrite: true);
                    var cover = store.CoverPath(book);
                    Files.DeleteIfPresent(cover);
                    if (found.CoverPng is not { Length: > 0 } png) return false;
                    try
                    {
                        Files.WriteAtomically(cover, png);
                        return true;
                    }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
                });
                book = book with { HasCover = hasCover };
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                throw new ImportException(ImportError.Unreadable);
            }
            store.Add(book);
            return store.Book(id) ?? book;
        }
        finally
        {
            Files.DeleteIfPresent(staged);
        }
    }

    /// <summary>Imports each in turn, whatever happens to the others.</summary>
    public async Task<IReadOnlyList<(string Path, Book? Book, ImportError? Error)>> ImportAllAsync(IEnumerable<string> paths)
    {
        var results = new List<(string, Book?, ImportError?)>();
        foreach (var path in paths)
        {
            try { results.Add((path, await ImportAsync(path), null)); }
            catch (ImportException error) { results.Add((path, null, error.Error)); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { results.Add((path, null, ImportError.Unreadable)); }
        }
        return results;
    }
}

/// <summary>
/// A picture of the spread each book was last left on (LastSpreadCache.swift), so launching into a
/// book can show it at once while the book opens behind it. Each is kept with a signature of the look
/// it was taken in, and only given back for the same look: a picture of the wrong size or theme is
/// worse than none.
/// </summary>
public sealed class LastSpreadCache(string directory)
{
    readonly Lock _lock = new();

    public string Directory { get; } = directory;

    /// <summary>Everything that changes how a spread is drawn: size, scale, columns and styles.</summary>
    public static string Signature(double width, double height, double scale, int columns, double? columnWidth, string css)
    {
        var styles = Convert.ToHexStringLower(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(css)));
        var column = columnWidth is { } w ? w.ToString("F1", System.Globalization.CultureInfo.InvariantCulture) : "auto";
        return string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{width:F0}x{height:F0}@{scale:F2} {columns}x{column} {styles}");
    }

    public string ImagePath(string bookId) => Path.Combine(Directory, Files.SafeName(bookId) + ".png");
    string SignaturePath(string bookId) => Path.Combine(Directory, Files.SafeName(bookId) + ".look");

    /// <summary>The PNG of the book's last spread, if one was kept for exactly this look.</summary>
    public byte[]? Image(string bookId, string signature)
    {
        lock (_lock)
        {
            try
            {
                if (!File.Exists(SignaturePath(bookId)) || File.ReadAllText(SignaturePath(bookId)) != signature) return null;
                return File.ReadAllBytes(ImagePath(bookId));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
        }
    }

    public void Save(byte[] png, string signature, string bookId)
    {
        lock (_lock)
        {
            try
            {
                // The picture first: a look without its picture is never left pointing at an old one.
                Files.DeleteIfPresent(SignaturePath(bookId));
                Files.WriteAtomically(ImagePath(bookId), png);
                Files.WriteAtomically(SignaturePath(bookId), System.Text.Encoding.UTF8.GetBytes(signature));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    public void Remove(string bookId)
    {
        lock (_lock)
        {
            Files.DeleteIfPresent(ImagePath(bookId));
            Files.DeleteIfPresent(SignaturePath(bookId));
        }
    }
}
