using Readme.Core.Model;
using Readme.Core.Storage;

namespace Readme.Core.Library;

/// <summary>How an export went.</summary>
public readonly record struct ExportSummary(int Exported, int Missing)
{
    public string Line
    {
        get
        {
            var text = Exported == 1 ? "Exported 1 book" : $"Exported {Exported} books";
            if (Missing == 1) text += ", 1 was missing and left out";
            else if (Missing > 1) text += $", {Missing} were missing and left out";
            return text;
        }
    }
}

/// <summary>
/// Puts books from the library, with their highlights, marker and place, into one bundle file
/// (LibraryExporter.swift).
/// </summary>
public sealed class LibraryExporter(LibraryStore store)
{
    /// <summary>Books whose copy has gone are left out and counted. Nothing left to export throws, writing nothing.</summary>
    public async Task<ExportSummary> ExportAsync(IReadOnlyList<Book> books, string path, DateTimeOffset? now = null)
    {
        var exportedAt = now ?? DateTimeOffset.UtcNow;
        var (items, missing) = await Task.Run(() =>
        {
            var items = new List<BundleItem>();
            var missing = 0;
            foreach (var book in books)
            {
                var file = store.FilePath(book);
                if (!File.Exists(file))
                {
                    missing++;
                    continue;
                }
                items.Add(new BundleItem(
                    book.Id,
                    new BundledBook
                    {
                        Title = book.Title,
                        Author = book.Author,
                        AddedAt = book.AddedAt,
                        LastReadAt = book.LastReadAt,
                        PinnedAt = book.PinnedAt,
                    },
                    file,
                    store.Highlights.Highlights(book.Id),
                    store.Markers.Marker(book.Id),
                    store.Positions.Location(book.Id)));
            }
            return (items, missing);
        });
        if (items.Count == 0) throw new BundleException(BundleError.Unwritable);
        await Task.Run(() => LibraryBundle.Write(items, path, exportedAt));
        return new ExportSummary(items.Count, missing);
    }
}
