using System.Diagnostics;
using Readme.Core.Model;
using Readme.Core.Reader;

namespace Readme.Core.Curl;

/// <summary>Half of a spread's picture: its left page or its right.</summary>
public sealed record PageImage<TImage>(TImage Spread, bool IsRight, bool IsWhole = false) where TImage : class;

/// <summary>
/// What a curl shows (CurlPieces and TurnImages in TurnCoordinator.swift): four pages cut from two
/// spreads, or, with one page across, the page that turns and the one beneath it.
/// </summary>
public abstract record CurlPieces<TImage> where TImage : class
{
    public sealed record SpreadPieces(PageImage<TImage> Front, PageImage<TImage> Back, PageImage<TImage> BeneathLeft,
        PageImage<TImage> BeneathRight) : CurlPieces<TImage>;
    public sealed record PagePieces(TImage Front, TImage Beneath) : CurlPieces<TImage>;

    public static CurlPieces<TImage> Of(TurnDirection direction, TImage current, TImage target, bool isSinglePage)
    {
        if (isSinglePage)
            // Going back is the forward turn played in reverse, so the page coming back is the one that turns.
            return direction == TurnDirection.Forward ? new PagePieces(current, target) : new PagePieces(target, current);
        PageImage<TImage> Left(TImage spread) => new(spread, false);
        PageImage<TImage> Right(TImage spread) => new(spread, true);
        return direction == TurnDirection.Forward
            ? new SpreadPieces(Right(current), Left(target), Left(current), Right(target))
            : new SpreadPieces(Right(target), Left(current), Left(target), Right(current));
    }
}

/// <summary>The curl as the coordinator drives it. Progress runs 0 to 1, a backward turn being the forward one in reverse.</summary>
public interface ICurl<TImage> where TImage : class
{
    bool IsShowing { get; }
    double Progress { get; }
    /// <summary>The width the curl covers, the whole book.</summary>
    double Width { get; }
    void Begin(TurnDirection direction, CurlPieces<TImage> pieces);
    void SetProgress(double t);
    /// <summary>Runs from one progress to another at the curl's pace, then lays the page flat where it fell.</summary>
    void Play(double from, double to, Action completion);
    /// <summary>Fades one whole spread into another, for readers who've asked for less motion.</summary>
    void Crossfade(TImage from, TImage to, Action completion);
    /// <summary>Finishes whatever's playing at once, completion included.</summary>
    void SnapToEnd();
    /// <summary>Takes the curl off, showing what's underneath.</summary>
    void End();
}

/// <summary>What the coordinator reads of the visible book.</summary>
public interface ITurnBook
{
    ReaderLocation? CurrentLocation { get; }
    int Columns { get; }
    /// <summary>A link in the book followed (false), and again once it has landed (true).</summary>
    event Action<bool>? LinkFollowed;
    /// <summary>Returns once what the view shows has reached the screen, or soon if that can't be told.</summary>
    Task PagePaintedAsync();
}

/// <summary>
/// Turns the pages of a book (TurnCoordinator.swift): it plays the curl over the web view and moves
/// the web view beneath it. The curl only ever uses images known to belong to where the book is. A
/// press that outruns them waits only briefly, then the page just changes with no curl, as it does if
/// another press arrives first, so every press counts and the book never seems to ignore one.
///
/// A swipe holds the same curl under the reader's fingers, with the web view staying where it is until
/// they let go past the point of turning. Its images can still be on their way, as just after a jump:
/// then the curl rises to meet the fingers as soon as they come, or, if the fingers let go to turn
/// before then, plays the whole turn once they come. A press while the fingers are down counts as them
/// letting go, standing still. Single-threaded: use it from one thread, as the app's UI thread.
/// </summary>
public sealed class TurnCoordinator<TImage> where TImage : class
{
    /// <summary>How long a press waits for images before the page changes without a curl.</summary>
    public static readonly TimeSpan DefaultPatience = TimeSpan.FromMilliseconds(50);
    /// <summary>How long a press waits for the move before it to land.</summary>
    static readonly TimeSpan LandingPatience = TimeSpan.FromMilliseconds(150);
    static readonly TimeSpan PaintTimeout = TimeSpan.FromMilliseconds(500);
    static readonly TimeSpan SwipePollInterval = TimeSpan.FromMilliseconds(10);
    /// <summary>How long a swipe let go to turn waits for its images: only for images that never come.</summary>
    public static readonly TimeSpan SwipePatience = TimeSpan.FromMilliseconds(2500);
    /// <summary>How long a curl whose images came after the fingers began takes to rise to meet them.</summary>
    const double CatchUpDuration = 0.15;

    sealed class Swipe(TurnDirection direction, SwipeTracker tracker)
    {
        public TurnDirection Direction { get; } = direction;
        public SwipeTracker Tracker { get; } = tracker;
        public bool IsCurling;
        /// <summary>The curl is still rising to where the fingers are, so it doesn't follow them yet.</summary>
        public bool IsCatchingUp;
        /// <summary>Going back is the forward curl played from its end.</summary>
        public double CurlProgress => Direction == TurnDirection.Forward ? Tracker.Progress : 1 - Tracker.Progress;
    }

    readonly ITurnBook _book;
    readonly SpreadCache<TImage> _cache;
    readonly ICurl<TImage> _curl;
    readonly Func<bool> _reduceMotion;
    readonly TimeSpan _patience;

    /// <summary>Moves of the book that haven't finished settling.</summary>
    int _moves;
    /// <summary>Moves that haven't landed. Until they have, the cache's images and the location are out of date.</summary>
    int _unlanded;
    TurnDirection? _waitingTurn;
    Task? _waitingTask;
    CancellationTokenSource? _waitingStop;
    /// <summary>Identifies the latest curl, so an earlier one's landing doesn't take it off.</summary>
    int _curlNumber;
    Swipe? _swipe;
    CancellationTokenSource? _swipeWait;
    CancellationTokenSource? _catchUp;
    /// <summary>The moves and jumps that haven't finished, by number. A jump waits for them.</summary>
    readonly Dictionary<int, Task> _underWay = [];
    int _moveNumber;
    /// <summary>The latest jump, which moves asked for after it wait for.</summary>
    Task? _jumping;
    int _linksLanding;
    readonly List<TaskCompletionSource> _linkWaiters = [];

    public TurnCoordinator(ITurnBook book, SpreadCache<TImage> cache, ICurl<TImage> curl, Func<bool> reduceMotion, TimeSpan? patience = null)
    {
        _book = book;
        _cache = cache;
        _curl = curl;
        _reduceMotion = reduceMotion;
        _patience = patience ?? DefaultPatience;
        cache.UnforeseenMove += BookMovedElsewhere;
        book.LinkFollowed += landed =>
        {
            if (landed) LinkLanded();
            else LinkFollowed();
        };
    }

    /// <summary>True from a turn being accepted until the web view shows where it landed.</summary>
    public bool IsTurning => _swipe != null || _waitingTurn != null || _moves > 0 || _curl.IsShowing;

    /// <summary>Raised when a move of the book is asked for (with its direction), and when every move under way has landed.</summary>
    public event Action<TurnDirection>? Moving;
    public event Action? Settled;

    /// <summary>
    /// <paramref name="isRepeat"/> is a held key's repeat. Pages stop when the key is let go, so a repeat
    /// is dropped, never kept for later, while a turn before it is waiting for its images or its move to
    /// land. Every other press counts.
    /// </summary>
    public void Turn(TurnDirection direction, bool isRepeat = false)
    {
        if (_book.CurrentLocation == null) return;
        if (isRepeat && (_unlanded > 0 || _waitingTurn != null)) return;
        FinishEarlierTurns();
        if (_unlanded == 0 && StartOrDecline(direction)) return;
        Wait(direction, _patience);
    }

    void Wait(TurnDirection direction, TimeSpan patience)
    {
        _waitingTurn = direction;
        var stop = new CancellationTokenSource();
        _waitingStop = stop;
        _waitingTask = WaitAndTurnAsync(direction, patience, stop.Token);
    }

    /// <summary>Returns once the turns and jumps asked for so far have moved the book and settled.</summary>
    public async Task LandedAsync()
    {
        if (_waitingTask is { } waiting) await waiting;
        foreach (var move in _underWay.Values.ToList()) await move;
    }

    /// <summary>Follows the fingers. What arrives with no swipe to act on is ignored.</summary>
    public void Follow(SwipeSignal signal)
    {
        switch (signal)
        {
            case SwipeSignal.Start start:
                StartSwipe(start.Direction);
                break;
            case SwipeSignal.Move move:
                _swipe?.Tracker.Changed(move.Distance);
                if (_swipe is { IsCurling: true, IsCatchingUp: false } held) _curl.SetProgress(held.CurlProgress);
                break;
            case SwipeSignal.Release release:
                if (_swipe is { } swipe) FinishSwipe(swipe.Tracker.Ended(release.Velocity));
                break;
            case SwipeSignal.Abandon:
                FinishSwipe(SwipeOutcome.Cancel);
                break;
        }
    }

    public bool IsSwiping => _swipe != null;

    /// <summary>Whatever's under way has to end before anything new can begin.</summary>
    void FinishEarlierTurns()
    {
        // As if the fingers let go where they are, not moving.
        if (_swipe is { } held) FinishSwipe(held.Tracker.Ended(0));
        _curl.SnapToEnd();
        if (_waitingTurn is { } earlier)
        {
            // It's been overtaken, so it has its move now and no curl.
            _waitingStop?.Cancel();
            _waitingTurn = null;
            Move(earlier);
        }
    }

    void StartSwipe(TurnDirection direction)
    {
        if (_book.CurrentLocation == null) return;
        FinishEarlierTurns();
        var tracker = new SwipeTracker(IsSinglePage ? _curl.Width : _curl.Width / 2);
        tracker.Began();
        _swipe = new Swipe(direction, tracker);
        if (PickUpSwipe()) return;
        // The images the fingers need are rendered first.
        _cache.Prefer(direction);
        var stop = new CancellationTokenSource();
        _swipeWait = stop;
        _ = Poll();
        async Task Poll()
        {
            while (true)
            {
                try { await Task.Delay(SwipePollInterval, stop.Token); }
                catch (OperationCanceledException) { return; }
                if (stop.IsCancellationRequested || PickUpSwipe(late: true)) return;
            }
        }
    }

    /// <summary>
    /// True if the swipe needs no more waiting: its curl is on screen, it never has one, or it's past
    /// the end of the book and so over. The images can only be trusted with nothing left to land.
    /// </summary>
    bool PickUpSwipe(bool late = false)
    {
        if (_swipe is not { } held || _unlanded != 0) return false;
        if (IsPastTheEnd(held.Direction))
        {
            _swipe = null;
            return true;
        }
        if (_reduceMotion()) return true;
        if (Images(held.Direction) is not { } spreads) return false;
        _curlNumber++;
        _curl.Begin(held.Direction, CurlPieces<TImage>.Of(held.Direction, spreads.Current, spreads.Target, IsSinglePage));
        held.IsCurling = true;
        if (late) RiseToFingers(held, held.Direction == TurnDirection.Forward ? 0 : 1);
        else _curl.SetProgress(held.CurlProgress);
        return true;
    }

    /// <summary>The fingers are already partway across, so the curl eases up to them rather than appearing there.</summary>
    void RiseToFingers(Swipe held, double start)
    {
        held.IsCatchingUp = true;
        _curl.SetProgress(start);
        var stop = new CancellationTokenSource();
        _catchUp = stop;
        _ = Rise();
        async Task Rise()
        {
            var clock = Stopwatch.StartNew();
            while (!stop.IsCancellationRequested)
            {
                if (_swipe != held || !held.IsCatchingUp) return;
                var share = Math.Min(1, clock.Elapsed.TotalSeconds / CatchUpDuration);
                var eased = 1 - (1 - share) * (1 - share);
                _curl.SetProgress(start + (held.CurlProgress - start) * eased);
                if (share >= 1)
                {
                    held.IsCatchingUp = false;
                    return;
                }
                try { await Task.Delay(8, stop.Token); } catch (OperationCanceledException) { return; }
            }
        }
    }

    void FinishSwipe(SwipeOutcome outcome)
    {
        if (_swipe is not { } held) return;
        _swipe = null;
        _swipeWait?.Cancel();
        _swipeWait = null;
        _catchUp?.Cancel();
        _catchUp = null;
        if (!held.IsCurling)
        {
            if (outcome == SwipeOutcome.Commit) TurnWithoutFollowing(held.Direction);
            return;
        }
        // The page's already under the curl, so this is the one moment it may move.
        var landing = outcome == SwipeOutcome.Commit ? Move(held.Direction) : null;
        var number = ++_curlNumber;
        var wentOver = held.Direction == TurnDirection.Forward ? outcome == SwipeOutcome.Commit : outcome == SwipeOutcome.Cancel;
        _curl.Play(_curl.Progress, wentOver ? 1 : 0, () => Uncover(number, landing));
    }

    /// <summary>
    /// Fingers let go past the point of turning before their curl's images came. The turn waits for
    /// them, longer than a press does, and plays the whole curl once they're here.
    /// </summary>
    void TurnWithoutFollowing(TurnDirection direction)
    {
        if (_reduceMotion())
        {
            Turn(direction);
            return;
        }
        if (_unlanded == 0 && StartOrDecline(direction)) return;
        _cache.Prefer(direction);
        Wait(direction, SwipePatience);
    }

    /// <summary>The book's laid out one page across. Its images then hold one page each.</summary>
    bool IsSinglePage => _book.Columns == 1;

    bool IsPastTheEnd(TurnDirection direction) =>
        _book.CurrentLocation is not { } here || (direction == TurnDirection.Forward ? here.IsAtEnd : here.IsAtStart);

    /// <summary>
    /// The spreads a turn goes from and to, only if they belong to where the book is now: a link or a
    /// jump can move it without a turn.
    /// </summary>
    (TImage Current, TImage Target)? Images(TurnDirection direction)
    {
        if (_book.CurrentLocation is not { } here || !_cache.ImagesBelong(here)
            || _cache.Image(SpreadSlot.Current) is not { } current
            || _cache.Image(direction == TurnDirection.Forward ? SpreadSlot.Next : SpreadSlot.Previous) is not { } target)
            return null;
        return (current, target);
    }

    /// <summary>
    /// The book went somewhere no turn took it, so a curl on screen shows where it was. It comes off,
    /// and fingers holding a page have to start again.
    /// </summary>
    void BookMovedElsewhere()
    {
        if (_swipe?.IsCurling == true)
        {
            _swipe = null;
            _swipeWait?.Cancel();
            _swipeWait = null;
        }
        if (!_curl.IsShowing) return;
        _curlNumber++;
        _curl.End();
    }

    /// <summary>
    /// Waits for a move still landing, as its images will be good then, and briefly for images that
    /// may be about to arrive.
    /// </summary>
    async Task WaitAndTurnAsync(TurnDirection direction, TimeSpan patience, CancellationToken token)
    {
        var pressed = Stopwatch.StartNew();
        await Task.Yield();
        while (true)
        {
            var isWaitingUsefully = _unlanded > 0
                ? pressed.Elapsed < (LandingPatience > patience ? LandingPatience : patience)
                : Images(direction) == null && !IsPastTheEnd(direction) && pressed.Elapsed < patience;
            if (!isWaitingUsefully) break;
            try { await Task.Delay(10, token); } catch (OperationCanceledException) { return; }
        }
        if (token.IsCancellationRequested) return;
        _waitingTurn = null;
        if (_unlanded == 0 && StartOrDecline(direction)) return;
        _ = Move(direction);
    }

    /// <summary>True if that settles the turn: it's past the end, or its curl has started. Only with nothing left to land.</summary>
    bool StartOrDecline(TurnDirection direction)
    {
        if (IsPastTheEnd(direction)) return true;
        if (Images(direction) is not { } spreads) return false;
        Start(direction, spreads.Current, spreads.Target);
        return true;
    }

    void Start(TurnDirection direction, TImage current, TImage target)
    {
        // The move yields before it starts, so the curl is up and covering the book before it can change.
        var landing = Move(direction);
        var number = ++_curlNumber;
        if (_reduceMotion()) _curl.Crossfade(current, target, () => Uncover(number, landing));
        else
        {
            _curl.Begin(direction, CurlPieces<TImage>.Of(direction, current, target, IsSinglePage));
            var forward = direction == TurnDirection.Forward;
            _curl.Play(forward ? 0 : 1, forward ? 1 : 0, () => Uncover(number, landing));
        }
    }

    /// <summary>The web view's move. They reach the book in the order they're made, and after any jump made before them.</summary>
    Task Move(TurnDirection direction)
    {
        _moves++;
        _unlanded++;
        var jump = _jumping;
        var number = ++_moveNumber;
        Moving?.Invoke(direction);
        var task = Run();
        _underWay[number] = task;
        return task;

        async Task Run()
        {
            await Task.Yield();
            if (jump != null) await jump;
            try { await _cache.CommitAsync(direction, () => _unlanded--); }
            finally
            {
                _moves--;
                _underWay.Remove(number);
                if (_moves == 0) Settled?.Invoke();
            }
        }
    }

    /// <summary>
    /// Takes the book somewhere turning doesn't, such as a chapter or a page number, with no curl.
    /// <paramref name="go"/> makes the move and returns where it landed. What's under way ends first;
    /// the jump then waits for every turn before it to land, and turns asked for meanwhile wait for it.
    /// </summary>
    public async Task<ReaderLocation?> JumpAsync(Func<Task<ReaderLocation?>> go) =>
        StartJump(go) is { } jump ? await jump : null;

    Task<ReaderLocation?>? StartJump(Func<Task<ReaderLocation?>> go)
    {
        if (_book.CurrentLocation == null) return null;
        FinishEarlierTurns();
        var earlier = _underWay.Values.ToList();
        _moves++;
        _unlanded++;
        var number = ++_moveNumber;
        var jump = Run();
        _underWay[number] = jump;
        _jumping = jump;
        return jump;

        async Task<ReaderLocation?> Run()
        {
            await Task.Yield();
            foreach (var move in earlier) await move;
            try { return await go(); }
            finally
            {
                _unlanded--;
                _moves--;
                _underWay.Remove(number);
                if (_moves == 0) Settled?.Invoke();
            }
        }
    }

    /// <summary>
    /// A link in the book waits in the page's queue, and the book still shows the old place until it
    /// lands. It's a jump the coordinator didn't make: no curl starts from the old place's images meanwhile.
    /// </summary>
    void LinkFollowed()
    {
        _linksLanding++;
        StartJump(async () =>
        {
            await LinksLandedAsync();
            return _book.CurrentLocation;
        });
    }

    void LinkLanded()
    {
        _linksLanding = Math.Max(0, _linksLanding - 1);
        if (_linksLanding != 0) return;
        var waiters = _linkWaiters.ToList();
        _linkWaiters.Clear();
        foreach (var waiter in waiters) waiter.TrySetResult();
    }

    Task LinksLandedAsync()
    {
        if (_linksLanding == 0) return Task.CompletedTask;
        var waiter = new TaskCompletionSource();
        _linkWaiters.Add(waiter);
        return waiter.Task;
    }

    /// <summary>Waits for the web view to have the landed page on screen, then uncovers it.</summary>
    void Uncover(int number, Task? landing)
    {
        _ = Run();
        async Task Run()
        {
            if (landing != null) await landing;
            await Task.WhenAny(_book.PagePaintedAsync(), Task.Delay(PaintTimeout));
            if (number == _curlNumber) _curl.End();
        }
    }
}
