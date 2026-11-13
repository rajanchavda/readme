using System.Diagnostics;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Readme.Core.Library;
using Readme.Core.Model;
using Readme.Core.Reader;
using Readme.Core.Storage;
using Windows.UI.ViewManagement;

namespace Readme.App.Reader;

/// <summary>
/// The reading window's content (the reading part of ReaderWindowController.swift): the desk, the book
/// on it laid out by <see cref="BookFrame"/>, the spine's shadow, the progress hairline, and everything
/// that turns, jumps and restyles the book while keeping the reader's place.
/// </summary>
public sealed partial class ReaderView
{
    static readonly TimeSpan Motion = TimeSpan.FromMilliseconds(200);
    /// <summary>How long the window has to keep its size before a resize counts as over.</summary>
    static readonly TimeSpan ResizeQuiet = TimeSpan.FromMilliseconds(150);
    static readonly TimeSpan NoticeDuration = TimeSpan.FromSeconds(4);
    const double EdgeShare = 0.2;

    readonly LibraryStore _library;
    readonly PlaceWriter _writer;
    readonly UISettings _system = new();
    readonly BookWebView _book = new();
    readonly Grid _root = new();
    readonly Canvas _desk = new();
    readonly Border _bookHost = new();
    readonly Rectangle _spineLeft = new() { IsHitTestVisible = false };
    readonly Rectangle _spineRight = new() { IsHitTestVisible = false };
    readonly Border _edgeBack = new() { Background = new SolidColorBrush(Colors.Transparent) };
    readonly Border _edgeForward = new() { Background = new SolidColorBrush(Colors.Transparent) };
    readonly Image _cover = new() { IsHitTestVisible = false, Stretch = Stretch.Fill, Visibility = Visibility.Collapsed };
    /// <summary>The last spread a book was left on, shown under its page until the page is ready.</summary>
    readonly Image _placeholder = new() { IsHitTestVisible = false, Stretch = Stretch.Fill, Visibility = Visibility.Collapsed };
    readonly LastSpreadCache _spreads;
    static readonly TimeSpan SpreadInterval = TimeSpan.FromSeconds(1);
    Task? _spreadMemory;
    bool _spreadWanted;
    DateTime _lastSpreadAttempt = DateTime.MinValue;
    readonly Rectangle _progress = new() { Height = 1, IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Left };
    readonly TextBlock _notice = new() { Opacity = 0, IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 10), FontSize = 13 };

    ReaderSettings _settings;
    BookFrame _layout;
    bool _isFullscreen;
    readonly PlaceKeeper _places = new();
    int _openGeneration;
    bool _isOpening;
    Task? _restyling;
    bool _restyleWanted;
    bool _restyleAnimated;
    PlaceKeeper.Capture? _restyleCapture;
    CancellationTokenSource? _resizeSettling;
    bool _isResizeOwnChange;
    bool _isCovered;
    int _turnsInFlight;
    Task _turning = Task.CompletedTask;
    CancellationTokenSource? _noticeFading;

    /// <summary>The library book open, once it's opened.</summary>
    public Book? Record { get; private set; }
    public string? BookId { get; private set; }
    public UIElement Root => _root;
    public ReaderSettings Settings => _settings;
    public bool IsFullscreen => _isFullscreen;
    public ReaderLocation? Location => _book.IsOpen ? _book.CurrentLocation : null;
    internal BookWebView Book => _book;

    /// <summary>Where the reader is in a library book: when it has opened, and at each place kept.</summary>
    public event Action<string, ReaderLocation>? Read;
    public event Action<Book, string>? OpenFailed;
    public event Action<ReaderCommand>? CommandRequested;
    /// <summary>A key the reader doesn't use, for the window: Ctrl+O, say.</summary>
    public event Action<PageKey>? UnhandledKey;
    public event Action<string>? TitleChanged;
    /// <summary>Takes keys before the reader does, answering whether it used them; null leaves them to the reader.</summary>
    public Func<PageKey, bool?>? Intercept { get; set; }

    public ReaderView(LibraryStore library, LastSpreadCache spreads, ReaderSettings settings)
    {
        _library = library;
        _spreads = spreads;
        _writer = new PlaceWriter(library.Positions);
        _settings = settings;
        _layout = new BookFrame(1048, 620, settings, false);

        _bookHost.Child = _book.Control;
        _book.Control.Opacity = 0;
        _desk.Children.Add(_placeholder);
        _desk.Children.Add(_bookHost);
        _desk.Children.Add(_cover);
        _desk.Children.Add(_spineLeft);
        _desk.Children.Add(_spineRight);
        _desk.Children.Add(_edgeBack);
        _desk.Children.Add(_edgeForward);
        _root.Children.Add(_desk);
        _root.Children.Add(_progress);
        _root.Children.Add(_notice);
        BuildTools();

        _root.SizeChanged += (_, _) => Resized();
        _edgeBack.PointerPressed += (_, e) => EdgeClicked(TurnDirection.Backward, e);
        _edgeForward.PointerPressed += (_, e) => EdgeClicked(TurnDirection.Forward, e);
        _book.Relocated += location =>
        {
            Show(location);
            if (!IsLayingOut) Keep(location);
        };
        // A link is a jump the window didn't make, so it counts as one: when followed and when landed.
        _book.LinkFollowed += _ => _places.Turned();
        _book.KeyPressed += key => HandleKey(key);
        // A mouse wheel does nothing, as on Mac; touchpad swipes come with the curl (phase 7).
        _book.Wheel += (_, _) => { };
        // Auto follows Windows' light or dark mode as it changes.
        _system.ColorValuesChanged += (_, _) => _root.DispatcherQueue.TryEnqueue(() =>
        {
            if (_settings.Theme == ThemeChoice.Auto) Restyle(animated: true);
        });
        ApplyColors();
    }

    static bool SystemIsDark(UISettings system)
    {
        var background = system.GetColorValue(UIColorType.Background);
        return background.R + background.G + background.B < 3 * 128;
    }

    public Theme Theme => _settings.ResolvedTheme(SystemIsDark(_system));

    /// <summary>Windows' "Animation effects" setting; off means no slide, fade or crossfade.</summary>
    bool AnimationsOn => _system.AnimationsEnabled;

    string Css() => ReadingCss.Css(_settings, Theme, _isFullscreen);

    /// <summary>While the book opens or its layout changes, the pages it lands on aren't the reader's moves.</summary>
    bool IsLayingOut => _isOpening || _restyling != null || _places.IsChangingLayout;

    // MARK: Opening

    public async Task<bool> OpenAsync(Book record, string? cfi = null)
    {
        if (_book.IsOpen) await KeepPlaceAsync();
        // Taken off the shelf while the book before it was being put away.
        if (_library.Book(record.Id) == null) return false;
        await ShowLastSpreadAsync(record);
        return await OpenFileAsync(_library.FilePath(record), record, cfi);
    }

    /// <summary>Lets go of the book, as when it's taken off the shelf. Nothing more is kept for it.</summary>
    public void CloseBook()
    {
        ++_openGeneration;
        _isOpening = false;
        _spreadWanted = false;
        _book.Unload();
        ResetTools();
        SleepToolbar();
        Record = null;
        BookId = null;
        _book.Control.Opacity = 0;
        HidePlaceholder();
        PlaceViews();
        TitleChanged?.Invoke("");
    }

    // MARK: The last spread

    double Scale => _root.XamlRoot?.RasterizationScale ?? 1;

    /// <summary>
    /// Returns once the view is in the window and laid out, so its scale and size are the real ones:
    /// at launch it isn't yet, and a picture matched against a scale of 1 never matches.
    /// </summary>
    async Task LoadedAsync()
    {
        if (_root.XamlRoot != null && _root.ActualWidth > 0) return;
        var loaded = new TaskCompletionSource();
        void Done(object sender, SizeChangedEventArgs e)
        {
            if (_root.XamlRoot != null && e.NewSize.Width > 0) loaded.TrySetResult();
        }
        _root.SizeChanged += Done;
        try { await Task.WhenAny(loaded.Task, Task.Delay(2000)); }
        finally { _root.SizeChanged -= Done; }
    }

    /// <summary>The look a spread has in the window now, to match a kept picture against.</summary>
    string SpreadSignature() => LastSpreadCache.Signature(
        _layout.Frame.Width, _layout.Frame.Height, Scale, _layout.Columns, _layout.ColumnWidth, Css());

    /// <summary>Shows the picture of the spread the book was left on, if one was kept in the look the window has now.</summary>
    async Task ShowLastSpreadAsync(Book record)
    {
        HidePlaceholder();
        await LoadedAsync();
        _layout = new BookFrame(_root.ActualWidth > 0 ? _root.ActualWidth : 1048, _root.ActualHeight > 0 ? _root.ActualHeight : 620, _settings, _isFullscreen);
        var wanted = SpreadSignature();
        Log.Write($"last spread wanted: {wanted[..Math.Min(40, wanted.Length)]}");
        if (_spreads.Image(record.Id, wanted) is not { } png) return;
        var image = new BitmapImage();
        using (var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream())
        {
            await stream.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(png));
            stream.Seek(0);
            await image.SetSourceAsync(stream);
        }
        _placeholder.Source = image;
        _placeholder.Visibility = Visibility.Visible;
        ApplyColors();
        PlaceViews();
        Log.Write($"showing the last spread of {record.Id[..8]}");
    }

    void HidePlaceholder()
    {
        _placeholder.Visibility = Visibility.Collapsed;
        _placeholder.Source = null;
    }

    public bool IsShowingLastSpread => _placeholder.Visibility == Visibility.Visible;

    /// <summary>Keeps a picture of the spread the reader's on, at most once a second, and soon after the last place asked for.</summary>
    void RememberSpread()
    {
        if (BookId == null) return;
        _spreadWanted = true;
        if (_spreadMemory != null) return;
        var wait = SpreadInterval - (DateTime.UtcNow - _lastSpreadAttempt);
        _spreadMemory = Remember(wait > TimeSpan.Zero ? wait : TimeSpan.Zero);
        async Task Remember(TimeSpan delay)
        {
            await Task.Yield();
            if (delay > TimeSpan.Zero) await Task.Delay(delay);
            await WriteSpreadAsync();
            _spreadMemory = null;
            if (_spreadWanted) RememberSpread();
        }
    }

    async Task WriteSpreadAsync()
    {
        _spreadWanted = false;
        _lastSpreadAttempt = DateTime.UtcNow;
        // Only a settled page, in the look it's kept under.
        if (BookId is not { } id || !_book.IsOpen || _isCovered || IsLayingOut || _book.Control.Opacity < 1) return;
        var signature = LastSpreadCache.Signature(_layout.Frame.Width, _layout.Frame.Height, Scale, _book.Columns, _book.ColumnWidth, _book.Css);
        using var png = await _book.SnapshotAsync();
        if (png == null || BookId != id) return;
        Log.Write($"last spread kept: {signature[..Math.Min(40, signature.Length)]}");
        var bytes = new byte[png.Size];
        using (var reader = new Windows.Storage.Streams.DataReader(png))
        {
            await reader.LoadAsync((uint)png.Size);
            reader.ReadBytes(bytes);
        }
        await Task.Run(() => _spreads.Save(bytes, signature, id));
    }

    /// <summary>Returns once the place is written, then the picture of its spread.</summary>
    public async Task KeepPlaceAsync()
    {
        await PlacesKeptAsync();
        if (_spreadMemory is { } memory) await memory;
        await WriteSpreadAsync();
    }

    async Task<bool> OpenFileAsync(string file, Book? record, string? cfi)
    {
        var generation = ++_openGeneration;
        bool Current() => generation == _openGeneration;
        _isOpening = true;
        Record = record;
        BookId = null;
        _places.MovedTo(null);
        _book.Control.Opacity = 0;
        HideNotice();
        ResetTools();
        _layout = new BookFrame(_root.ActualWidth > 0 ? _root.ActualWidth : 1048, _root.ActualHeight > 0 ? _root.ActualHeight : 620, _settings, _isFullscreen);
        PlaceViews();
        ApplyColors();
        try
        {
            await _book.InitializeAsync();
            await _book.ApplyStylesAsync(Css(), _layout.Columns, _layout.ColumnWidth);
            var bookId = record?.Id ?? await Core.Storage.BookId.OfAsync(file);
            var saved = _library.Positions.Location(bookId);
            var start = cfi ?? saved?.Cfi;
            // How far through the book the place was, for when the place itself is gone.
            var share = saved != null && saved.Cfi == start ? saved.Fraction : (double?)null;
            var location = await _book.OpenAsync(file, start);
            if (!Current()) return false;
            BookId = bookId;
            await LoadMarksAsync(bookId, Current);
            if (!Current()) return false;
            // The book opens on the page that holds its place, which starts before it. A place it
            // couldn't find is replaced by where it opened, or by the same share of the way through.
            var place = await _book.PlaceAsync() ?? location.Cfi;
            if (!Current()) return false;
            var isLost = start != null && place != start;
            if (isLost && share > 0 && await _book.GoToFractionAsync(share.Value) is { } found)
            {
                if (!Current()) return false;
                place = await _book.PlaceAsync() ?? found.Cfi;
            }
            _places.MovedTo(place);
            var opened = _places.Take(place);
            TitleChanged?.Invoke(record?.Title ?? System.IO.Path.GetFileNameWithoutExtension(file));
            Show(location);
            await _book.SetSlideAsync(AnimationsOn);
            await _book.SettleAsync();
            if (!Current()) return false;
            _isOpening = false;
            // The spine shows now the book is open, even with no last spread shown before it.
            PlaceViews();
            // A page turned as the book settled is where the reader now is.
            if ((isLost || _places.HasTurnedSince(opened)) && _book.CurrentLocation is { } here) Keep(here);
            else if (_book.CurrentLocation is { } now) Read?.Invoke(bookId, now);
            // Over the last spread, if that's showing, so the page never dims on its way in.
            Fade(_book.Control, 1, () =>
            {
                if (Current()) HidePlaceholder();
                RememberSpread();
            });
            _book.Control.Focus(FocusState.Programmatic);
            UpdateRibbon(animated: false);
            MentionMarker();
            return true;
        }
        catch (OperationCanceledException)
        {
            return false;
        }
        catch (Exception error) when (error is BookWebViewException or TimeoutException or IOException or UnauthorizedAccessException)
        {
            Debug.WriteLine($"Opening failed: {error}");
            if (!Current()) return false;
            _isOpening = false;
            Record = null;
            HidePlaceholder();
            if (record != null) OpenFailed?.Invoke(record, error.Message);
            return false;
        }
    }

    // MARK: Keeping the place

    /// <summary>
    /// The reader is at <paramref name="location"/> now: layout changes go back to it, and it's saved
    /// under the book's id.
    /// </summary>
    void Keep(ReaderLocation location)
    {
        _places.MovedTo(location.Cfi);
        if (BookId is not { } id) return;
        _writer.Save(location, id);
        Read?.Invoke(id, location);
        RememberSpread();
    }

    /// <summary>Returns once the turns and restyles under way are over and the place is written.</summary>
    public async Task PlacesKeptAsync()
    {
        try { await _turning; } catch (Exception) { }
        if (_restyling is { } restyling) await restyling;
        await _writer.WrittenAsync();
    }

    void Show(ReaderLocation location)
    {
        PlaceProgress(location);
        if (_turnsInFlight == 0) UpdateRibbon(animated: true);
        if (_toolbar.IsAwake) RefreshToolbar();
    }

    // MARK: Commands and keys

    /// <summary>What a key does, from the page or from the window. Answers whether it was used.</summary>
    public bool HandleKey(PageKey key)
    {
        // While the shelf covers the book, its keys are the shelf's, not page turns underneath.
        if (Intercept?.Invoke(key) is { } handled) return handled;
        var isEscape = key.Key == "Escape" && key.Modifiers == Modifiers.None;
        // Esc puts the shortcuts away, and any other key does what it does once they're gone.
        if (_shortcutsShown && isEscape)
        {
            CloseShortcuts();
            return true;
        }
        var action = KeyAction.Of(key.Key, key.Modifiers, key.IsRepeat, _isFullscreen, isTyping: false,
            isInContents: _contentsShown || _highlightsShown);
        if (action == null && isEscape && _bar.IsShown)
        {
            HideBar();
            _ = _book.ClearSelectionAsync();
            return true;
        }
        if (_shortcutsShown && action is not (KeyAction.Command { Value: ReaderCommand.ShowShortcuts } or KeyAction.Ignore)) CloseShortcuts();
        switch (action)
        {
            case KeyAction.Command { Value: var command }:
                Perform(command);
                return true;
            case KeyAction.Turn { Direction: var direction, IsRepeat: var repeat }:
                if (!_book.IsOpen) return false;
                Turn(direction, repeat);
                return true;
            case KeyAction.LeaveFullscreen:
                CommandRequested?.Invoke(ReaderCommand.ToggleFullscreen);
                return true;
            case KeyAction.CloseContents:
                CloseContents();
                CloseHighlights();
                return true;
            case KeyAction.Ignore:
                return true;
            default:
                UnhandledKey?.Invoke(key);
                return false;
        }
    }

    public void Perform(ReaderCommand command)
    {
        if (PerformTool(command)) return;
        switch (command)
        {
            case ReaderCommand.BiggerText or ReaderCommand.SmallerText:
                Change(_settings with { FontSize = ReaderCommands.FontSizeAfter(command, _settings.FontSize) });
                break;
            case ReaderCommand.GoToStart:
                Jump(book => book.GoToStartAsync());
                break;
            case ReaderCommand.GoToEnd:
                Jump(book => book.GoToEndAsync());
                break;
            default:
                // Full screen and the library are the window's.
                CommandRequested?.Invoke(command);
                break;
        }
    }

    /// <summary>A click on a page's edge follows a link there, and turns the page only if there's none.</summary>
    async void EdgeClicked(TurnDirection direction, PointerRoutedEventArgs e)
    {
        if (_isCovered || !_book.IsOpen) return;
        var point = e.GetCurrentPoint(_book.Control).Position;
        e.Handled = true;
        if (await _book.FollowLinkAtAsync(point.X, point.Y)) return;
        Turn(direction);
    }

    /// <summary>
    /// Turns a page. A turn takes about 450 ms in the page (the slide, then settling), so presses
    /// faster than that would queue without end and the book would trail behind the reader, its
    /// places kept long after. So one turn may wait behind the one under way, and presses beyond that
    /// are dropped; a held key's repeats are dropped while any turn is on its way, so letting go
    /// stops the book at once. Phase 7's rapid-turn handling replaces this with the curl's own.
    /// </summary>
    public void Turn(TurnDirection direction, bool isRepeat = false)
    {
        const int MostInFlight = 2;
        if (_isCovered || !_book.IsOpen) return;
        if (isRepeat ? _turnsInFlight > 0 : _turnsInFlight >= MostInFlight) return;
        _places.Turned();
        HideBar();
        _turnsInFlight++;
        TurnBegan();
        var turn = direction == TurnDirection.Forward ? _book.NextAsync() : _book.PreviousAsync();
        _turning = Finish(turn);
        async Task Finish(Task<ReaderLocation?> moving)
        {
            try { await moving; }
            finally
            {
                _turnsInFlight--;
                TurnLanded();
            }
        }
    }

    /// <summary>
    /// Takes the book somewhere new. A jump counts as a turn when asked for and again when it lands,
    /// so a restyle won't take the reader back to a place captured before it landed.
    /// </summary>
    void Jump(Func<BookWebView, Task<ReaderLocation?>> go)
    {
        if (_isCovered || !_book.IsOpen) return;
        ClosePanelsForJump();
        HideBar();
        _places.Turned();
        var before = _turning;
        _turnsInFlight++;
        TurnBegan();
        _turning = Land();
        async Task Land()
        {
            try
            {
                // After the turns before it have landed, so it's the last word.
                try { await before; } catch (Exception) { }
                await go(_book);
                _places.Turned();
            }
            finally
            {
                _turnsInFlight--;
                TurnLanded();
            }
        }
    }

    // MARK: Settings and layout

    public void Change(ReaderSettings changed)
    {
        if (changed == _settings) return;
        _settings = changed;
        _settings.Save(AppPaths.Settings);
        // As on Mac, the toolbar goes, so the reader sees the page in its new look.
        SleepToolbar();
        Restyle(animated: true);
    }

    string? Place => _places.PlaceShowing(_book.CurrentLocation?.Cfi);

    /// <summary>
    /// Lays the book out for the settings, theme and window as they are now. Animated crossfades from
    /// the old look. Restyles run one at a time; those asked for meanwhile fold into the next.
    /// </summary>
    void Restyle(bool animated, PlaceKeeper.Capture? capture = null)
    {
        _restyleWanted = true;
        _restyleAnimated |= animated;
        _restyleCapture ??= capture ?? _places.Take(Place);
        if (_restyling != null) return;
        _restyling = Run();
        async Task Run()
        {
            // Never finishes before it's stored: with nothing to wait for, it would clear
            // _restyling first and then be stored as finished for good, stopping every later restyle.
            await Task.Yield();
            while (_restyleWanted)
            {
                _restyleWanted = false;
                var wantsAnimation = _restyleAnimated;
                var wanted = _restyleCapture;
                _restyleAnimated = false;
                _restyleCapture = null;
                try { await ApplyLayoutAsync(wantsAnimation, wanted); }
                catch (Exception error) when (error is BookWebViewException or TimeoutException) { Debug.WriteLine(error); }
            }
            _restyling = null;
        }
    }

    async Task ApplyLayoutAsync(bool animated, PlaceKeeper.Capture? capture)
    {
        _layout = new BookFrame(_root.ActualWidth, _root.ActualHeight, _settings, _isFullscreen);
        var css = Css();
        if (!_book.IsOpen)
        {
            PlaceViews();
            ApplyColors();
            await _book.ApplyStylesAsync(css, _layout.Columns, _layout.ColumnWidth);
            return;
        }
        var restyles = _book.Css != css || _book.Columns != _layout.Columns || _book.ColumnWidth != _layout.ColumnWidth;
        Log.Write($"layout {_layout.Frame} columns {_layout.Columns} restyles={restyles} animated={animated}");
        if (restyles && animated && AnimationsOn) await CoverAsync();
        Log.Write("covered");
        PlaceViews();
        if (restyles) await _book.ApplyStylesAsync(css, _layout.Columns, _layout.ColumnWidth);
        Log.Write("styled");
        // Read after the restyle, so a page turned meanwhile is kept.
        if (_places.Target(capture) is { } cfi && _book.CurrentLocation?.Cfi != cfi) await _book.GoToCfiAsync(cfi);
        if (restyles && _isCovered) await _book.SettleAsync();
        Log.Write("settled");
        ApplyColors();
        Uncover();
        if (_book.CurrentLocation is { } here)
        {
            Show(here);
            // A page turned while the layout changed is where the reader now is.
            if (_places.HasTurnedSince(capture)) Keep(here);
            else RememberSpread();
        }
    }

    /// <summary>Lays the old look over the book, so the new one can arrive behind it and fade in.</summary>
    async Task CoverAsync()
    {
        using var png = await _book.SnapshotAsync();
        if (png == null) return;
        var image = new BitmapImage();
        await image.SetSourceAsync(png);
        _cover.Source = image;
        _cover.Opacity = 1;
        _cover.Visibility = Visibility.Visible;
        _isCovered = true;
    }

    void Uncover()
    {
        if (!_isCovered) return;
        _isCovered = false;
        Fade(_cover, 0, () =>
        {
            if (_isCovered) return;
            _cover.Visibility = Visibility.Collapsed;
            _cover.Source = null;
        });
    }

    /// <summary>Puts the book, its spine and edges where the layout says.</summary>
    void PlaceViews()
    {
        var frame = _layout.Frame;
        Put(_bookHost, frame);
        Put(_cover, frame);
        Put(_placeholder, frame);
        if (Math.Abs(_book.Control.Width - frame.Width) > 0.5) _ = ResizedLaterAsync(frame.Width);
        _book.Control.Width = frame.Width;
        _book.Control.Height = frame.Height;
        var middle = frame.X + frame.Width / 2;
        Put(_spineLeft, new Box(middle - SpineShadow.Reach, frame.Y, SpineShadow.Reach, frame.Height));
        Put(_spineRight, new Box(middle, frame.Y, SpineShadow.Reach, frame.Height));
        var spineShown = _layout.Columns == 2 && (_book.IsOpen || IsShowingLastSpread) ? Visibility.Visible : Visibility.Collapsed;
        _spineLeft.Visibility = _spineRight.Visibility = spineShown;
        PlaceTools();
        var edge = frame.Width * EdgeShare;
        Put(_edgeBack, new Box(frame.X, frame.Y, edge, frame.Height));
        Put(_edgeForward, new Box(frame.Right - edge, frame.Y, edge, frame.Height));
        if (_book.CurrentLocation is { } location && _book.IsOpen) PlaceProgress(location);
        else _progress.Width = 0;
    }

    /// <summary>
    /// foliate caps columns by the width it's given; the bridge is told the new width once the view
    /// has it, and lays out again holding the place.
    /// </summary>
    async Task ResizedLaterAsync(double width)
    {
        await Task.Delay(50);
        await _book.ResizedAsync(width);
    }

    static void Put(FrameworkElement element, Box box)
    {
        Canvas.SetLeft(element, box.X);
        Canvas.SetTop(element, box.Y);
        element.Width = Math.Max(0, box.Width);
        element.Height = Math.Max(0, box.Height);
    }

    /// <summary>The hairline along the bottom of the desk, full at the end of the book.</summary>
    void PlaceProgress(ReaderLocation location)
    {
        var share = location.IsAtEnd ? 1 : Math.Clamp(location.Fraction, 0, 1);
        _progress.Width = Math.Round(_root.ActualWidth * share);
    }

    /// <summary>The desk, spine and hairline take the theme's colours.</summary>
    void ApplyColors()
    {
        var colors = ReadingCss.Colors(Theme);
        _root.Background = Brush(colors.Desk);
        _progress.Fill = Brush(colors.Soft);
        _notice.Foreground = Brush(colors.Page.WithAlpha(0.75));
        _spineLeft.Fill = SpineBrush(colors.Spine, towardsSpine: true);
        _spineRight.Fill = SpineBrush(colors.Spine, towardsSpine: false);
        // The desk is dark in every theme, so the window's own controls are drawn for a dark ground.
        _root.RequestedTheme = ElementTheme.Dark;
        ApplyToolColors();
    }

    static SolidColorBrush Brush(Rgba color) => new(Windows.UI.Color.FromArgb((byte)Math.Round(color.A * 255), color.R, color.G, color.B));

    static LinearGradientBrush SpineBrush(Rgba spine, bool towardsSpine)
    {
        var brush = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(towardsSpine ? 0 : 1, 0.5),
            EndPoint = new Windows.Foundation.Point(towardsSpine ? 1 : 0, 0.5),
        };
        foreach (var (location, share) in SpineShadow.Falloff)
            brush.GradientStops.Add(new GradientStop { Offset = location, Color = Windows.UI.Color.FromArgb((byte)Math.Round(spine.A * share * 255), spine.R, spine.G, spine.B) });
        return brush;
    }

    // MARK: Window

    /// <summary>
    /// A resize is a layout change, and the book's landings during it aren't the reader's moves. A
    /// change in the number of pages can't wait, or two columns would squeeze onto one page; otherwise
    /// the restyle waits until the window has kept its size a moment, then goes back to where it began.
    /// </summary>
    void Resized()
    {
        if (_root.ActualWidth <= 0 || _root.ActualHeight <= 0) return;
        if (!_places.IsChangingLayout)
        {
            _places.BeginLayoutChange(Place);
            _isResizeOwnChange = true;
        }
        var wanted = new BookFrame(_root.ActualWidth, _root.ActualHeight, _settings, _isFullscreen);
        if (wanted.Columns != _layout.Columns) Restyle(animated: false, _places.LayoutChangeCapture);
        else
        {
            _layout = wanted;
            PlaceViews();
        }
        SettleResize();
    }

    void SettleResize()
    {
        _resizeSettling?.Cancel();
        var settling = _resizeSettling = new CancellationTokenSource();
        _ = Settle();
        async Task Settle()
        {
            try { await Task.Delay(ResizeQuiet, settling.Token); }
            catch (TaskCanceledException) { return; }
            if (!_isResizeOwnChange) return;
            _isResizeOwnChange = false;
            if (_places.IsChangingLayout) Restyle(animated: false, _places.EndLayoutChange());
        }
    }

    /// <summary>Full screen has larger text and a wider book; its change is one layout change.</summary>
    public void SetFullscreen(bool on)
    {
        if (on == _isFullscreen) return;
        if (!_places.IsChangingLayout) _places.BeginLayoutChange(Place);
        _isResizeOwnChange = true;
        _isFullscreen = on;
        if (!on) SetAwake(_toolbar.IsAwake);
        RefreshToolbar();
        SettleResize();
    }

    // MARK: Notices

    public void ShowNotice(string text)
    {
        _noticeFading?.Cancel();
        _notice.Text = text;
        Fade(_notice, 1);
        var fading = _noticeFading = new CancellationTokenSource();
        _ = Later();
        async Task Later()
        {
            try { await Task.Delay(NoticeDuration, fading.Token); }
            catch (TaskCanceledException) { return; }
            Fade(_notice, 0);
        }
    }

    void HideNotice()
    {
        _noticeFading?.Cancel();
        _notice.Opacity = 0;
    }

    /// <summary>Fades an element's opacity with the app's 200 ms ease-out, or at once with animations off.</summary>
    void Fade(UIElement element, double to, Action? done = null)
    {
        if (!AnimationsOn)
        {
            element.Opacity = to;
            done?.Invoke();
            return;
        }
        var animation = new DoubleAnimation
        {
            To = to,
            Duration = new Duration(Motion),
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
        };
        Storyboard.SetTarget(animation, element);
        Storyboard.SetTargetProperty(animation, "Opacity");
        var storyboard = new Storyboard();
        storyboard.Children.Add(animation);
        storyboard.Completed += (_, _) =>
        {
            element.Opacity = to;
            done?.Invoke();
        };
        storyboard.Begin();
    }
}
