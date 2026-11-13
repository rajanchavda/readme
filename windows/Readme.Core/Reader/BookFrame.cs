using Readme.Core.Layout;

namespace Readme.Core.Reader;

/// <summary>A rectangle in device-independent pixels, top-left origin.</summary>
public readonly record struct Box(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
}

/// <summary>
/// Where the book lies on the desk, and how it's laid out there (BookFrame.swift), as in
/// <c>docs/mockups/open-book-v2.html</c>: a margin of desk all round, two pages up to a width, and one
/// narrower page when two readable pages won't fit. The Mac measures from the bottom; the book is
/// centred vertically, so the numbers are the same from the top.
/// </summary>
public sealed record BookFrame
{
    public Box Frame { get; }
    public int Columns { get; }
    /// <summary>The width each column should have, for <c>applyStyles</c>.</summary>
    public double ColumnWidth { get; }
    /// <summary>The font size the text is set at, full screen's larger one included.</summary>
    public double FontSize { get; }

    /// <summary>Room for the page to overflow the book as it lifts towards the reader.</summary>
    public const double Margin = 34;
    /// <summary>Full screen's margin, as a share of the screen's width and height.</summary>
    public const double FullscreenMarginShare = 0.03;
    public const double SpreadWidth = 980;
    public const double FullscreenSpreadWidth = 1500;
    public const double PageWidth = 560;

    public BookFrame(double width, double height, ReaderSettings settings, bool fullscreen)
    {
        var scale = fullscreen ? ReadingCss.FullscreenScale : 1;
        FontSize = settings.FontSize * scale;
        ColumnWidth = SpreadLayout.ColumnWidth(FontSize, settings.Font, settings.LineWidth);
        var inset = fullscreen ? (width * FullscreenMarginShare, height * FullscreenMarginShare) : (Margin, Margin);
        var area = new Box(inset.Item1, inset.Item2, width - 2 * inset.Item1, height - 2 * inset.Item2);
        var available = Math.Max(0, Math.Floor(area.Width));

        // Wider than usual if the text is large enough to need it for two pages, so a big enough
        // window always shows two.
        var spread = Math.Min(available, Math.Max(
            fullscreen ? FullscreenSpreadWidth : SpreadWidth, WidthHolding(ColumnWidth, 2)));
        Columns = SpreadLayout.Columns(spread, FontSize, settings.LineWidth, area.Height, settings.Font);
        var bookWidth = Columns == 2
            ? spread
            : Math.Min(available, Math.Max(Round(PageWidth * scale), WidthHolding(ColumnWidth, 1)));
        Frame = new Box(
            Round(area.X + (area.Width - bookWidth) / 2), Round(area.Y),
            bookWidth, Math.Max(0, Math.Floor(area.Height)));
    }

    /// <summary>
    /// The narrowest book whose columns are each <paramref name="columnWidth"/> wide, rounded up a
    /// pixel so foliate's sums can't fall short of it.
    /// </summary>
    static double WidthHolding(double columnWidth, int columns) =>
        Math.Ceiling(columnWidth / SpreadLayout.AvailableColumnWidth(1, columns)) + 1;

    /// <summary>Swift's <c>rounded()</c>: halves away from zero.</summary>
    static double Round(double value) => Math.Round(value, MidpointRounding.AwayFromZero);
}
