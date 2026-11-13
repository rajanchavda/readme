using Readme.Core.Model;
using Readme.Core.Reader;

namespace Readme.Core.Curl;

public enum SpreadSlot
{
    Current, Next, Previous,
    /// <summary>The spreads one further on, which become Next and Previous as soon as a turn lands.</summary>
    AfterNext, BeforePrevious,
}

/// <summary>Everything about the visible view that changes how a spread looks.</summary>
public sealed record SpreadLayout(string? Book, double Width, double Height, double Scale, string Css, int Columns,
    double? ColumnWidth, string Highlights, string HighlightColor);

/// <summary>A book view the cache reads: the visible one, or the one nobody sees that renders spreads.</summary>
public interface ISpreadView<TImage> where TImage : class
{
    ReaderLocation? CurrentLocation { get; }
    bool IsOpen { get; }
    Task<ReaderLocation?> NextAsync();
    Task<ReaderLocation?> PreviousAsync();
    Task<ReaderLocation?> GoToCfiAsync(string cfi);
    /// <summary>Returns once the page has stopped changing.</summary>
    Task SettleAsync();
    /// <summary>A picture of what it shows now, at full resolution, or null if one can't be had.</summary>
    Task<TImage?> SnapshotAsync();
}

public interface IVisibleSpreadView<TImage> : ISpreadView<TImage> where TImage : class
{
    /// <summary>Every settled place the view reports, whatever moved it.</summary>
    event Action<ReaderLocation>? Relocated;
    SpreadLayout Layout { get; }
}

public interface IOffscreenSpreadView<TImage> : ISpreadView<TImage> where TImage : class
{
    /// <summary>Lays itself out as <paramref name="layout"/> and opens its book at <paramref name="at"/> if it hasn't.</summary>
    Task<bool> PrepareAsync(SpreadLayout layout, ReaderLocation at);
}

/// <summary>
/// Keeps pictures of the spreads around the visible one, for the page curl to animate
/// (SpreadCache.swift). There are two in each direction. A landing promotes the further one at once
/// and the buffer refills behind it, so a reader turning pages quickly has the next curl ready. A view
/// nobody sees renders them, at the visible view's size, scale, styles and highlights, so a preview is
/// what the reader lands on.
///
/// A slot is null until its image is ready, and always null past the ends of the book. Every image
/// belongs to the place last refreshed or committed to, and to that layout. The cache hears the visible
/// view move anywhere else, such as through a link, and renders again around where it went.
/// Single-threaded: call it on one thread, as the app's UI thread.
/// </summary>
public sealed class SpreadCache<TImage> where TImage : class
{
    sealed record Spread(TImage Image, ReaderLocation Location);

    /// <summary>How many spreads are kept in each direction.</summary>
    public const int Depth = 2;
    /// <summary>Longer than the gap between held-key turns, so a burst of them does no rendering.</summary>
    static readonly TimeSpan QuietPeriod = TimeSpan.FromMilliseconds(150);

    readonly IVisibleSpreadView<TImage> _visible;
    readonly IOffscreenSpreadView<TImage> _offscreen;

    ReaderLocation? _anchor;
    SpreadLayout? _layout;
    Spread? _current;
    /// <summary>Each runs outward from the current spread, nearest first, with no gaps.</summary>
    List<Spread> _ahead = [];
    List<Spread> _behind = [];
    /// <summary>Changes whenever the slots are emptied, so work begun before that can't add to them.</summary>
    int _generation;
    TurnDirection _lastDirection = TurnDirection.Forward;

    /// <summary>The rendering in progress. Only one runs at a time, as they share the offscreen view.</summary>
    Task? _rendering;
    CancellationTokenSource? _renderStop;
    bool _isRendering;
    int _renderNumber;
    int _turnsInFlight;
    int _turnsSettling;
    int _turnsStarted;

    /// <summary>Raised once the cache has heard the visible view go somewhere it didn't take it, and emptied the slots.</summary>
    public event Action? UnforeseenMove;

    public SpreadCache(IVisibleSpreadView<TImage> visible, IOffscreenSpreadView<TImage> offscreen)
    {
        _visible = visible;
        _offscreen = offscreen;
        _visible.Relocated += VisibleMoved;
    }

    public TImage? Image(SpreadSlot slot) => slot switch
    {
        SpreadSlot.Current => _current?.Image,
        SpreadSlot.Next => _ahead.FirstOrDefault()?.Image,
        SpreadSlot.Previous => _behind.FirstOrDefault()?.Image,
        SpreadSlot.AfterNext => _ahead.Skip(1).FirstOrDefault()?.Image,
        _ => _behind.Skip(1).FirstOrDefault()?.Image,
    };

    /// <summary>How many spreads are ready, the current one included.</summary>
    public int Count => (_current != null ? 1 : 0) + _ahead.Count + _behind.Count;

    /// <summary>True if the current image shows <paramref name="location"/> as the visible view lays it out now.</summary>
    public bool ImagesBelong(ReaderLocation location) => _current?.Location.Cfi == location.Cfi && _visible.Layout == _layout;

    /// <summary>
    /// Makes the slots right for <paramref name="location"/>, where the visible view must be. Only what's
    /// missing is rendered. Returns when the nearest spreads are done, or a newer refresh replaces this.
    /// Call it after opening or restyling the visible view.
    /// </summary>
    public async Task RefreshAsync(ReaderLocation location)
    {
        Adopt(location);
        await StartRendering(null);
    }

    /// <summary>A turn that way is waiting for its images, so the spreads that way are rendered first.</summary>
    public void Prefer(TurnDirection direction)
    {
        if (_lastDirection == direction) return;
        _lastDirection = direction;
        var isMissing = (direction == TurnDirection.Forward ? _ahead : _behind).Count == 0;
        if (!isMissing || !_isRendering || _anchor == null) return;
        StartRendering(null);
    }

    /// <summary>Returns when the work in progress is done, so the slots are as full as they'll get here.</summary>
    public async Task NeighboursReadyAsync()
    {
        while (_rendering is { } task)
        {
            try { await task; } catch (OperationCanceledException) { }
            if (task == _rendering) return;
        }
    }

    /// <summary>Forgets every image, as when the book closes.</summary>
    public void Clear()
    {
        StopRendering();
        Empty();
        _anchor = null;
        _layout = null;
    }

    /// <summary>
    /// Turns the visible view and moves the images along. <paramref name="onLanded"/> is called as soon
    /// as the page has moved and the slots are right for where it went. Returns once the page has
    /// settled. Turns run in the order called.
    /// </summary>
    public async Task CommitAsync(TurnDirection direction, Action? onLanded = null)
    {
        _turnsInFlight++;
        _turnsStarted++;
        _lastDirection = direction;
        var landed = await (direction == TurnDirection.Forward ? _visible.NextAsync() : _visible.PreviousAsync());
        _turnsInFlight--;
        var foreseen = false;
        if (landed != null)
        {
            foreseen = Rotate(direction, landed);
            if (!foreseen) StopRendering();
        }
        onLanded?.Invoke();
        // Held keys skip this: a turn already behind it would make the work pointless.
        if (_turnsInFlight != 0) return;
        if (foreseen && !_isRendering) _ = StartRendering(null);

        var turn = _turnsStarted;
        _turnsSettling++;
        await _visible.SettleAsync();
        _turnsSettling--;
        // The view only takes a reply's location if no relocation overtook it, so this is the latest.
        if (turn != _turnsStarted || _visible.CurrentLocation is not { } settled) return;
        var changed = Adopt(settled);
        if (_current == null)
        {
            var image = await _visible.SnapshotAsync();
            // A jump while it was taken has adopted its own place, and the image could show either.
            if (turn != _turnsStarted || _anchor?.Cfi != settled.Cfi || _visible.CurrentLocation?.Cfi != settled.Cfi) return;
            if (image != null) _current = new Spread(image, settled);
        }
        if (changed || !_isRendering) _ = StartRendering(foreseen ? null : QuietPeriod);
    }

    /// <summary>
    /// An image only moves into the current slot if it's known to show where the turn landed. A turn
    /// that wasn't foreseen, such as one that outran the buffer, leaves the slots empty for the next
    /// render instead. Returns whether it was foreseen.
    /// </summary>
    bool Rotate(TurnDirection direction, ReaderLocation landed)
    {
        var leaving = _current;
        var forward = direction == TurnDirection.Forward;
        var arriving = (forward ? _ahead : _behind).FirstOrDefault();
        _anchor = landed;
        if (arriving == null || arriving.Location.Cfi != landed.Cfi)
        {
            Empty();
            return false;
        }
        _current = new Spread(arriving.Image, landed);
        var behindIt = (forward ? _behind : _ahead).ToList();
        // Without the page it left, what's beyond that wouldn't join on.
        if (leaving != null)
        {
            behindIt.Insert(0, leaving);
            behindIt = behindIt.Take(Depth).ToList();
        }
        else behindIt = [];
        var inFront = (forward ? _ahead : _behind).Skip(1).ToList();
        _ahead = forward ? inFront : behindIt;
        _behind = forward ? behindIt : inFront;
        return true;
    }

    /// <summary>
    /// Every move of the visible view arrives here, including its own turns and their settling, which
    /// CommitAsync looks after, and the same place reported again, which needs nothing.
    /// </summary>
    void VisibleMoved(ReaderLocation location)
    {
        if (_turnsInFlight != 0 || _turnsSettling != 0 || !_visible.IsOpen || _anchor == null || location.Cfi == _anchor.Cfi) return;
        Adopt(location);
        StartRendering(null);
        UnforeseenMove?.Invoke();
    }

    void Empty()
    {
        _current = null;
        _ahead = [];
        _behind = [];
        _generation++;
    }

    /// <summary>
    /// Makes <paramref name="location"/> and the visible view's layout the ones the slots belong to,
    /// emptying them if they were for something else, so a stale image is never on offer.
    /// </summary>
    bool Adopt(ReaderLocation location)
    {
        var wanted = _visible.Layout;
        var changed = location.Cfi != _anchor?.Cfi || wanted != _layout;
        if (changed) Empty();
        _anchor = location;
        _layout = wanted;
        return changed;
    }

    void StopRendering()
    {
        _renderStop?.Cancel();
        _isRendering = false;
        _renderNumber++;
    }

    /// <summary>The nearest spreads first, which the returned task waits for, then the rest.</summary>
    Task StartRendering(TimeSpan? delay)
    {
        var earlier = _rendering;
        StopRendering();
        _isRendering = true;
        var number = _renderNumber;
        var stop = new CancellationTokenSource();
        _renderStop = stop;
        var token = stop.Token;
        var nearest = Run();
        _rendering = nearest;
        return nearest;

        async Task Run()
        {
            // Never finishes before it's stored.
            await Task.Yield();
            if (earlier != null) try { await earlier; } catch (OperationCanceledException) { }
            if (delay is { } wait) try { await Task.Delay(wait, token); } catch (OperationCanceledException) { return; }
            if (token.IsCancellationRequested) return;
            await FillAsync(1, token);
            if (token.IsCancellationRequested) return;
            _rendering = Further();
        }

        async Task Further()
        {
            await Task.Yield();
            await FillAsync(Depth, token);
            if (number == _renderNumber) _isRendering = false;
        }
    }

    /// <summary>
    /// Renders what's missing until each direction has <paramref name="depth"/> spreads, the way the
    /// reader is going first. Reads the slots afresh at each step, and a stopped or outdated render
    /// stores nothing, so a slot can't pick up an image from a place the reader has left.
    /// </summary>
    async Task FillAsync(int depth, CancellationToken token)
    {
        var triedCurrent = false;
        var prepared = false;
        var blocked = new List<TurnDirection>();
        while (!token.IsCancellationRequested)
        {
            var started = _generation;
            if (_current == null && !triedCurrent && _turnsInFlight == 0 && _anchor is { } here)
            {
                triedCurrent = true;
                await _visible.SettleAsync();
                if (token.IsCancellationRequested || started != _generation) return;
                if (_visible.CurrentLocation?.Cfi == here.Cfi && await _visible.SnapshotAsync() is { } image)
                {
                    if (token.IsCancellationRequested || started != _generation) return;
                    if (_current == null && _anchor?.Cfi == here.Cfi) _current = new Spread(image, here);
                }
            }
            if (Wanted(depth, blocked) is not { } direction || _layout is not { } layout || Frontier(direction) is not { } from) return;
            if (!prepared)
            {
                prepared = true;
                if (!await _offscreen.PrepareAsync(layout, from) || started != _generation || token.IsCancellationRequested) return;
            }
            var spread = await NeighbourAsync(from, direction, token);
            if (token.IsCancellationRequested || started != _generation) return;
            if (spread == null)
            {
                blocked.Add(direction);
                continue;
            }
            Store(spread, from, direction);
        }
    }

    TurnDirection? Wanted(int depth, List<TurnDirection> blocked)
    {
        TurnDirection[] order = _lastDirection == TurnDirection.Forward
            ? [TurnDirection.Forward, TurnDirection.Backward] : [TurnDirection.Backward, TurnDirection.Forward];
        foreach (var direction in order)
        {
            if (blocked.Contains(direction) || Frontier(direction) is not { } edge) continue;
            var count = direction == TurnDirection.Forward ? _ahead.Count : _behind.Count;
            if (count < depth && !(direction == TurnDirection.Forward ? edge.IsAtEnd : edge.IsAtStart)) return direction;
        }
        return null;
    }

    /// <summary>The furthest place known in a direction.</summary>
    ReaderLocation? Frontier(TurnDirection direction) =>
        (direction == TurnDirection.Forward ? _ahead : _behind).LastOrDefault()?.Location ?? _anchor;

    /// <summary>Turns can land while a spread renders, and it's still good if it still joins on.</summary>
    void Store(Spread spread, ReaderLocation from, TurnDirection direction)
    {
        if (Frontier(direction)?.Cfi != from.Cfi) return;
        var list = direction == TurnDirection.Forward ? _ahead : _behind;
        if (list.Count < Depth) list.Add(spread);
    }

    /// <summary>
    /// Goes to <paramref name="location"/> in the offscreen view, makes the move and pictures where it
    /// lands. A reader going one way leaves the view where this needs it, so there's nothing to go to.
    /// </summary>
    async Task<Spread?> NeighbourAsync(ReaderLocation location, TurnDirection direction, CancellationToken token)
    {
        if (_offscreen.CurrentLocation?.Cfi != location.Cfi)
        {
            await _offscreen.GoToCfiAsync(location.Cfi);
            if (token.IsCancellationRequested) return null;
        }
        // Starting anywhere else would make a preview of the wrong spread, which is worse than none.
        if (_offscreen.CurrentLocation?.Cfi != location.Cfi) return null;
        var moved = await (direction == TurnDirection.Forward ? _offscreen.NextAsync() : _offscreen.PreviousAsync());
        if (moved == null || token.IsCancellationRequested) return null;
        await _offscreen.SettleAsync();
        if (token.IsCancellationRequested || _offscreen.CurrentLocation is not { } landed) return null;
        if (await _offscreen.SnapshotAsync() is not { } image || token.IsCancellationRequested) return null;
        return new Spread(image, landed);
    }
}
