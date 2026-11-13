using Readme.Core.Reader;

namespace Readme.Core.Curl;

/// <summary>
/// Geometry of the page curl (CurlPose.swift), matching the maths in <c>docs/mockups/open-book-v2.html</c>.
/// The turning page is a chain of <see cref="Strips"/> hinged strips; <see cref="Angles"/> gives each
/// strip's cumulative rotation in degrees.
/// </summary>
public static class CurlPose
{
    public const double Duration = 0.52;
    public const int Strips = 28;
    public const double Bend = 34.0;
    /// <summary>The share of a turn over which the last half degree to flat is closed (CurlView.flatteningShare).</summary>
    public const double FlatteningShare = 0.05;
    /// <summary>A single page fades out over this last share of its turn (CurlView.pageFadeShare).</summary>
    public const double PageFadeShare = 0.3;
    public const double Perspective = 2400;
    public const double CrossfadeDuration = 0.2;

    /// <summary>Cumulative angle in degrees for each strip at progress <paramref name="t"/> in 0…1.</summary>
    public static double[] Angles(double t, int strips = Strips, double bend = Bend)
    {
        var e = t * t * (3 - 2 * t);
        var b = bend * Math.Sin(2 * Math.PI * t);
        var root = -180 * e + b;
        var d = 2 * b / (strips - 1);
        return Enumerable.Range(0, strips).Select(k => Math.Max(-179.5, Math.Min(0, root - k * d))).ToArray();
    }

    /// <summary>
    /// <see cref="Angles"/>, except that those stop 0.5 degrees short of flat, which would make the
    /// page jump as a backward turn begins and a forward one ends. This closes the gap over the last
    /// <see cref="FlatteningShare"/> of the turn (CurlView.drawnAngles).
    /// </summary>
    public static double[] DrawnAngles(double t)
    {
        var closing = Math.Min(1, Math.Max(0, (t - (1 - FlatteningShare)) / FlatteningShare)) * 0.5;
        return Angles(t).Select(a => Math.Max(-180, a - closing)).ToArray();
    }

    /// <summary>Darkness of the page face for a strip at <paramref name="angle"/> degrees: darkest when edge-on.</summary>
    public static double Shade(double angle) => Math.Abs(Math.Sin(angle * Math.PI / 180)) * 0.16;

    /// <summary>Strength of the cast shadow at progress <paramref name="t"/>, peaking at the midpoint.</summary>
    public static double Cast(double t) => Math.Sin(Math.PI * t);

    /// <summary>How opaque a single turning page is: whole, then fading to nothing over the last <see cref="PageFadeShare"/>.</summary>
    public static double PageOpacity(double t) => t > 1 - PageFadeShare ? Math.Max(0, (1 - t) / PageFadeShare) : 1;

    /// <summary>
    /// Each strip's darkness at its two hinges, where neighbouring strips agree, so the page shades
    /// smoothly rather than in bands: (spine side, outer side) for strip <paramref name="index"/>.
    /// </summary>
    public static (double Near, double Far) HingeShades(double[] angles, int index)
    {
        var angle = angles[index];
        var previous = index == 0 ? angle : angles[index - 1];
        var outer = angles[Math.Min(index + 1, angles.Length - 1)];
        return (Shade((angle + previous) / 2), Shade((angle + outer) / 2));
    }
}

public enum SwipeOutcome { Commit, Cancel }

/// <summary>
/// How far fingers have carried a page, and whether it goes over when they let go (SwipeTracker.swift).
/// Distances and speeds are positive towards turning it; progress runs from 0 where the page lies at
/// the start to 1 where it's gone over.
/// </summary>
public sealed class SwipeTracker(double pageWidth)
{
    /// <summary>A release faster than this, in DIPs per second, decides the turn by its direction.</summary>
    const double FlickSpeed = 600;
    /// <summary>Kept within the page, so fingers that went past an end move the page as soon as they turn back.</summary>
    double _distance;

    public double Progress => pageWidth > 0 ? _distance / pageWidth : 0;

    public void Began() => _distance = 0;

    public double Changed(double deltaX)
    {
        _distance = Math.Min(pageWidth, Math.Max(0, _distance + deltaX));
        return Progress;
    }

    public SwipeOutcome Ended(double velocityX) =>
        velocityX > FlickSpeed ? SwipeOutcome.Commit
        : velocityX < -FlickSpeed ? SwipeOutcome.Cancel
        : Progress >= 0.5 ? SwipeOutcome.Commit : SwipeOutcome.Cancel;
}

/// <summary>What a scroll gesture amounts to for the page. Distances and speeds are positive towards turning it.</summary>
public abstract record SwipeSignal
{
    public sealed record Start(TurnDirection Direction) : SwipeSignal;
    public sealed record Move(double Distance) : SwipeSignal;
    public sealed record Release(double Velocity) : SwipeSignal;
    /// <summary>The gesture stopped without the fingers letting go, so the page should fall back.</summary>
    public sealed record Abandon : SwipeSignal;
}

public enum SwipePhase { Began, Changed, Ended, Cancelled }

/// <summary>
/// Reads one scroll gesture at a time (SwipeGesture in SwipeTracker.swift), deciding early whether it's
/// a swipe across the page and which way, and ignoring it from then on if it isn't. It reads finger
/// travel across the touchpad, positive to the right: fingers going right to left turn forward.
/// </summary>
public sealed class SwipeGesture
{
    /// <summary>Finger travel by which the axis is decided: enough to tell, too little to notice the page hasn't moved.</summary>
    const double DecisionDistance = 8;
    /// <summary>How far back the release speed looks, in seconds.</summary>
    const double SpeedWindow = 0.1;

    enum State { Idle, Deciding, Ignoring, Following }

    State _state = State.Idle;
    double _x, _y;
    TurnDirection _direction;
    readonly List<(double Time, double DeltaX)> _recent = [];

    /// <summary>The events of a gesture, in order, with <paramref name="deltaX"/> as finger travel. Those with no beginning are ignored.</summary>
    public IReadOnlyList<SwipeSignal> Handle(SwipePhase phase, double deltaX, double deltaY, double time)
    {
        switch (phase)
        {
            case SwipePhase.Began:
                var signals = Abandon().ToList();
                _state = State.Deciding;
                _x = _y = 0;
                _recent.Clear();
                signals.AddRange(Travel(deltaX, deltaY, time));
                return signals;
            case SwipePhase.Changed:
                return Travel(deltaX, deltaY, time);
            case SwipePhase.Ended:
                var ended = Travel(deltaX, deltaY, time).ToList();
                if (_state == State.Following) ended.Add(new SwipeSignal.Release(Along(Speed(time))));
                _state = State.Idle;
                return ended;
            default:
                return Abandon();
        }
    }

    /// <summary>Forgets the gesture, whatever more arrives of it.</summary>
    public IReadOnlyList<SwipeSignal> Abandon()
    {
        var was = _state;
        _state = State.Idle;
        return was == State.Following ? [new SwipeSignal.Abandon()] : [];
    }

    public bool IsFollowing => _state == State.Following;

    IReadOnlyList<SwipeSignal> Travel(double deltaX, double deltaY, double time)
    {
        _recent.RemoveAll(r => r.Time < time - SpeedWindow);
        _recent.Add((time, deltaX));
        switch (_state)
        {
            case State.Following:
                return deltaX == 0 ? [] : [new SwipeSignal.Move(Along(deltaX))];
            case State.Deciding:
                _x += deltaX;
                _y += deltaY;
                if (Math.Max(Math.Abs(_x), Math.Abs(_y)) < DecisionDistance) return [];
                if (Math.Abs(_x) <= Math.Abs(_y))
                {
                    _state = State.Ignoring;
                    return [];
                }
                _direction = _x < 0 ? TurnDirection.Forward : TurnDirection.Backward;
                _state = State.Following;
                return [new SwipeSignal.Start(_direction), new SwipeSignal.Move(Along(_x))];
            default:
                return [];
        }
    }

    /// <summary>Between the first and last events kept. The first event's distance was covered before its time, so it doesn't count.</summary>
    double Speed(double time)
    {
        if (_recent.Count == 0 || time <= _recent[0].Time) return 0;
        return _recent.Skip(1).Sum(r => r.DeltaX) / (time - _recent[0].Time);
    }

    double Along(double deltaX) => _direction == TurnDirection.Forward ? -deltaX : deltaX;
}

/// <summary>
/// Windows' wheel events as gestures: they come with no beginning or end, so a gesture begins with
/// the first event after a quiet spell and ends once the events pause. A touchpad's own glide after
/// the fingers lift is part of the gesture, so a flick carries the page on. A mouse wheel's notches,
/// whole steps straight along one axis, are never a swipe: a wheel does nothing, as on Mac.
/// </summary>
public sealed class WheelSwipes
{
    /// <summary>Events closer together than this are one gesture; a pause this long ends it.</summary>
    public const double Pause = 0.12;

    readonly SwipeGesture _gesture = new();
    double? _last;
    bool _isNotches;

    /// <summary>
    /// One wheel event, as the page reports it: <paramref name="deltaX"/> positive scrolls the content
    /// right, which on Windows is the fingers going left.
    /// </summary>
    public IReadOnlyList<SwipeSignal> Wheel(double deltaX, double deltaY, double time)
    {
        var began = _last is not { } last || time - last >= Pause;
        _last = time;
        if (began) _isNotches = IsNotch(deltaX, deltaY);
        if (_isNotches) return began ? _gesture.Abandon() : [];
        return _gesture.Handle(began ? SwipePhase.Began : SwipePhase.Changed, -deltaX, deltaY, time);
    }

    /// <summary>The gesture's end, if the events have paused by <paramref name="time"/>.</summary>
    public IReadOnlyList<SwipeSignal> Tick(double time)
    {
        if (_last is not { } last || time - last < Pause) return [];
        _last = null;
        if (_isNotches) return [];
        // The speed is the fingers' (or the glide's) over the last events, not over the pause after them.
        return _gesture.Handle(SwipePhase.Ended, 0, 0, last);
    }

    /// <summary>Forgets the gesture under way, as when a key press takes over.</summary>
    public IReadOnlyList<SwipeSignal> Abandon()
    {
        _last = null;
        return _gesture.Abandon();
    }

    public bool IsActive => _last != null;

    /// <summary>A mouse wheel's step: straight along one axis, a whole 100 or 120 (or a multiple), as Chromium reports one.</summary>
    public static bool IsNotch(double deltaX, double deltaY)
    {
        if (deltaX != 0 && deltaY != 0) return false;
        var value = Math.Abs(deltaX != 0 ? deltaX : deltaY);
        return value >= 100 && value % 1 == 0 && (value % 120 == 0 || value % 100 == 0);
    }
}
