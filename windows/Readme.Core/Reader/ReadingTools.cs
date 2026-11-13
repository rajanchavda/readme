using System.Globalization;
using System.Text.RegularExpressions;
using Readme.Core.Model;

namespace Readme.Core.Reader;

/// <summary>
/// Whether the reader has moved the mouse lately, which is when the toolbar shows (IdleTimer.swift).
/// Times are in seconds, from any one clock.
/// </summary>
public sealed class IdleTimer
{
    public double Delay { get; init; } = 1.6;
    double? _lastActivity;

    public void Activity(double time) => _lastActivity = time;

    /// <summary>Asleep at once, as when the mouse leaves the window.</summary>
    public void Sleep() => _lastActivity = null;

    /// <summary>Not <c>time - last</c>, which can fall a rounding error short of the delay when it's up.</summary>
    public bool IsAwake(double time) => _lastActivity is { } last && time < last + Delay;
}

/// <summary>How far the reader has got with one entry of the contents.</summary>
public enum TocState { Read, Current, Unread }

/// <summary>Which entries of the contents are read, being read, and ahead (TOCProgress.swift).</summary>
public static class TocProgress
{
    /// <summary>A spread that starts where a chapter does can be reported a hair before it.</summary>
    const double Tolerance = 1e-9;

    /// <summary>
    /// <paramref name="fraction"/> is where the visible spread starts. The current entry is the last
    /// one, in the contents' order, that starts there or before. Before the first entry nothing is
    /// current. An entry with no place in the book is never current.
    /// </summary>
    public static TocState[] States(IReadOnlyList<TocEntry> entries, double fraction)
    {
        var current = -1;
        for (var i = 0; i < entries.Count; i++)
            if (entries[i].Fraction is { } start && start <= fraction + Tolerance) current = i;
        if (current < 0) return entries.Select(_ => TocState.Unread).ToArray();
        return Enumerable.Range(0, entries.Count)
            .Select(i => i < current ? TocState.Read : i == current ? TocState.Current : TocState.Unread).ToArray();
    }
}

/// <summary>
/// One place the searched words were found (Search.swift): where, the words around it, and the page
/// and chapter it's in. <see cref="Page"/> is the match's own page.
/// </summary>
public sealed record SearchMatch
{
    public required string Cfi { get; init; }
    public required string Pre { get; init; }
    public required string Match { get; init; }
    public required string Post { get; init; }
    public required int Page { get; init; }
    public string? Chapter { get; init; }
}

/// <summary>What a search found, in book order. <see cref="IsCapped"/>: it stopped at the limit with more to find.</summary>
public sealed record SearchOutcome(IReadOnlyList<SearchMatch> Matches, bool IsCapped);

/// <summary>What the search box says about a search.</summary>
public static class SearchResults
{
    /// <summary>Fewer characters than this search nothing, as one letter is on nearly every page.</summary>
    public const int MinimumLength = 2;
    /// <summary>The most matches listed. Past this, the reader types more to narrow it down.</summary>
    public const int Limit = 500;

    public static bool IsSearchable(string query) => query.Trim().Length >= MinimumLength;

    public static string CountText(SearchOutcome outcome, CultureInfo? culture = null)
    {
        culture ??= CultureInfo.CurrentCulture;
        var count = outcome.Matches.Count;
        if (outcome.IsCapped) return $"{count.ToString("N0", culture)}+ matches, type more to narrow it down";
        return count switch
        {
            0 => "No matches",
            1 => "1 match",
            _ => $"{count.ToString("N0", culture)} matches",
        };
    }

    /// <summary>The page and chapter, as a row shows them beside the match.</summary>
    public static string Detail(SearchMatch match)
    {
        var chapter = match.Chapter?.Trim();
        return string.IsNullOrEmpty(chapter) ? match.Page.ToString(CultureInfo.InvariantCulture) : $"{match.Page} · {chapter}";
    }

    /// <summary>The most of what comes before a match that a row shows, so the match stays in view.</summary>
    public const int PreLength = 32;

    /// <summary>What a row shows before the match: the end of it, from a word's start, after an ellipsis.</summary>
    public static string ShortPre(string pre)
    {
        if (pre.Length <= PreLength) return pre;
        var tail = pre[^PreLength..];
        var space = tail.IndexOf(' ');
        return "…" + (space < 0 ? "" : tail[space..]);
    }
}

/// <summary>What a page number typed into the go-to-page field means (GoToPage in GoToPageField.swift).</summary>
public static partial class GoToPage
{
    [GeneratedRegex("^-?[0-9]+$")]
    private static partial Regex WholeNumber();

    /// <summary>The typed page. A number outside the book means the nearest page in it; null if it isn't a whole number.</summary>
    public static int? Page(string typed, int pageCount)
    {
        var text = typed.Trim();
        if (pageCount <= 0 || !WholeNumber().IsMatch(text)) return null;
        // Too long for an int is still a number, past one end or the other.
        var number = int.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n)
            ? n : text.StartsWith('-') ? 1 : pageCount;
        return Math.Clamp(number, 1, pageCount);
    }

    /// <summary>Where the typed page begins, as a fraction of the book.</summary>
    public static double? Fraction(string typed, int pageCount) =>
        Page(typed, pageCount) is { } page ? (double)(page - 1) / pageCount : null;

    /// <summary>What the empty field shows, such as "214 of 1,240".</summary>
    public static string Placeholder(int page, int pageCount, CultureInfo? culture = null)
    {
        culture ??= CultureInfo.CurrentCulture;
        return $"{page.ToString("N0", culture)} of {pageCount.ToString("N0", culture)}";
    }
}

/// <summary>How much of the chapter is left, as the toolbar says it (TimeLeft in ReaderToolbar.swift).</summary>
public static class ChapterTimeLeft
{
    public static string Text(double minutes)
    {
        if (minutes < 1) return "Under a minute left in chapter";
        var whole = (int)Math.Round(minutes, MidpointRounding.AwayFromZero);
        if (whole < 60) return $"{whole} min left in chapter";
        var (hours, rest) = Math.DivRem(whole, 60);
        return rest == 0 ? $"{hours} hr left in chapter" : $"{hours} hr {rest} min left in chapter";
    }
}

/// <summary>
/// What the shortcuts panel lists (ShortcutsHelp.swift), with Windows' key names: every reader command
/// and the keys that aren't commands, in groups, each with its keys and a few words.
/// </summary>
public static class ShortcutsHelp
{
    public sealed record Row(string[] Keys, string Description)
    {
        public bool Equals(Row? other) => other is not null && Description == other.Description && Keys.SequenceEqual(other.Keys);
        public override int GetHashCode() => HashCode.Combine(Description, string.Join("|", Keys));
    }

    public sealed record Section(string Title, Row[] Rows);

    /// <summary>The panel's two columns, left then right.</summary>
    public static readonly Section[][] Columns =
    [
        [
            new("Reading", [
                new(["Right", "Space"], "Next page"),
                new(["Left"], "Previous page"),
                RowFor(ReaderCommand.BiggerText),
                RowFor(ReaderCommand.SmallerText),
            ]),
            new("Moving Around", [
                RowFor(ReaderCommand.GoToStart),
                RowFor(ReaderCommand.GoToEnd),
                RowFor(ReaderCommand.GoToPage),
                RowFor(ReaderCommand.Find),
                RowFor(ReaderCommand.ToggleMarker),
                RowFor(ReaderCommand.GoToMarker),
            ]),
        ],
        [
            new("Panels", [
                RowFor(ReaderCommand.ToggleToc),
                RowFor(ReaderCommand.ToggleHighlights),
                RowFor(ReaderCommand.ShowLibrary),
                new(["Ctrl+O"], "Open a book"),
            ]),
            new("Window", [
                RowFor(ReaderCommand.ToggleFullscreen),
                new(["Esc"], "Close a panel or leave full screen"),
                RowFor(ReaderCommand.ShowShortcuts),
            ]),
            // On the shelf, where the reader's commands are put away.
            new("Library", [
                new(["Ctrl+F"], "Search the library"),
                new(["Esc"], "Clear the search"),
            ]),
        ],
    ];

    public static IEnumerable<Section> Sections => Columns.SelectMany(c => c);

    /// <summary>A command's row: its shortcut, then any plain key that stands in for it.</summary>
    public static Row RowFor(ReaderCommand command) =>
        new([command.Shortcut().Label, .. PlainKeys(command)], Description(command));

    public static string Description(ReaderCommand command) => command switch
    {
        ReaderCommand.BiggerText => "Bigger text",
        ReaderCommand.SmallerText => "Smaller text",
        ReaderCommand.ToggleToc => "Show or hide the contents",
        ReaderCommand.ToggleHighlights => "Show or hide your highlights",
        ReaderCommand.ToggleMarker => "Mark or unmark this page",
        ReaderCommand.ToggleFullscreen => "Full screen",
        ReaderCommand.ShowLibrary => "Show the library",
        ReaderCommand.GoToStart => "Go to the start",
        ReaderCommand.GoToEnd => "Go to the end",
        ReaderCommand.GoToPage => "Go to a page number",
        ReaderCommand.GoToMarker => "Go to the marked page",
        ReaderCommand.Find => "Find in the book",
        ReaderCommand.ShowShortcuts => "Show these shortcuts",
        _ => throw new ArgumentOutOfRangeException(nameof(command)),
    };

    /// <summary>The keys without modifiers that <see cref="ReaderCommands.FromKey"/> takes for the command.</summary>
    public static string[] PlainKeys(ReaderCommand command) => command switch
    {
        ReaderCommand.GoToStart => ["Home"],
        ReaderCommand.GoToEnd => ["End"],
        ReaderCommand.ToggleFullscreen => ["F"],
        ReaderCommand.ShowShortcuts => ["?"],
        _ => [],
    };
}

/// <summary>The reading tools' colours (from ReaderWindowController.swift and ReaderToolbar.swift).</summary>
public static class ToolColors
{
    /// <summary>A warm yellow, deeper on the night page; yellow vanishes into sepia, so that one's a soft blue.</summary>
    public static string Highlight(Theme theme) => theme switch
    {
        Theme.Sepia => "#4f9fd0",
        Theme.Night => "#d9a63a",
        _ => "#f2c744",
    };

    /// <summary>A picked search match's glow, which no highlight has, so it's never taken for one.</summary>
    public static string Glow(Theme theme) => theme switch
    {
        Theme.Sepia => "#e0703c",
        Theme.Night => "#5aa9e6",
        _ => "#3d8fd1",
    };

    static byte Channel(double share) => (byte)Math.Round(share * 255);

    /// <summary>The reading marker's ribbon: a muted red, softer on the night page.</summary>
    public static Rgba Ribbon(Theme theme) => theme switch
    {
        Theme.Sepia => new(Channel(0.62), Channel(0.24), Channel(0.18)),
        Theme.Night => new(Channel(0.62), Channel(0.34), Channel(0.32)),
        _ => new(Channel(0.69), Channel(0.23), Channel(0.20)),
    };

    /// <summary>The toolbar's ground, and the fields' and panels' that share its look.</summary>
    public static Rgba Chrome(Theme theme) => theme == Theme.Night ? new(70, 70, 74, 0.72) : new(40, 34, 28, 0.72);

    public static Rgba ChromeInk(Theme theme) => theme == Theme.Night ? Rgba.Hex(0xE6E3DB) : Rgba.Hex(0xF5EFE2);
}

/// <summary>Where the floating pieces go (HighlightBar.frame and MarkerRibbon.frame), from the top left.</summary>
public static class ToolPlacement
{
    public const double BarWidth = 104, BarHeight = 30, BarGap = 8;
    public const double RibbonWidth = 14, RibbonHeight = 36, RibbonInset = 34, RibbonNotch = 6;

    /// <summary>The highlight bar for words at <paramref name="target"/>: centred above them, or below if there's no room, kept inside.</summary>
    public static Box HighlightBar(Box target, Box bounds)
    {
        const double inset = 8;
        var x = target.X + target.Width / 2 - BarWidth / 2;
        x = Math.Min(Math.Max(x, bounds.X + inset), bounds.Right - BarWidth - inset);
        var y = target.Y - BarGap - BarHeight;
        if (y < bounds.Y + inset) y = target.Bottom + BarGap;
        y = Math.Min(Math.Max(y, bounds.Y + inset), bounds.Bottom - BarHeight - inset);
        return new Box(x, y, BarWidth, BarHeight);
    }

    /// <summary>The ribbon hangs from the top of the right-hand page, or the one page, <see cref="RibbonInset"/> in from its outer edge.</summary>
    public static Box Ribbon(Box book) =>
        new(Math.Round(book.Right - RibbonInset - RibbonWidth), Math.Round(book.Y), RibbonWidth, RibbonHeight);
}
