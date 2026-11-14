using System.Text.Json.Serialization;

namespace Readme.Core.Model;

/// <summary>
/// A book in the library, as <c>library.json</c> keeps it (Book.swift). <see cref="Id"/> is the
/// SHA-256 of the file (see <see cref="BookId"/>), so the same book is the same wherever it came from.
/// A field marked required must be in the file, or the whole file is unreadable, as on Mac.
/// </summary>
public sealed record Book
{
    public required string Id { get; init; }
    public required string Title { get; init; }
    public string? Author { get; init; }
    /// <summary>The copy's name in the library's Books folder, <c>&lt;id&gt;.epub</c>.</summary>
    public required string FileName { get; init; }
    public required bool HasCover { get; init; }
    public required DateTimeOffset AddedAt { get; init; }
    public DateTimeOffset? LastReadAt { get; init; }
    /// <summary>Where the reader left off, as the shelf shows it.</summary>
    public string? ChapterTitle { get; init; }
    public double? ChapterMinutesLeft { get; init; }
    /// <summary>When the reader pinned it to the front of the shelf, or null if it isn't pinned.</summary>
    public DateTimeOffset? PinnedAt { get; init; }

    /// <summary>A book never read counts from when it was added.</summary>
    [JsonIgnore]
    public DateTimeOffset Recency => LastReadAt ?? AddedAt;
}
