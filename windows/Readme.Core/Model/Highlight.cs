using Readme.Core.Storage;

namespace Readme.Core.Model;

/// <summary>
/// A passage the reader marked (HighlightStore.swift), anchored by the CFI of its range so it comes
/// back at the same words whatever the font or window size.
/// </summary>
public sealed record Highlight
{
    public required Guid Id { get; init; }
    public required string Cfi { get; init; }
    /// <summary>The marked words, for the list.</summary>
    public required string Text { get; init; }
    public string? ChapterTitle { get; init; }
    /// <summary>How far into the book it is, 0 to 1, for keeping the list in reading order.</summary>
    public required double Fraction { get; init; }
    public required DateTimeOffset Created { get; init; }

    public static Highlight Create(string cfi, string text, double fraction, string? chapterTitle = null,
        DateTimeOffset? created = null) => new()
    {
        Id = Guid.NewGuid(),
        Cfi = cfi,
        Text = text,
        ChapterTitle = chapterTitle,
        Fraction = fraction,
        Created = created ?? DateTimeOffset.UtcNow,
    };
}

/// <summary>
/// The reader's own "I stopped here" (MarkerStore.swift): one page they chose to mark. <see cref="Cfi"/>
/// is a point at the start of the marked spread.
/// </summary>
public sealed record Marker
{
    public required string Cfi { get; init; }
    /// <summary>How far into the book it is, 0 to 1.</summary>
    public required double Fraction { get; init; }
    /// <summary>The page it was on when marked; a cache across platforms, as for a position.</summary>
    public required int Page { get; init; }
    public string? ChapterTitle { get; init; }
    public required DateTimeOffset Created { get; init; }

    /// <summary>In whole seconds, as the file keeps it, so a marker read back equals the one set.</summary>
    public static Marker Create(string cfi, double fraction, int page, string? chapterTitle = null,
        DateTimeOffset? created = null) => new()
    {
        Cfi = cfi,
        Fraction = fraction,
        Page = page,
        ChapterTitle = chapterTitle,
        Created = Iso8601SecondsConverter.Truncate(created ?? DateTimeOffset.UtcNow),
    };
}
