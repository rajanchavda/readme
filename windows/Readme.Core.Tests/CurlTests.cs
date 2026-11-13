using System.Collections.Concurrent;
using Readme.Core.Curl;
using Readme.Core.Model;
using Readme.Core.Reader;

namespace Readme.Core.Tests;

/// <summary>Ported from CurlPoseTests.swift.</summary>
[TestClass]
public sealed class CurlPoseTests
{
    [TestMethod] public void FlatAtStart() => Assert.IsTrue(CurlPose.Angles(0).All(a => a == 0));
    [TestMethod] public void FlatAtEnd() => Assert.IsTrue(CurlPose.Angles(1).All(a => a == -179.5));
    [TestMethod] public void StraightAtMidpoint() => Assert.IsTrue(CurlPose.Angles(0.5).All(a => Math.Abs(a + 90) < 0.001));

    [TestMethod]
    public void OuterEdgeLeadsBeforeMidpoint()
    {
        var a = CurlPose.Angles(0.25);
        Assert.AreEqual(0, a[0]);
        Assert.IsTrue(a[^1] < -40);
    }

    [TestMethod]
    public void OuterEdgeTrailsAfterMidpoint()
    {
        var a = CurlPose.Angles(0.75);
        Assert.AreEqual(-179.5, a[0]);
        Assert.IsTrue(a[^1] > -140);
    }

    [TestMethod]
    public void ShadeIsDarkestEdgeOn()
    {
        Assert.AreEqual(0.16, CurlPose.Shade(-90), 0.001);
        Assert.AreEqual(0, CurlPose.Shade(0));
    }

    [TestMethod]
    public void DrawnAnglesCloseToFlat()
    {
        Assert.IsTrue(CurlPose.DrawnAngles(1).All(a => a == -180));
        CollectionAssert.AreEqual(CurlPose.Angles(0.5), CurlPose.DrawnAngles(0.5));
    }

    [TestMethod]
    public void ASinglePageFadesOverItsLastThird()
    {
        Assert.AreEqual(1, CurlPose.PageOpacity(0.6));
        Assert.AreEqual(0.5, CurlPose.PageOpacity(0.85), 1e-9);
        Assert.AreEqual(0, CurlPose.PageOpacity(1));
    }

    [TestMethod]
    public void NeighbouringStripsAgreeAtTheirHinge()
    {
        var angles = CurlPose.DrawnAngles(0.3);
        for (var i = 0; i < angles.Length - 1; i++)
            Assert.AreEqual(CurlPose.HingeShades(angles, i).Far, CurlPose.HingeShades(angles, i + 1).Near, 1e-12);
    }
}

/// <summary>Ported from SwipeTrackerTests.swift.</summary>
[TestClass]
public sealed class SwipeTrackerTests
{
    static SwipeTracker At(double progress)
    {
        var tracker = new SwipeTracker(500);
        tracker.Began();
        tracker.Changed(progress * 500);
        return tracker;
    }

    [TestMethod]
    public void FollowsFingers()
    {
        var tracker = new SwipeTracker(500);
        tracker.Began();
        Assert.AreEqual(0.2, tracker.Changed(100));
        Assert.AreEqual(0.5, tracker.Changed(150));
    }

    [TestMethod]
    public void ClampsAtEnds()
    {
        var tracker = new SwipeTracker(500);
        tracker.Began();
        Assert.AreEqual(1, tracker.Changed(1000));
        tracker.Began();
        Assert.AreEqual(0, tracker.Changed(-1000));
    }

    [TestMethod] public void CommitsPastHalfway() => Assert.AreEqual(SwipeOutcome.Commit, At(0.6).Ended(0));
    [TestMethod] public void FallsBackBeforeHalfway() => Assert.AreEqual(SwipeOutcome.Cancel, At(0.3).Ended(0));
    [TestMethod] public void FlickCommits() => Assert.AreEqual(SwipeOutcome.Commit, At(0.2).Ended(601));
    [TestMethod] public void ReverseFlickCancels() => Assert.AreEqual(SwipeOutcome.Cancel, At(0.7).Ended(-601));

    [TestMethod]
    public void ASlowerMoveIsNotAFlick()
    {
        Assert.AreEqual(SwipeOutcome.Cancel, At(0.2).Ended(600));
        Assert.AreEqual(SwipeOutcome.Commit, At(0.7).Ended(-600));
    }

    [TestMethod]
    public void ComingBackFromAnEndMovesAtOnce()
    {
        var tracker = new SwipeTracker(500);
        tracker.Began();
        tracker.Changed(1000);
        Assert.AreEqual(0.9, tracker.Changed(-50), 1e-12);
    }

    [TestMethod]
    public void BeganStartsAgain()
    {
        var swipe = At(0.7);
        swipe.Began();
        Assert.AreEqual(0, swipe.Progress);
        Assert.AreEqual(0.1, swipe.Changed(50));
    }
}

/// <summary>Ported from SwipeGestureTests in SwipeTrackerTests.swift, plus Windows' wheel gestures.</summary>
[TestClass]
public sealed class SwipeGestureTests
{
    static IReadOnlyList<SwipeSignal> Send(SwipeGesture g, SwipePhase phase, double x = 0, double y = 0, int step = 0) =>
        g.Handle(phase, x, y, step / 60.0);

    static SwipeSignal Start(TurnDirection d) => new SwipeSignal.Start(d);
    static SwipeSignal Move(double d) => new SwipeSignal.Move(d);

    [TestMethod]
    public void FingersRightToLeftTurnForward()
    {
        var g = new SwipeGesture();
        Assert.AreEqual(0, Send(g, SwipePhase.Began, x: -3).Count);
        Assert.AreEqual(0, Send(g, SwipePhase.Changed, x: -3, step: 1).Count);
        CollectionAssert.AreEqual(new[] { Start(TurnDirection.Forward), Move(9) }, Send(g, SwipePhase.Changed, x: -3, step: 2).ToArray());
        CollectionAssert.AreEqual(new[] { Move(5) }, Send(g, SwipePhase.Changed, x: -5, step: 3).ToArray());
        CollectionAssert.AreEqual(new[] { Move(-2) }, Send(g, SwipePhase.Changed, x: 2, step: 4).ToArray());
    }

    [TestMethod]
    public void FingersLeftToRightTurnBack()
    {
        var g = new SwipeGesture();
        CollectionAssert.AreEqual(new[] { Start(TurnDirection.Backward), Move(10) }, Send(g, SwipePhase.Began, x: 10).ToArray());
        CollectionAssert.AreEqual(new[] { Move(4) }, Send(g, SwipePhase.Changed, x: 4, step: 1).ToArray());
    }

    [TestMethod]
    public void AMostlyVerticalScrollIsIgnoredToTheEnd()
    {
        var g = new SwipeGesture();
        Assert.AreEqual(0, Send(g, SwipePhase.Began, x: 2, y: 9).Count);
        Assert.AreEqual(0, Send(g, SwipePhase.Changed, x: -200, step: 1).Count);
        Assert.AreEqual(0, Send(g, SwipePhase.Ended, step: 2).Count);
    }

    [TestMethod]
    public void ADiagonalScrollIsIgnored()
    {
        var g = new SwipeGesture();
        Assert.AreEqual(0, Send(g, SwipePhase.Began, x: 10, y: 10).Count);
        Assert.AreEqual(0, Send(g, SwipePhase.Changed, x: 100, step: 1).Count);
    }

    [TestMethod]
    public void AReleaseCarriesTheFingersSpeed()
    {
        var g = new SwipeGesture();
        Send(g, SwipePhase.Began, x: -20);
        for (var step = 1; step <= 3; step++) Send(g, SwipePhase.Changed, x: -20, step: step);
        var release = (SwipeSignal.Release)Send(g, SwipePhase.Ended, step: 4)[0];
        Assert.AreEqual(900, release.Velocity, 1);
    }

    [TestMethod]
    public void AReleaseBackwardsReadsAsAReverseVelocity()
    {
        var g = new SwipeGesture();
        Send(g, SwipePhase.Began, x: -20);
        for (var step = 1; step <= 3; step++) Send(g, SwipePhase.Changed, x: 20, step: step);
        var release = (SwipeSignal.Release)Send(g, SwipePhase.Ended, step: 3)[0];
        Assert.AreEqual(-1200, release.Velocity, 1);
    }

    [TestMethod]
    public void APauseBeforeReleaseHasNoSpeed()
    {
        var g = new SwipeGesture();
        Send(g, SwipePhase.Began, x: -20);
        Send(g, SwipePhase.Changed, x: -20, step: 1);
        CollectionAssert.AreEqual(new SwipeSignal[] { new SwipeSignal.Release(0) }, Send(g, SwipePhase.Ended, step: 30).ToArray());
    }

    [TestMethod]
    public void ACancelledGestureAbandons()
    {
        var g = new SwipeGesture();
        Send(g, SwipePhase.Began, x: -20);
        CollectionAssert.AreEqual(new SwipeSignal[] { new SwipeSignal.Abandon() }, Send(g, SwipePhase.Cancelled, step: 1).ToArray());
        Assert.AreEqual(0, Send(g, SwipePhase.Changed, x: -20, step: 2).Count);
    }

    [TestMethod]
    public void NothingHappensWithoutABeginning()
    {
        var g = new SwipeGesture();
        Assert.AreEqual(0, Send(g, SwipePhase.Changed, x: -200).Count);
        Assert.AreEqual(0, Send(g, SwipePhase.Ended, step: 1).Count);
    }

    [TestMethod]
    public void ANewGestureAbandonsOneThatNeverEnded()
    {
        var g = new SwipeGesture();
        Send(g, SwipePhase.Began, x: -20);
        CollectionAssert.AreEqual(new[] { new SwipeSignal.Abandon(), Start(TurnDirection.Backward), Move(20) },
            Send(g, SwipePhase.Began, x: 20, step: 1).ToArray());
    }

    // Windows' wheel events.

    [TestMethod]
    public void AWheelGestureBeginsAndEndsOnPauses()
    {
        var wheel = new WheelSwipes();
        // Content scrolled right is fingers going left: forward.
        Assert.AreEqual(0, wheel.Wheel(4, 0, 0).Count);
        CollectionAssert.AreEqual(new[] { Start(TurnDirection.Forward), Move(8) }, wheel.Wheel(4, 0, 0.01).ToArray());
        CollectionAssert.AreEqual(new[] { Move(30) }, wheel.Wheel(30, 0, 0.02).ToArray());
        Assert.AreEqual(0, wheel.Tick(0.1).Count);
        var end = wheel.Tick(0.2);
        Assert.IsInstanceOfType<SwipeSignal.Release>(end.Single());
        Assert.IsFalse(wheel.IsActive);
        // The next events are a new gesture.
        CollectionAssert.AreEqual(new[] { Start(TurnDirection.Backward), Move(10) }, wheel.Wheel(-10, 0, 0.5).ToArray());
    }

    [TestMethod]
    public void AMouseWheelNeverSwipes()
    {
        Assert.IsTrue(WheelSwipes.IsNotch(0, 120));
        Assert.IsTrue(WheelSwipes.IsNotch(-240, 0));
        Assert.IsTrue(WheelSwipes.IsNotch(0, -100));
        Assert.IsFalse(WheelSwipes.IsNotch(12.5, 0));
        Assert.IsFalse(WheelSwipes.IsNotch(120, 3));
        var wheel = new WheelSwipes();
        Assert.AreEqual(0, wheel.Wheel(120, 0, 0).Count);
        Assert.AreEqual(0, wheel.Wheel(120, 0, 0.05).Count);
        Assert.AreEqual(0, wheel.Tick(1).Count);
    }
}

/// <summary>A picture of one spread of the fake book.</summary>
sealed record Pic(int Spread);

/// <summary>A book of <c>count</c> spreads; a move takes <c>moveTime</c>, a picture <c>snapTime</c>.</summary>
sealed class FakeView(int count, int at, int moveTime = 15, int snapTime = 5) : IOffscreenSpreadView<Pic>, IVisibleSpreadView<Pic>, ITurnBook
{
    public int Index = at;
    public bool Open = true;
    public int Moves;
    public SpreadLayout Look = new("book", 1000, 600, 1, "css", 2, null, "", "");

    public static ReaderLocation Place(int index, int count) => new()
    {
        Cfi = $"spread{index}", Fraction = index / (double)count, ChapterMinutesLeft = 1,
        IsAtStart = index == 0, IsAtEnd = index == count - 1, Page = index * 2 + 1, PageCount = count * 2,
    };

    public ReaderLocation? CurrentLocation => Open ? Place(Index, count) : null;
    public bool IsOpen => Open;
    public int Columns { get; set; } = 2;
    public SpreadLayout Layout => Look;
    public event Action<ReaderLocation>? Relocated;
    public event Action<bool>? LinkFollowed;

    public Task<ReaderLocation?> NextAsync() => Queue(() => Index + 1);
    public Task<ReaderLocation?> PreviousAsync() => Queue(() => Index - 1);
    public Task<ReaderLocation?> GoToCfiAsync(string cfi) => MoveTo(int.Parse(cfi["spread".Length..]));
    public Task<ReaderLocation?> MoveTo(int index) => Queue(() => index);

    /// <summary>Moves run one after another, as the page runs them, each from where the last one left it.</summary>
    Task<ReaderLocation?> Queue(Func<int> target)
    {
        var before = _moving;
        var move = Run();
        _moving = move;
        return move;
        async Task<ReaderLocation?> Run()
        {
            await before;
            return await Step(target());
        }
    }

    Task _moving = Task.CompletedTask;

    async Task<ReaderLocation?> Step(int index)
    {
        await Task.Delay(moveTime);
        if (index < 0 || index >= count) return null;
        Index = index;
        Moves++;
        Relocated?.Invoke(Place(Index, count));
        return Place(Index, count);
    }

    public Task SettleAsync() => Task.Delay(1);
    public async Task<Pic?> SnapshotAsync()
    {
        await Task.Delay(snapTime);
        return new Pic(Index);
    }

    public Task<bool> PrepareAsync(SpreadLayout layout, ReaderLocation at) => Task.FromResult(true);
    public Task PagePaintedAsync() => Task.Delay(1);

    /// <summary>A link followed in the book: the page moves with no turn.</summary>
    public async Task FollowLink(int index)
    {
        LinkFollowed?.Invoke(false);
        await MoveTo(index);
        LinkFollowed?.Invoke(true);
    }
}

/// <summary>Records what's asked of the curl. A play takes <c>playTime</c>.</summary>
sealed class FakeCurl(int playTime = 30) : ICurl<Pic>
{
    public bool IsShowing { get; private set; }
    public double Progress { get; private set; }
    public double Width => 1000;
    public readonly List<string> Log = [];
    public CurlPieces<Pic>? Pieces;
    Action? _completion;
    int _play;

    public void Begin(TurnDirection direction, CurlPieces<Pic> pieces)
    {
        Pieces = pieces;
        IsShowing = true;
        Log.Add($"begin {direction}");
    }

    public void SetProgress(double t) => Progress = t;

    public void Play(double from, double to, Action completion)
    {
        Progress = from;
        _completion = completion;
        var number = ++_play;
        Log.Add($"play {from:0.##}->{to:0.##}");
        _ = Finish();
        async Task Finish()
        {
            await Task.Delay(playTime);
            if (number != _play || _completion == null) return;
            Progress = to;
            Complete();
        }
    }

    public void Crossfade(Pic from, Pic to, Action completion)
    {
        IsShowing = true;
        Log.Add($"crossfade {from.Spread}->{to.Spread}");
        Play(0, 1, completion);
    }

    public void SnapToEnd()
    {
        if (_completion == null) return;
        Log.Add("snap");
        Complete();
    }

    void Complete()
    {
        var done = _completion;
        _completion = null;
        done?.Invoke();
    }

    public void End()
    {
        _completion = null;
        _play++;
        IsShowing = false;
        Log.Add("end");
    }
}

/// <summary>Runs async code on one thread, as the UI thread runs it, so the coordinator never sees two at once.</summary>
static class OneThread
{
    sealed class Context : SynchronizationContext
    {
        readonly BlockingCollection<(SendOrPostCallback, object?)> _queue = [];
        /// <summary>Work posted after the test is over, such as rendering still under way, is dropped.</summary>
        public override void Post(SendOrPostCallback d, object? state)
        {
            try { _queue.Add((d, state)); }
            catch (InvalidOperationException) { }
        }
        public void RunUntil(Task task)
        {
            task.ContinueWith(_ => _queue.CompleteAdding(), TaskScheduler.Default);
            foreach (var (callback, state) in _queue.GetConsumingEnumerable()) callback(state);
        }
    }

    public static void Run(Func<Task> body)
    {
        var previous = SynchronizationContext.Current;
        var context = new Context();
        SynchronizationContext.SetSynchronizationContext(context);
        try
        {
            var task = body();
            context.RunUntil(task);
            task.GetAwaiter().GetResult();
        }
        finally { SynchronizationContext.SetSynchronizationContext(previous); }
    }
}

[TestClass]
public sealed class SpreadCacheTests
{
    [TestMethod]
    public void FillsTwoEachWayAndRotatesOnATurn() => OneThread.Run(async () =>
    {
        var visible = new FakeView(10, 5);
        var cache = new SpreadCache<Pic>(visible, new FakeView(10, 0));
        await cache.RefreshAsync(visible.CurrentLocation!);
        await cache.NeighboursReadyAsync();
        Assert.AreEqual(new Pic(5), cache.Image(SpreadSlot.Current));
        Assert.AreEqual(new Pic(6), cache.Image(SpreadSlot.Next));
        Assert.AreEqual(new Pic(7), cache.Image(SpreadSlot.AfterNext));
        Assert.AreEqual(new Pic(4), cache.Image(SpreadSlot.Previous));
        Assert.AreEqual(new Pic(3), cache.Image(SpreadSlot.BeforePrevious));

        var landed = false;
        await cache.CommitAsync(TurnDirection.Forward, () => landed = true);
        Assert.IsTrue(landed);
        Assert.AreEqual(6, visible.Index);
        Assert.AreEqual(new Pic(6), cache.Image(SpreadSlot.Current));
        Assert.AreEqual(new Pic(5), cache.Image(SpreadSlot.Previous));
        Assert.IsTrue(cache.ImagesBelong(visible.CurrentLocation!));
        await cache.NeighboursReadyAsync();
        Assert.AreEqual(new Pic(8), cache.Image(SpreadSlot.AfterNext));
    });

    [TestMethod]
    public void NothingPastTheEnds() => OneThread.Run(async () =>
    {
        var visible = new FakeView(3, 2);
        var cache = new SpreadCache<Pic>(visible, new FakeView(3, 0));
        await cache.RefreshAsync(visible.CurrentLocation!);
        await cache.NeighboursReadyAsync();
        Assert.IsNull(cache.Image(SpreadSlot.Next));
        Assert.AreEqual(new Pic(1), cache.Image(SpreadSlot.Previous));
        Assert.AreEqual(new Pic(0), cache.Image(SpreadSlot.BeforePrevious));
    });

    [TestMethod]
    public void AChangedLookEmptiesItAndAnUnforeseenMoveIsHeard() => OneThread.Run(async () =>
    {
        var visible = new FakeView(10, 5);
        var cache = new SpreadCache<Pic>(visible, new FakeView(10, 0));
        var heard = 0;
        cache.UnforeseenMove += () => heard++;
        await cache.RefreshAsync(visible.CurrentLocation!);
        visible.Look = visible.Look with { Css = "bigger" };
        Assert.IsFalse(cache.ImagesBelong(visible.CurrentLocation!));
        visible.Look = visible.Look with { Css = "css" };
        await visible.FollowLink(1);
        Assert.AreEqual(1, heard);
        await cache.NeighboursReadyAsync();
        Assert.AreEqual(new Pic(1), cache.Image(SpreadSlot.Current));
        Assert.AreEqual(new Pic(2), cache.Image(SpreadSlot.Next));
    });
}

/// <summary>The rules of TurnCoordinator.swift, as RapidTurnTests and SwipeTurnTests check them on Mac.</summary>
[TestClass]
public sealed class TurnCoordinatorTests
{
    sealed record Setup(FakeView Book, SpreadCache<Pic> Cache, FakeCurl Curl, TurnCoordinator<Pic> Turns);

    static async Task<Setup> Ready(int count = 20, int at = 5, bool reduceMotion = false, bool fill = true)
    {
        var book = new FakeView(count, at);
        var cache = new SpreadCache<Pic>(book, new FakeView(count, 0));
        var curl = new FakeCurl();
        var turns = new TurnCoordinator<Pic>(book, cache, curl, () => reduceMotion);
        if (fill)
        {
            await cache.RefreshAsync(book.CurrentLocation!);
            await cache.NeighboursReadyAsync();
        }
        return new Setup(book, cache, curl, turns);
    }

    static async Task Quiet(Setup s)
    {
        await s.Turns.LandedAsync();
        for (var i = 0; i < 100 && s.Curl.IsShowing; i++) await Task.Delay(10);
    }

    [TestMethod]
    public void APressCurlsFromTheImagesThenUncovers() => OneThread.Run(async () =>
    {
        var s = await Ready();
        s.Turns.Turn(TurnDirection.Forward);
        Assert.IsTrue(s.Curl.IsShowing, "the curl covers the book at once");
        var pieces = (CurlPieces<Pic>.SpreadPieces)s.Curl.Pieces!;
        Assert.AreEqual(new PageImage<Pic>(new Pic(5), true), pieces.Front);
        Assert.AreEqual(new PageImage<Pic>(new Pic(6), false), pieces.Back);
        Assert.AreEqual(new PageImage<Pic>(new Pic(5), false), pieces.BeneathLeft);
        Assert.AreEqual(new PageImage<Pic>(new Pic(6), true), pieces.BeneathRight);
        await Quiet(s);
        Assert.AreEqual(6, s.Book.Index);
        Assert.IsFalse(s.Curl.IsShowing);
        CollectionAssert.AreEqual(new[] { "begin Forward", "play 0->1", "end" }, s.Curl.Log);
        Assert.IsFalse(s.Turns.IsTurning);
    });

    [TestMethod]
    public void BackwardPlaysTheForwardTurnInReverse() => OneThread.Run(async () =>
    {
        var s = await Ready();
        s.Turns.Turn(TurnDirection.Backward);
        var pieces = (CurlPieces<Pic>.SpreadPieces)s.Curl.Pieces!;
        Assert.AreEqual(new PageImage<Pic>(new Pic(4), true), pieces.Front);
        Assert.AreEqual(new PageImage<Pic>(new Pic(5), false), pieces.Back);
        await Quiet(s);
        Assert.AreEqual(4, s.Book.Index);
        Assert.AreEqual("play 1->0", s.Curl.Log[1]);
    });

    [TestMethod]
    public void WithNoImagesThePageJustChanges() => OneThread.Run(async () =>
    {
        var s = await Ready(fill: false);
        s.Turns.Turn(TurnDirection.Forward);
        await Quiet(s);
        Assert.AreEqual(6, s.Book.Index);
        Assert.AreEqual(0, s.Curl.Log.Count);
    });

    [TestMethod]
    public void EveryPressCountsAndAnOvertakenCurlSnapsToItsEnd() => OneThread.Run(async () =>
    {
        var s = await Ready();
        for (var i = 0; i < 4; i++) s.Turns.Turn(TurnDirection.Forward);
        await Quiet(s);
        Assert.AreEqual(9, s.Book.Index);
        CollectionAssert.Contains(s.Curl.Log, "snap");
        Assert.IsFalse(s.Curl.IsShowing);
    });

    [TestMethod]
    public void AHeldKeysRepeatsAreDroppedWhileATurnLands() => OneThread.Run(async () =>
    {
        var s = await Ready();
        s.Turns.Turn(TurnDirection.Forward);
        for (var i = 0; i < 5; i++) s.Turns.Turn(TurnDirection.Forward, isRepeat: true);
        await Quiet(s);
        Assert.AreEqual(6, s.Book.Index, "letting go stops the book at once");
    });

    [TestMethod]
    public void NothingPastTheEnd() => OneThread.Run(async () =>
    {
        var s = await Ready(count: 6, at: 5);
        s.Turns.Turn(TurnDirection.Forward);
        await Quiet(s);
        Assert.AreEqual(5, s.Book.Index);
        Assert.AreEqual(0, s.Curl.Log.Count);
    });

    [TestMethod]
    public void ReducedMotionCrossfades() => OneThread.Run(async () =>
    {
        var s = await Ready(reduceMotion: true);
        s.Turns.Turn(TurnDirection.Forward);
        await Quiet(s);
        Assert.AreEqual("crossfade 5->6", s.Curl.Log[0]);
        Assert.AreEqual(6, s.Book.Index);
    });

    [TestMethod]
    public void ASwipePastHalfwayTurnsAndOneShortOfItFallsBack() => OneThread.Run(async () =>
    {
        var s = await Ready();
        s.Turns.Follow(new SwipeSignal.Start(TurnDirection.Forward));
        s.Turns.Follow(new SwipeSignal.Move(300));
        Assert.IsTrue(s.Curl.IsShowing);
        Assert.AreEqual(0.6, s.Curl.Progress, 1e-9);
        Assert.AreEqual(5, s.Book.Index, "the page stays until the fingers let go");
        s.Turns.Follow(new SwipeSignal.Release(0));
        await Quiet(s);
        Assert.AreEqual(6, s.Book.Index);

        s.Curl.Log.Clear();
        await s.Cache.NeighboursReadyAsync();
        s.Turns.Follow(new SwipeSignal.Start(TurnDirection.Forward));
        s.Turns.Follow(new SwipeSignal.Move(100));
        s.Turns.Follow(new SwipeSignal.Release(0));
        await Quiet(s);
        Assert.AreEqual(6, s.Book.Index);
        CollectionAssert.AreEqual(new[] { "begin Forward", "play 0.2->0", "end" }, s.Curl.Log);
    });

    [TestMethod]
    public void AFlickTurnsFromAnywhere() => OneThread.Run(async () =>
    {
        var s = await Ready();
        s.Turns.Follow(new SwipeSignal.Start(TurnDirection.Backward));
        s.Turns.Follow(new SwipeSignal.Move(40));
        Assert.AreEqual(1 - 0.08, s.Curl.Progress, 1e-9);
        s.Turns.Follow(new SwipeSignal.Release(900));
        await Quiet(s);
        Assert.AreEqual(4, s.Book.Index);
    });

    [TestMethod]
    public void APressWhileTheFingersAreDownLetsGoWhereTheyAre() => OneThread.Run(async () =>
    {
        var s = await Ready();
        s.Turns.Follow(new SwipeSignal.Start(TurnDirection.Forward));
        s.Turns.Follow(new SwipeSignal.Move(350));
        s.Turns.Turn(TurnDirection.Forward);
        Assert.IsFalse(s.Turns.IsSwiping);
        await Quiet(s);
        Assert.AreEqual(7, s.Book.Index, "the held page went over, then the press turned another");
    });

    [TestMethod]
    public void ASwipeLetGoBeforeItsImagesCameStillTurns() => OneThread.Run(async () =>
    {
        var s = await Ready(fill: false);
        s.Turns.Follow(new SwipeSignal.Start(TurnDirection.Forward));
        s.Turns.Follow(new SwipeSignal.Move(400));
        s.Turns.Follow(new SwipeSignal.Release(0));
        await s.Cache.RefreshAsync(s.Book.CurrentLocation!);
        await Quiet(s);
        Assert.AreEqual(6, s.Book.Index);
        Assert.AreEqual("begin Forward", s.Curl.Log[0], "it plays the whole curl once the images come");
    });

    [TestMethod]
    public void AJumpWaitsForTheTurnsBeforeIt() => OneThread.Run(async () =>
    {
        var s = await Ready();
        s.Turns.Turn(TurnDirection.Forward);
        s.Turns.Turn(TurnDirection.Forward);
        var landed = await s.Turns.JumpAsync(() => s.Book.MoveTo(15));
        Assert.AreEqual("spread15", landed?.Cfi);
        s.Turns.Turn(TurnDirection.Forward);
        await Quiet(s);
        Assert.AreEqual(16, s.Book.Index, "a turn after the jump turns from where it landed");
    });

    [TestMethod]
    public void ALinkTakesTheCurlOffAndTurnsGoOnFromWhereItLanded() => OneThread.Run(async () =>
    {
        var s = await Ready();
        await s.Book.FollowLink(12);
        await s.Cache.NeighboursReadyAsync();
        s.Turns.Turn(TurnDirection.Forward);
        var pieces = (CurlPieces<Pic>.SpreadPieces)s.Curl.Pieces!;
        Assert.AreEqual(new Pic(12), pieces.Front.Spread);
        await Quiet(s);
        Assert.AreEqual(13, s.Book.Index);
    });

    [TestMethod]
    public void OnePageAcrossTurnsTheWholePage() => OneThread.Run(async () =>
    {
        var s = await Ready();
        s.Book.Columns = 1;
        s.Turns.Turn(TurnDirection.Backward);
        Assert.AreEqual(new CurlPieces<Pic>.PagePieces(new Pic(4), new Pic(5)), s.Curl.Pieces);
        await Quiet(s);
    });
}
