namespace Readme.Core.Reader;

/// <summary>What's under a click near the book's outer edges, which says whether it turns the page (EdgeSpot in DeskView.swift).</summary>
public enum EdgeSpot
{
    /// <summary>Nothing to select, such as a margin or the gap between lines.</summary>
    Blank,
    /// <summary>Text, which a double or triple click would select.</summary>
    Text,
    /// <summary>A link, which the page follows, or a highlight, which it shows. The page has the click, as it has any click while text is selected, which only puts the selection away.</summary>
    Own,
}

/// <summary>What a click near an edge does with the page.</summary>
public enum EdgeTurn
{
    None,
    Now,
    /// <summary>Once the double-click time has passed with no other press, in case it's the start of one.</summary>
    AfterDoubleClick,
}

/// <summary>
/// Follows a click near the book's outer edges (EdgeClick in DeskView.swift), to tell a plain click
/// there, which turns the page, from one that selects text: a drag, or a double or triple click on
/// text. The page keeps every click, so text near the edges can be selected too.
/// </summary>
public sealed class EdgeClick
{
    /// <summary>The share of the book's width on each side where a click turns the page.</summary>
    public const double EdgeShare = 0.2;
    /// <summary>How far the pointer may wander between pressing and letting go and still make a click.</summary>
    public const double Slop = 4;

    (TurnDirection Direction, double X, double Y, int ClickCount, EdgeSpot Spot)? _pressed;
    /// <summary>Whether a click of the run under way has turned the page, which makes its later clicks turns.</summary>
    bool _runHasTurned;

    /// <summary>Which way a click at `x`, `y` in a book `width` by `height` turns the page, if it does.</summary>
    public static TurnDirection? TurnAt(double x, double y, double width, double height)
    {
        if (x < 0 || y < 0 || x > width || y > height) return null;
        var band = width * EdgeShare;
        if (x < band) return TurnDirection.Backward;
        if (x > width - band) return TurnDirection.Forward;
        return null;
    }

    /// <summary>
    /// Over text, a single click waits to see it isn't a double one, and a double or triple click
    /// selects. Elsewhere every click of a run turns, so quick clicks flip quickly, and once a run has
    /// turned the page its later clicks are more turns, wherever they land on the new page.
    /// </summary>
    public static EdgeTurn TurnFor(EdgeSpot spot, int clickCount, bool runHasTurned = false) => spot switch
    {
        EdgeSpot.Own => EdgeTurn.None,
        EdgeSpot.Blank => EdgeTurn.Now,
        _ when clickCount > 1 && runHasTurned => EdgeTurn.Now,
        _ => clickCount == 1 ? EdgeTurn.AfterDoubleClick : EdgeTurn.None,
    };

    /// <summary>
    /// `spot` is what's under the press, found as the button went down, before a link could change the
    /// page. A modifier means something other than a turn, such as Shift extending a selection.
    /// </summary>
    public void Press(double x, double y, TurnDirection? direction, int clickCount, bool isPlain, EdgeSpot spot)
    {
        _pressed = isPlain && direction is { } d ? (d, x, y, clickCount, spot) : null;
        if (clickCount <= 1 || _pressed == null) _runHasTurned = false;
    }

    /// <summary>Pulling away from where it was pressed makes a selection, not a click.</summary>
    public void Drag(double x, double y)
    {
        if (_pressed is { } p && Distance(p.X, p.Y, x, y) > Slop) _pressed = null;
    }

    /// <summary>The turn a click asks for once it's let go, if it was a click near an edge that turns.</summary>
    public (TurnDirection Direction, EdgeTurn Turn)? Release(double x, double y)
    {
        var pressed = _pressed;
        _pressed = null;
        if (pressed is not { } p || Distance(p.X, p.Y, x, y) > Slop) return null;
        var turn = TurnFor(p.Spot, p.ClickCount, _runHasTurned);
        if (turn == EdgeTurn.Now) _runHasTurned = true;
        return turn == EdgeTurn.None ? null : (p.Direction, turn);
    }

    static double Distance(double ax, double ay, double bx, double by) => Math.Sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));
}
