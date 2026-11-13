using System.Globalization;
using Readme.Core.Model;
using Readme.Core.Reader;
using Readme.Core.Zip;

namespace Readme.Core.Library;

/// <summary>
/// Which books on the shelf are picked out (ShelfSelection.swift). A plain click opens a book and
/// clears the selection; Ctrl-click picks one in or out, and Shift-click picks the run from the last
/// one picked, as in File Explorer.
/// </summary>
public sealed class ShelfSelection
{
    public enum Outcome { Open, Changed }

    readonly HashSet<string> _ids = [];
    string? _anchor;

    public IReadOnlySet<string> Ids => _ids;
    public event Action? Changed;

    /// <summary><paramref name="order"/> is the books as the shelf shows them, the current one first.</summary>
    public Outcome Click(string id, Modifiers modifiers, IReadOnlyList<string> order)
    {
        if (modifiers.HasFlag(Modifiers.Ctrl))
        {
            if (!_ids.Remove(id)) _ids.Add(id);
            _anchor = id;
            Changed?.Invoke();
            return Outcome.Changed;
        }
        if (modifiers.HasFlag(Modifiers.Shift))
        {
            var from = _anchor == null ? -1 : IndexOf(order, _anchor);
            var to = IndexOf(order, id);
            _ids.Clear();
            if (from < 0 || to < 0)
            {
                _ids.Add(id);
                _anchor = id;
            }
            else
            {
                for (var i = Math.Min(from, to); i <= Math.Max(from, to); i++) _ids.Add(order[i]);
            }
            Changed?.Invoke();
            return Outcome.Changed;
        }
        Clear();
        return Outcome.Open;
    }

    static int IndexOf(IReadOnlyList<string> order, string id)
    {
        for (var i = 0; i < order.Count; i++) if (order[i] == id) return i;
        return -1;
    }

    public void Clear()
    {
        var had = _ids.Count > 0;
        _ids.Clear();
        _anchor = null;
        if (had) Changed?.Invoke();
    }

    /// <summary>The books a right-click on <paramref name="id"/> acts on: the selection, in shelf order, if it's in it, else just it.</summary>
    public IReadOnlyList<string> Targets(string id, IReadOnlyList<string> order) =>
        _ids.Contains(id) ? order.Where(_ids.Contains).ToList() : [id];

    public string ExportTitle(string id) => _ids.Contains(id) && _ids.Count > 1 ? $"Export {_ids.Count} Books…" : "Export…";

    /// <summary>The pin item for <paramref name="count"/> books: it unpins when every one is pinned, and pins otherwise.</summary>
    public static string PinMenuTitle(int count, bool allPinned) => (allPinned, count > 1) switch
    {
        (true, true) => $"Unpin {count} Books",
        (true, false) => "Unpin",
        (false, true) => $"Pin {count} Books to Front",
        (false, false) => "Pin to Front",
    };
}

/// <summary>What the shelf says, in the Mac app's words (CurrentBookShelf.swift, ShelfDrops.swift).</summary>
public static class ShelfText
{
    /// <summary>"Chapter 1, Loomings · 23 min left", with whichever parts the book has; null if neither.</summary>
    public static string? ProgressLine(Book book)
    {
        var parts = new[]
        {
            string.IsNullOrEmpty(book.ChapterTitle) ? null : book.ChapterTitle,
            book.ChapterMinutesLeft is { } minutes ? TimeLeft(minutes) : null,
        }.OfType<string>().ToList();
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    public static string TimeLeft(double minutes)
    {
        var total = Math.Max(1, (int)Math.Ceiling(minutes));
        if (total < 60) return $"{total} min left";
        var (hours, rest) = Math.DivRem(total, 60);
        return rest == 0 ? $"{hours} hr left" : $"{hours} hr {rest} min left";
    }

    public static string Message(ImportError error) => error switch
    {
        ImportError.CopyProtected => "This book is copy-protected, so it can't be opened here.",
        ImportError.NotAnEpub => "This file isn't an EPUB book.",
        _ => "This book couldn't be read.",
    };

    /// <summary>One line for each kind of failure, in the order they first happened.</summary>
    public static IReadOnlyList<string> Messages(IEnumerable<ImportError> errors) => errors.Distinct().Select(Message).ToList();

    public static string Adding(int count) => count == 1 ? "Adding a book…" : $"Adding {count} books…";

    public static string NoMatch(string query) => $"No books match “{query.Trim()}”";

    /// <summary>The Narrator label of a book on the shelf.</summary>
    public static string Label(Book book) =>
        string.Join(", ", new[] { book.Title, book.Author, book.PinnedAt != null ? "pinned" : null }.OfType<string>());
}

/// <summary>
/// The typographic cover a book gets when it has none (GeneratedCover.swift), from its title and author.
/// The colours come from the book's id, so a book always has the same ones. The layout is pure: the
/// app passes in how wide a run of text is set at a size, in its own fonts.
/// </summary>
public static class GeneratedCover
{
    public readonly record struct Palette(Rgba Background, Rgba Ink);

    /// <summary>The twelve pairs of the library mockup.</summary>
    public static readonly IReadOnlyList<Palette> Palettes = new (int, int)[]
    {
        (0x22404F, 0xEDE3CF), (0xE6D9C2, 0x5A2F2A), (0x2A2A2E, 0xC9B98F), (0xA8482F, 0xF4E7D2),
        (0x4F5D3F, 0xEFE8D4), (0x5B1A1F, 0xEADAC2), (0xD9CFA8, 0x39452C), (0x3B3550, 0xE5DCCB),
        (0xC49A4A, 0x2C2316), (0x7A2E3A, 0xF1E4D3), (0x1F4A4A, 0xE6E0C8), (0xC7B5A8, 0x3E2C2A),
    }.Select(p => new Palette(Rgba.Hex(p.Item1), Rgba.Hex(p.Item2))).ToList();

    /// <summary>FNV-1a over the id's UTF-8, the same on every launch and on both platforms.</summary>
    public static Palette PaletteFor(string id)
    {
        var hash = 0xcbf29ce484222325UL;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(id)) hash = unchecked((hash ^ b) * 0x100000001b3UL);
        return Palettes[(int)(hash % (ulong)Palettes.Count)];
    }

    // Proportions of the cover's width, from the mockup.
    public const double Padding = 0.09;
    public const double TitleSize = 0.135;
    public const double AuthorSize = 0.095;
    public const double LineHeight = 1.08;
    const double SmallestTitle = 0.07;
    const double SmallestAuthor = 0.06;
    const double Gap = 0.05;

    public sealed record Lines(double Size, IReadOnlyList<string> Text)
    {
        public bool Equals(Lines? other) => other != null && Size == other.Size && Text.SequenceEqual(other.Text);
        public override int GetHashCode() => HashCode.Combine(Size, Text.Count);
    }

    public sealed record Layout(Lines Title, Lines? Author);

    /// <summary>Measures <c>text</c> set at <c>size</c>: its width.</summary>
    public delegate double Measure(string text, double size);

    /// <summary>The author is placed first, in at most two lines' worth of room, and the title takes what's left.</summary>
    public static Layout LayoutFor(string title, string? author, double width, Measure titleFont, Measure authorFont)
    {
        var inner = width * (1 - 2 * Padding);
        var height = width * 1.5 - 2 * width * Padding;
        author = string.IsNullOrWhiteSpace(author) ? null : author.Trim();
        var authorLines = author == null ? null
            : Fit(author, inner, width * 0.2, width * AuthorSize, width * SmallestAuthor, authorFont);
        var taken = authorLines == null ? 0 : authorLines.Text.Count * authorLines.Size * LineHeight + width * Gap;
        var name = string.IsNullOrWhiteSpace(title) ? "Untitled" : title.Trim();
        return new Layout(Fit(name, inner, height - taken, width * TitleSize, width * SmallestTitle, titleFont), authorLines);
    }

    /// <summary>
    /// Sets text as large as it will go, down to <paramref name="smallest"/>, wrapped at words. A word
    /// wider than the line makes that size fail. Only at the smallest size is a word broken, and only if
    /// it must; text that still won't fit ends in an ellipsis.
    /// </summary>
    public static Lines Fit(string text, double width, double height, double start, double smallest, Measure font)
    {
        bool Fits(List<string> lines, double size) => lines.Count * size * LineHeight <= height;
        var size = start;
        while (size > smallest)
        {
            var s = size;
            if (Wrap(text, width, false, t => font(t, s)) is { } lines && Fits(lines, size))
                return new Lines(size, Balanced(lines, text, width, t => font(t, s)));
            size *= 0.95;
        }
        size = smallest;
        var final = Wrap(text, width, true, t => font(t, smallest)) ?? [text];
        var room = Math.Max(1, (int)(height / (size * LineHeight)));
        if (final.Count > room)
        {
            final = final.Take(room).ToList();
            var last = final[room - 1];
            while (last.Length > 0 && font(last + "…", size) > width) last = last[..^ElementLength(last)];
            final[room - 1] = last.TrimEnd() + "…";
        }
        return new Lines(size, final);
    }

    /// <summary>The length of the last text element (a character as a reader sees it), so a surrogate pair is never split.</summary>
    static int ElementLength(string text)
    {
        var starts = StringInfo.ParseCombiningCharacters(text);
        return text.Length - starts[^1];
    }

    /// <summary>The same number of lines, as even as can be: the narrowest width that still wraps to that many.</summary>
    static List<string> Balanced(List<string> lines, string text, double width, Func<string, double> measure)
    {
        if (lines.Count <= 1) return lines;
        var (low, high) = (width / 2, width);
        var best = lines;
        for (var i = 0; i < 12; i++)
        {
            var middle = (low + high) / 2;
            if (Wrap(text, middle, false, measure) is { } narrower && narrower.Count == lines.Count)
            {
                best = narrower;
                high = middle;
            }
            else low = middle;
        }
        return best;
    }

    /// <summary>Greedy line breaking at spaces; null when a word is wider than a line and may not be broken.</summary>
    static List<string>? Wrap(string text, double width, bool breakingWords, Func<string, double> measure)
    {
        var lines = new List<string>();
        foreach (var paragraph in text.Split(['\n', '\r'], StringSplitOptions.RemoveEmptyEntries))
        {
            var current = "";
            var (words, joiner) = Words(paragraph);
            foreach (var word in words)
            {
                var candidate = current.Length == 0 ? word : current + joiner + word;
                if (measure(candidate) <= width)
                {
                    current = candidate;
                    continue;
                }
                if (current.Length > 0)
                {
                    lines.Add(current);
                    current = "";
                }
                if (measure(word) <= width) current = word;
                else if (breakingWords)
                {
                    var elements = StringInfo.GetTextElementEnumerator(word);
                    while (elements.MoveNext())
                    {
                        var character = (string)elements.Current;
                        var next = current + character;
                        if (measure(next) > width && current.Length > 0)
                        {
                            lines.Add(current);
                            current = character;
                        }
                        else current = next;
                    }
                }
                else return null;
            }
            if (current.Length > 0) lines.Add(current);
        }
        return lines.Count == 0 ? [""] : lines;
    }

    /// <summary>Words split at spaces; text with no spaces and some CJK in it splits between characters.</summary>
    static (List<string> Words, string Joiner) Words(string paragraph)
    {
        var spaced = paragraph.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (spaced.Count != 1 || !spaced[0].EnumerateRunes().Any(IsCjk)) return (spaced, " ");
        var characters = new List<string>();
        var elements = StringInfo.GetTextElementEnumerator(spaced[0]);
        while (elements.MoveNext()) characters.Add((string)elements.Current);
        return (characters, "");
    }

    static bool IsCjk(System.Text.Rune rune) => rune.Value is
        >= 0x3040 and <= 0x30FF or >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF
        or >= 0xAC00 and <= 0xD7AF or >= 0xF900 and <= 0xFAFF;
}
