using System.Text.Json;
using System.Text.Json.Serialization;
using Readme.Core.Model;
using Readme.Core.Storage;
using Readme.Core.Zip;

namespace Readme.Core.Library;

/// <summary>What a bundle says about itself (BundleManifest in LibraryBundle.swift).</summary>
public sealed record BundleManifest
{
    /// <summary>The newest layout this Readme can read.</summary>
    public const int CurrentVersion = 1;

    public required int FormatVersion { get; init; }
    public required DateTimeOffset ExportedAt { get; init; }
    [JsonPropertyName("bookIDs")]
    public required IReadOnlyList<string> BookIds { get; init; }

    public bool Equals(BundleManifest? other) =>
        other != null && FormatVersion == other.FormatVersion && ExportedAt == other.ExportedAt && BookIds.SequenceEqual(other.BookIds);

    public override int GetHashCode() => HashCode.Combine(FormatVersion, ExportedAt, BookIds.Count);
}

/// <summary>A book as the shelf shows it, as it travels in a bundle.</summary>
public sealed record BundledBook
{
    public required string Title { get; init; }
    public string? Author { get; init; }
    public required DateTimeOffset AddedAt { get; init; }
    public DateTimeOffset? LastReadAt { get; init; }
    /// <summary>When it was pinned to the front of the shelf. Bundles from before pins have none.</summary>
    public DateTimeOffset? PinnedAt { get; init; }
}

/// <summary>One book to put in a bundle.</summary>
public sealed record BundleItem(string Id, BundledBook Info, string Epub, IReadOnlyList<Highlight> Highlights,
    Marker? Marker, ReaderLocation? Position);

/// <summary>One book's notes, as read back from a bundle.</summary>
public sealed record BundleContents(BundledBook Info, IReadOnlyList<Highlight> Highlights, Marker? Marker, ReaderLocation? Position)
{
    public bool Equals(BundleContents? other) =>
        other != null && Info == other.Info && Highlights.SequenceEqual(other.Highlights) && Marker == other.Marker && Position == other.Position;

    public override int GetHashCode() => HashCode.Combine(Info, Highlights.Count, Marker, Position);
}

public enum BundleError { NotABundle, NewerVersion, TooLarge, Unwritable }

public sealed class BundleException(BundleError error) : Exception(BundleErrors.Message(error))
{
    public BundleError Error { get; } = error;
}

public static class BundleErrors
{
    public static string Message(BundleError error) => error switch
    {
        BundleError.NotABundle => "This file isn't a Readme library.",
        BundleError.NewerVersion => "This library was made by a newer Readme. Update Readme to import it.",
        BundleError.TooLarge => "That's more than 4 GB, too much for one file. Export fewer books at a time.",
        _ => "The export couldn't be saved.",
    };
}

/// <summary>
/// A <c>.readmelibrary</c> file (LibraryBundle.swift; see <c>docs/readmelibrary-format.md</c>): a zip
/// of stored entries laid out as
/// <code>
/// manifest.json
/// books/&lt;id&gt;/book.json, book.epub, highlights.json, marker.json?, position.json?
/// </code>
/// Book IDs are the SHA-256 of the EPUB, so a bundle whose IDs are anything else is refused before
/// one of them is ever used as a path.
/// </summary>
public static class LibraryBundle
{
    public const string Extension = ".readmelibrary";
    public const long MaxBookSize = 1L << 31;
    public const long MaxNotesSize = 64L << 20;

    /// <summary>Writes the bundle, or throws a <see cref="BundleException"/> having left no file behind.</summary>
    public static void Write(IReadOnlyList<BundleItem> items, string path, DateTimeOffset exportedAt)
    {
        try
        {
            using var writer = new ZipWriter(path);
            var manifest = new BundleManifest
            {
                FormatVersion = BundleManifest.CurrentVersion,
                ExportedAt = exportedAt,
                BookIds = items.Select(i => i.Id).ToList(),
            };
            writer.Add("manifest.json", Encode(manifest));
            foreach (var item in items)
            {
                var folder = $"books/{item.Id}/";
                writer.Add(folder + "book.json", Encode(item.Info));
                writer.Add(folder + "highlights.json", Encode(item.Highlights));
                if (item.Marker != null) writer.Add(folder + "marker.json", Encode(item.Marker));
                if (item.Position != null) writer.Add(folder + "position.json", Encode(item.Position));
                writer.Add(folder + "book.epub", item.Epub);
            }
            writer.Finish();
        }
        catch (ZipWriterException error)
        {
            Files.DeleteIfPresent(path);
            throw new BundleException(error.Failure == ZipWriterFailure.TooLarge ? BundleError.TooLarge : BundleError.Unwritable);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            Files.DeleteIfPresent(path);
            throw new BundleException(BundleError.Unwritable);
        }
    }

    static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Json.Iso);

    /// <summary>Opens and checks the bundle: refused whole, never half read.</summary>
    public static OpenedBundle Open(string path)
    {
        var archive = ZipReader.Open(path);
        var data = archive?.Data("manifest.json", MaxNotesSize);
        BundleManifest? manifest = null;
        if (data != null)
        {
            try { manifest = JsonSerializer.Deserialize<BundleManifest>(data, Json.Iso); }
            catch (JsonException) { }
        }
        if (archive == null || manifest?.BookIds == null) throw new BundleException(BundleError.NotABundle);
        if (manifest.FormatVersion > BundleManifest.CurrentVersion) throw new BundleException(BundleError.NewerVersion);
        foreach (var id in manifest.BookIds)
        {
            if (!BookId.IsValid(id) || !archive.Contains($"books/{id}/book.json") || !archive.Contains($"books/{id}/book.epub"))
                throw new BundleException(BundleError.NotABundle);
        }
        return new OpenedBundle(path, manifest);
    }
}

/// <summary>A bundle that has been checked, ready to read books from.</summary>
public sealed class OpenedBundle(string path, BundleManifest manifest)
{
    public string Path { get; } = path;
    public BundleManifest Manifest { get; } = manifest;

    public BundleContents Contents(string id)
    {
        if (!BookId.IsValid(id) || ZipReader.Open(Path) is not { } archive) throw new BundleException(BundleError.NotABundle);
        var folder = $"books/{id}/";
        T? Read<T>(string name) where T : class
        {
            if (archive.Data(folder + name, LibraryBundle.MaxNotesSize) is not { } data) return null;
            try { return JsonSerializer.Deserialize<T>(data, Json.Iso); }
            catch (JsonException) { return null; }
        }
        var info = Read<BundledBook>("book.json") ?? throw new BundleException(BundleError.NotABundle);
        return new BundleContents(info, Read<List<Highlight>>("highlights.json") ?? [], Read<Marker>("marker.json"),
            Read<ReaderLocation>("position.json"));
    }

    /// <summary>Writes the book's EPUB to <paramref name="destination"/>, replacing anything there.</summary>
    public void ExtractEpub(string id, string destination)
    {
        if (!BookId.IsValid(id) || ZipReader.Open(Path) is not { } archive
            || !archive.CopyTo($"books/{id}/book.epub", destination, LibraryBundle.MaxBookSize))
            throw new BundleException(BundleError.NotABundle);
    }
}
