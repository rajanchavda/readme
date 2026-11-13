using Readme.Core.Storage;
using Readme.Core.Zip;

namespace Readme.Core.Library;

/// <summary>
/// A bundle opened and sorted: the books new to this library, and those already in it, each in the
/// bundle's order.
/// </summary>
public sealed record PreparedImport(OpenedBundle Bundle, IReadOnlyList<string> NewIds, IReadOnlyList<string> ExistingIds);

/// <summary>What to do with the books that are here already.</summary>
public enum ImportChoice
{
    /// <summary>Leave them exactly as they are.</summary>
    KeepMine,
    /// <summary>Add the highlights not here yet, keep the further place, and keep this machine's marker if it has one.</summary>
    Combine,
}

/// <summary>How an import went.</summary>
public readonly record struct ImportSummary(int Added = 0, int Combined = 0, int Kept = 0, int Failed = 0)
{
    public string Line
    {
        get
        {
            var parts = new List<string>();
            if (Added > 0) parts.Add(Added == 1 ? "added 1 book" : $"added {Added} books");
            if (Combined > 0) parts.Add($"combined {Combined}");
            if (Kept > 0) parts.Add($"left {Kept} as they were");
            if (Failed > 0) parts.Add($"{Failed} couldn't be read");
            if (parts.Count == 0) return "Nothing to import";
            var text = string.Join(", ", parts);
            return char.ToUpperInvariant(text[0]) + text[1..];
        }
    }
}

/// <summary>The question asked when some of a bundle's books are here already (ImportQuestion in AppCoordinator.swift).</summary>
public static class ImportQuestion
{
    public static string Message(int existing, int total) =>
        total == 1 ? "This book is already in your library."
        : existing == 1 ? "1 of these books is already in your library."
        : $"{existing} of these books are already in your library.";

    public const string Informative = "Keep Mine leaves your copy as it is. Combine adds the highlights you don't have and keeps whichever reading place is further along. Your copy of the book is never replaced.";
    public static readonly IReadOnlyList<string> Buttons = ["Keep Mine", "Combine", "Cancel"];
}

/// <summary>
/// Brings books in from a bundle (LibraryImporter.swift). A book already in the library is never
/// replaced: at most, with <see cref="ImportChoice.Combine"/>, what the bundle knows about it is added
/// to what's here. <paramref name="spreads"/>, if given, loses the picture of a book whose place moves.
/// </summary>
public sealed class LibraryImporter(LibraryStore store, BookImporter importer, LastSpreadCache? spreads = null)
{
    /// <summary>Opens and checks the bundle, and sorts its books.</summary>
    public async Task<PreparedImport> PrepareAsync(string path)
    {
        var bundle = await Task.Run(() => LibraryBundle.Open(path));
        var ids = bundle.Manifest.BookIds;
        return new PreparedImport(bundle, ids.Where(id => store.Book(id) == null).ToList(), ids.Where(id => store.Book(id) != null).ToList());
    }

    public async Task<ImportSummary> RunAsync(PreparedImport prepared, ImportChoice choice)
    {
        var summary = new ImportSummary();
        foreach (var id in prepared.Bundle.Manifest.BookIds)
        {
            // Sorted when prepared, but another import may have added it since.
            if (store.Book(id) != null)
            {
                if (choice == ImportChoice.KeepMine) summary = summary with { Kept = summary.Kept + 1 };
                else if (await CombineAsync(id, prepared.Bundle)) summary = summary with { Combined = summary.Combined + 1 };
                else summary = summary with { Failed = summary.Failed + 1 };
            }
            else if (await AddAsync(id, prepared.Bundle)) summary = summary with { Added = summary.Added + 1 };
            else summary = summary with { Failed = summary.Failed + 1 };
        }
        return summary;
    }

    /// <summary>A book new here: its file through the usual import, then everything the bundle knows about it.</summary>
    async Task<bool> AddAsync(string id, OpenedBundle bundle)
    {
        var staged = Path.Combine(store.BooksDirectory, $".bundle-{Guid.NewGuid():N}.epub");
        try
        {
            var contents = await Task.Run(() =>
            {
                try
                {
                    Directory.CreateDirectory(store.BooksDirectory);
                    var contents = bundle.Contents(id);
                    bundle.ExtractEpub(id, staged);
                    return contents;
                }
                catch (Exception error) when (error is BundleException or IOException or UnauthorizedAccessException)
                {
                    return null;
                }
            });
            if (contents == null) return false;
            // A book that isn't the book it says it is doesn't come in.
            try { if (await BookId.OfAsync(staged) != id) return false; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
            try { await importer.ImportAsync(staged); }
            catch (Exception error) when (error is ImportException or IOException or UnauthorizedAccessException) { return false; }
            if (store.Book(id) == null) return false;

            // Named as the shelf showed it there, not by the file or the staged copy's name.
            store.SetDetails(id, contents.Info.Title, contents.Info.Author);
            store.ApplyImported(id, contents.Info.AddedAt, contents.Info.LastReadAt, contents.Position);
            // Only a book new here takes the bundle's pin: how this shelf is arranged is this machine's own.
            if (contents.Info.PinnedAt is { } pinnedAt) store.RestorePin(id, pinnedAt);
            await Task.Run(() =>
            {
                store.Highlights.Merge(contents.Highlights, id);
                if (contents.Marker != null) store.Markers.SetIfNone(contents.Marker, id);
                if (contents.Position != null && ImportMerge.IsFurther(contents.Position, store.Positions.Location(id)))
                    store.Positions.Save(contents.Position, id);
            });
            return true;
        }
        finally
        {
            Files.DeleteIfPresent(staged);
        }
    }

    /// <summary>
    /// A book already here: the bundle's highlights it doesn't have, its marker if there's none here,
    /// and its place if that's further along.
    /// </summary>
    async Task<bool> CombineAsync(string id, OpenedBundle bundle) => await Task.Run(() =>
    {
        BundleContents contents;
        try { contents = bundle.Contents(id); }
        catch (BundleException) { return false; }
        store.Highlights.Merge(contents.Highlights, id);
        if (contents.Marker != null) store.Markers.SetIfNone(contents.Marker, id);
        Model.ReaderLocation? further = null;
        if (contents.Position != null && ImportMerge.IsFurther(contents.Position, store.Positions.Location(id)))
        {
            store.Positions.Save(contents.Position, id);
            further = contents.Position;
        }
        store.ApplyImported(id, null, contents.Info.LastReadAt, further);
        // The picture of where it was left may no longer be where it opens.
        if (further != null) spreads?.Remove(id);
        return true;
    });
}
