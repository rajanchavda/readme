namespace Readme.Core.Reader;

/// <summary>
/// Follows a click near the book's outer edges (EdgeClick in DeskView.swift), to tell a plain click
/// there, which turns the page, from one that selects text: a drag, or the first click of a double or
/// triple click. The page keeps every click, so text near the edges can be selected too.
/// </summary>
public sealed class EdgeClick
{
    /// <summary>The share of the book's width on each side where a click turns the page.</summary>
    public const double EdgeShare = 0.2;
    /// <summary>How far the pointer may wander between pressing and letting go and still make a click.</summary>
    public const double Slop = 4;

    (TurnDirection Direction, double X, double Y)? _pressed;

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
    /// Only a plain first click counts: a later one is part of a double or triple click, and a modifier
    /// means something else, such as Shift extending a selection.
    /// </summary>
    public void Press(double x, double y, TurnDirection? direction, int clickCount, bool isPlain) =>
        _pressed = clickCount == 1 && isPlain && direction is { } d ? (d, x, y) : null;

    /// <summary>Pulling away from where it was pressed makes a selection, not a click.</summary>
    public void Drag(double x, double y)
    {
        if (_pressed is { } p && Distance(p.X, p.Y, x, y) > Slop) _pressed = null;
    }

    /// <summary>The turn a click asks for once it's let go, if it was a click near an edge.</summary>
    public TurnDirection? Release(double x, double y, int clickCount)
    {
        var pressed = _pressed;
        _pressed = null;
        if (pressed is not { } p || clickCount != 1 || Distance(p.X, p.Y, x, y) > Slop) return null;
        return p.Direction;
    }

    static double Distance(double ax, double ay, double bx, double by) => Math.Sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));
}
