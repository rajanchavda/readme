using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Readme.App.Reader.Curl;
using Readme.Core.Curl;
using Readme.Core.Model;
using Readme.Core.Reader;

namespace Readme.App.Reader;

/// <summary>
/// The page curl (phase 7): presses, edge clicks and touchpad swipes turn the book through the turn
/// coordinator, which plays the curl from the spread cache's pictures over the book and moves the
/// book beneath it, as on Mac.
/// </summary>
public sealed partial class ReaderView
{
    readonly BookWebView _offscreenBook = new();
    OffscreenSpreads _offscreen = null!;
    VisibleSpreads _visible = null!;
    SpreadCache<SpreadImage> _cache = null!;
    readonly CurlView _curl = new();
    TurnCoordinator<SpreadImage> _turns = null!;
    readonly WheelSwipes _wheel = new();
    readonly System.Diagnostics.Stopwatch _wheelClock = System.Diagnostics.Stopwatch.StartNew();
    DispatcherQueueTimer? _wheelTimer;

    void BuildCurl()
    {
        // Behind everything on the desk, invisible but painting, as the spike found a hidden view must be.
        _offscreenBook.Control.Opacity = 0;
        _offscreenBook.Control.IsHitTestVisible = false;
        _offscreenBook.Control.IsTabStop = false;
        _desk.Children.Insert(0, _offscreenBook.Control);
        // Over the book and its last-spread picture, under the spine's shadow, which falls on the
        // pages beneath the curl and on the flat of the turning page as it does on the book.
        _desk.Children.Insert(_desk.Children.IndexOf(_spineLeft), _curl.Element);

        _offscreen = new OffscreenSpreads(_offscreenBook);
        _visible = new VisibleSpreads(_book, SpreadLook);
        _cache = new SpreadCache<SpreadImage>(_visible, _offscreen);
        _turns = new TurnCoordinator<SpreadImage>(_visible, _cache, _curl, () => !AnimationsOn);
        _turns.Moving += _ =>
        {
            if (_turnsInFlight++ == 0) TurnBegan();
        };
        _turns.Settled += () =>
        {
            _turnsInFlight = 0;
            TurnLanded();
        };
        _book.Wheel += Wheeled;
    }

    /// <summary>Everything that changes how a spread looks, as the reader's book shows it now.</summary>
    SpreadLayout SpreadLook() => new(_book.File, _book.Control.Width, _book.Control.Height, Scale, _book.Css, _book.Columns,
        _book.ColumnWidth, string.Join("\n", _book.HighlightCfis), _book.HighlightColor);

    /// <summary>The pictures for where the book is now, after it opens or its look changes.</summary>
    void RefreshSpreads()
    {
        if (!_book.IsOpen || _book.CurrentLocation is not { } here || _isOpening) return;
        _curl.PageColor = ToColor(ReadingCss.Colors(Theme).Page);
        _ = _cache.RefreshAsync(here);
    }

    static Windows.UI.Color ToColor(Rgba color) => Windows.UI.Color.FromArgb((byte)Math.Round(color.A * 255), color.R, color.G, color.B);

    void PlaceCurl(Box frame)
    {
        _curl.Place(frame.X, frame.Y, frame.Width, frame.Height);
        Microsoft.UI.Xaml.Controls.Canvas.SetLeft(_offscreenBook.Control, frame.X);
        Microsoft.UI.Xaml.Controls.Canvas.SetTop(_offscreenBook.Control, frame.Y);
    }

    void CloseCurl()
    {
        _wheel.Abandon();
        _curl.End();
        _cache.Clear();
        _offscreen.Unload();
    }

    /// <summary>
    /// A touchpad's two-finger swipe across the page holds the curl under the fingers. A mouse wheel
    /// does nothing, as on Mac. Windows sends no beginning or end, so a pause in the events ends it.
    /// </summary>
    void Wheeled(double deltaX, double deltaY)
    {
        if (_isCovered || !_book.IsOpen) return;
        foreach (var signal in _wheel.Wheel(deltaX, deltaY, _wheelClock.Elapsed.TotalSeconds)) Follow(signal);
        if (_wheelTimer == null)
        {
            _wheelTimer = _root.DispatcherQueue.CreateTimer();
            _wheelTimer.Interval = TimeSpan.FromMilliseconds(30);
            _wheelTimer.Tick += (_, _) =>
            {
                foreach (var signal in _wheel.Tick(_wheelClock.Elapsed.TotalSeconds)) Follow(signal);
                if (!_wheel.IsActive) _wheelTimer?.Stop();
            };
        }
        if (!_wheelTimer.IsRunning) _wheelTimer.Start();
    }

    void Follow(SwipeSignal signal)
    {
        if (signal is SwipeSignal.Start)
        {
            _places.Turned();
            HideBar();
        }
        _turns.Follow(signal);
    }

    /// <summary>For the self-checks: the curl, the cache and the fingers.</summary>
    internal CurlView CurlForChecks => _curl;
    internal SpreadCache<SpreadImage> SpreadsForChecks => _cache;
    internal TurnCoordinator<SpreadImage> TurnsForChecks => _turns;
    internal void WheelForChecks(double deltaX, double deltaY) => Wheeled(deltaX, deltaY);
}
