namespace Readme.Core.Layout;

/// <summary>
/// How the shelves are laid out (ShelfLayout.swift): how many books a row holds, and how many empty
/// shelves fill the window. Sizes are in device-independent pixels, as the Mac's are in points.
/// </summary>
public static class ShelfLayout
{
    /// <summary>A shelf's height, and its gap to the next, as in the mockup.</summary>
    public const double ShelfHeight = 210;
    public const double ShelfGap = 24;
    /// <summary>The top shelf, which holds the current book.</summary>
    public const double LedgeHeight = 262;

    /// <summary>Items in rows that fit <paramref name="width"/>, in order. A row holds at least one.</summary>
    public static IReadOnlyList<IReadOnlyList<T>> Rows<T>(IReadOnlyList<T> items, double width,
        double coverWidth = 112, double gap = 22, double inset = 54) =>
        items.Chunk(BooksPerRow(width, coverWidth, gap, inset)).Select(row => (IReadOnlyList<T>)row).ToList();

    public static int BooksPerRow(double width, double coverWidth = 112, double gap = 22, double inset = 54)
    {
        var usable = width - 2 * inset;
        var fits = Math.Floor((usable + gap) / (coverWidth + gap));
        return double.IsFinite(fits) ? (int)Math.Max(1, fits) : 1;
    }

    /// <summary>The shelves below the top one that fill a window this tall, and never fewer than one.</summary>
    public static int EmptyRowCount(double height)
    {
        var below = height - LedgeHeight - ShelfGap;
        if (!double.IsFinite(below)) return 1;
        return (int)Math.Max(1, Math.Ceiling(below / (ShelfHeight + ShelfGap)));
    }
}

/// <summary>
/// The faces a book can be set in. Windows has no New York, the Mac's system serif, so it offers the
/// bundled Fraunces in its place.
/// </summary>
public enum BookFont { EbGaramond, Literata, Fraunces }

/// <summary>How many characters a line holds, on average.</summary>
public enum LineWidth { Narrow, Regular, Wide }

/// <summary>
/// How wide the page's columns are and how many fit (SpreadLayout.swift). The bridge lays columns out
/// at the width asked for and shares what's left of the page out as equal margins. Two pages are shown
/// only where foliate's own layout would have fitted them.
/// </summary>
public static class SpreadLayout
{
    /// <summary>foliate's own #container, the view less a 3.5% gutter on each side.</summary>
    public const double ContainerShare = 0.93;
    /// <summary>foliate's own column gap, as a share of the view.</summary>
    public const double GapShare = 0.07;

    public static double Characters(LineWidth width) => width switch
    {
        LineWidth.Narrow => 45,
        LineWidth.Regular => 52,
        LineWidth.Wide => 60,
        _ => throw new ArgumentOutOfRangeException(nameof(width)),
    };

    /// <summary>
    /// Width a character takes in a rendered line, as a share of the font size. The Mac's values were
    /// calibrated in WebKit, and hold in Chromium: measured as the Mac's LineLengthTests do (a 1600 by
    /// 900 view), Regular gives 51.3, 50.9 and 50.8 characters a line for EB Garamond, Literata and
    /// Fraunces, inside the Mac's 50 to 55 (Readme.exe --checks &lt;dir&gt; calibrate, Nov 13, 2026).
    /// </summary>
    public static double CharacterWidth(BookFont font) => font switch
    {
        BookFont.EbGaramond => 0.365,
        BookFont.Literata => 0.458,
        BookFont.Fraunces => 0.448,
        _ => throw new ArgumentOutOfRangeException(nameof(font)),
    };

    /// <summary>The width a column should have for the line width's characters at this size.</summary>
    public static double ColumnWidth(double fontSize, BookFont font, LineWidth lineWidth) =>
        Characters(lineWidth) * CharacterWidth(font) * fontSize;

    /// <summary>The width of a column when <paramref name="columns"/> share a view this wide.</summary>
    public static double AvailableColumnWidth(double windowWidth, int columns)
    {
        var container = windowWidth * ContainerShare;
        var gap = container * GapShare / ContainerShare;
        return container / columns - gap;
    }

    /// <summary>
    /// One or two pages across: two only if each column could hold a full line at this size, and never
    /// when the book area is taller than wide. A <paramref name="windowHeight"/> of 0 means unknown.
    /// </summary>
    public static int Columns(double windowWidth, double fontSize, LineWidth lineWidth, double windowHeight = 0,
        BookFont font = BookFont.EbGaramond)
    {
        if (windowHeight > windowWidth) return 1;
        var wanted = ColumnWidth(fontSize, font, lineWidth);
        return AvailableColumnWidth(windowWidth, 2) >= wanted ? 2 : 1;
    }
}
