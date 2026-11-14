namespace Readme.Core.Model;

/// <summary>
/// Where the reader is in a book (ReaderLocation.swift), as bridge.js reports it and the position
/// files keep it. <see cref="Cfi"/> and <see cref="Fraction"/> describe the start of the visible spread.
/// </summary>
public sealed record ReaderLocation
{
    public required string Cfi { get; init; }
    /// <summary>
    /// Progress at the start of the visible spread: 0 on the first page, and below 1 on the last
    /// spread, so use <see cref="IsAtEnd"/> to detect the end of the book.
    /// </summary>
    public required double Fraction { get; init; }
    public string? ChapterTitle { get; init; }
    public required double ChapterMinutesLeft { get; init; }
    public required bool IsAtStart { get; init; }
    public required bool IsAtEnd { get; init; }
    /// <summary>
    /// The page the spread starts on, from 1, and how many the book has: fixed runs of text from the
    /// engine's pagination. A cache across platforms, since WebKit and Chromium may differ; the CFI is
    /// what counts.
    /// </summary>
    public required int Page { get; init; }
    public required int PageCount { get; init; }
    /// <summary>Whether the spread holds the reading marker. Places saved before markers read as false.</summary>
    public bool IsMarked { get; init; }
}

/// <summary>One line of a book's table of contents. <see cref="Level"/> is 0 at the top.</summary>
public sealed record TocEntry
{
    public required string Title { get; init; }
    public required string Href { get; init; }
    public required int Level { get; init; }
    /// <summary>Roughly where the entry starts, or null for a link that leads nowhere in the book.</summary>
    public double? Fraction { get; init; }
}
