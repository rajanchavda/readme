namespace Readme.Core.Reader;

/// <summary>
/// Where the reading window goes back to once its layout has changed (PlaceKeeper.swift): the start of
/// the spread it was on before the change began. A page turned since then is where the reader wants to
/// be, so a capture older than the last turn sends them nowhere.
///
/// A resize or a full-screen change is one change from start to end, however many restyles it takes,
/// so its place is kept until it ends and then let go, used or not. The place is where the reader is,
/// which only a turn, a jump or opening the book moves; a layout change shows it on whichever page now
/// holds it, so it stays as it was rather than creeping back a page each time.
/// </summary>
public sealed class PlaceKeeper
{
    public readonly record struct Capture(string Cfi, int Turns);

    public int Turns { get; private set; }
    /// <summary>The start of the spread the reader last turned or jumped to, or opened the book at.</summary>
    public string? Place { get; private set; }
    public Capture? LayoutChangeCapture { get; private set; }
    public bool IsChangingLayout { get; private set; }

    public void Turned() => Turns++;

    public void MovedTo(string? cfi) => Place = cfi;

    /// <summary>Where the reader is, or what's shown if that isn't known yet.</summary>
    public string? PlaceShowing(string? shown) => Place ?? shown;

    public Capture? Take(string? cfi) => cfi == null ? null : new Capture(cfi, Turns);

    /// <summary>The place to go back to, unless a page has turned since the capture.</summary>
    public string? Target(Capture? capture) => capture is { } c && c.Turns == Turns ? c.Cfi : null;

    /// <summary>True if a page has turned since the capture. With nothing captured, nothing is known to have.</summary>
    public bool HasTurnedSince(Capture? capture) => capture is { } c && c.Turns != Turns;

    public void BeginLayoutChange(string? cfi)
    {
        if (IsChangingLayout) return;
        IsChangingLayout = true;
        LayoutChangeCapture = Take(cfi);
    }

    public Capture? EndLayoutChange()
    {
        var capture = LayoutChangeCapture;
        IsChangingLayout = false;
        LayoutChangeCapture = null;
        return capture;
    }
}
