using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Readme.App.Reader.Tools;
using Readme.Core.Model;
using Readme.Core.Reader;

namespace Readme.App.Reader;

/// <summary>
/// The reading tools (the rest of ReaderWindowController.swift): the toolbar and its waking and
/// sleeping, the contents and highlights sidebars, the go-to-page field, search, the highlight bar,
/// the reading marker and its ribbon, and the shortcuts panel.
/// </summary>
public sealed partial class ReaderView
{
    readonly ReaderToolbar _toolbar = new();
    readonly TocSidebar _contents = new();
    readonly HighlightsSidebar _highlightsPanel = new();
    readonly GoToPageField _pageField = new();
    readonly SearchBox _search = new();
    readonly HighlightBar _bar = new();
    readonly ShortcutsPanel _shortcuts = new();
    readonly Canvas _overlay = new();
    /// <summary>Over the desk while a sidebar is open, so a click beside it closes it and turns no page.</summary>
    readonly Border _sideScrim = Scrim(0);
    readonly Border _searchScrim = Scrim(0.12);
    readonly Border _shortcutsScrim = Scrim(0.2);
    readonly Microsoft.UI.Xaml.Shapes.Path _ribbon = Ribbon();

    readonly IdleTimer _idle = new();
    readonly Stopwatch _clock = Stopwatch.StartNew();
    CancellationTokenSource? _idleCheck;
    bool _isPointerHidden;
    bool _isBehind;

    IReadOnlyList<TocEntry>? _toc;
    Task? _contentsLoading;
    List<Highlight> _bookHighlights = [];
    SelectionInfo? _selection;
    string? _targetedHighlight;
    DateTime? _barShownAt;
    Marker? _bookMarker;
    Task _marking = Task.CompletedTask;
    bool _isRibbonOn;
    string _searchQuery = "";
    SearchOutcome? _searchOutcome;
    int? _searchSelection;
    int _searchGeneration;
    Task? _searching;

    bool _contentsShown, _highlightsShown, _pageFieldShown, _searchShown, _shortcutsShown;

    static Border Scrim(double dim) => new()
    {
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb((byte)Math.Round(dim * 255), 0, 0, 0)),
        Visibility = Visibility.Collapsed,
        Opacity = 0,
    };

    /// <summary>
    /// The reading marker on the page (MarkerRibbon.swift): a narrow ribbon hanging from the top edge of
    /// the right-hand page with a V cut into its tail, and a faint shade down one side.
    /// </summary>
    static Microsoft.UI.Xaml.Shapes.Path Ribbon()
    {
        double w = ToolPlacement.RibbonWidth, h = ToolPlacement.RibbonHeight, notch = ToolPlacement.RibbonNotch;
        var figure = new PathFigure { StartPoint = new Windows.Foundation.Point(0, 0), IsClosed = true };
        foreach (var (x, y) in new[] { (w, 0.0), (w, h), (w / 2, h - notch), (0.0, h) })
            figure.Segments.Add(new LineSegment { Point = new Windows.Foundation.Point(x, y) });
        var ribbon = new Microsoft.UI.Xaml.Shapes.Path { Data = new PathGeometry { Figures = { figure } }, IsHitTestVisible = false, Opacity = 0 };
        AutomationProperties.SetName(ribbon, "Reading marker");
        return ribbon;
    }

    void BuildTools()
    {
        _desk.Children.Insert(_desk.Children.IndexOf(_spineRight) + 1, _ribbon);
        _overlay.Children.Add(_bar.Root);
        foreach (var element in new UIElement[]
        {
            _toolbar.Root, _pageField.Root, _searchScrim, _search.Root, _sideScrim, _contents.Root, _highlightsPanel.Root,
            _overlay, _shortcutsScrim, _shortcuts.Root,
        })
            _root.Children.Add(element);

        _toolbar.SettingsChanged += Change;
        _toolbar.Command += command =>
        {
            Perform(command);
            _book.Control.Focus(FocusState.Programmatic);
        };
        _toolbar.Hover += over => { if (!over) Wake(); };
        _root.PointerMoved += (_, _) => Wake();
        _book.PointerMoved += Wake;

        _sideScrim.PointerPressed += (_, e) => { e.Handled = true; CloseContents(); CloseHighlights(); };
        _searchScrim.PointerPressed += (_, e) => { e.Handled = true; CloseSearch(); };
        _shortcutsScrim.PointerPressed += (_, e) => { e.Handled = true; CloseShortcuts(); };

        _contents.Chosen += Choose;
        _highlightsPanel.Chosen += highlight => Jump(book => book.GoToCfiAsync(highlight.Cfi));
        _highlightsPanel.Removed += Remove;
        _pageField.OnGo = GoToPageTyped;
        _pageField.Closed += ClosePageField;
        _search.Query += query => _searching = SearchAsync(query);
        _search.Picked += PickSearchMatch;
        _search.Closed += CloseSearch;
        _bar.Pressed += PressedBar;
        _book.SelectionChanged += SelectionChanged;
        _book.HighlightClicked += HighlightClicked;
    }

    /// <summary>A new book, or none: the tools are put away, and nothing of the last book's is kept.</summary>
    void ResetTools()
    {
        CloseContents();
        CloseHighlights();
        ClosePageField();
        CloseSearch();
        CloseShortcuts();
        HideBar();
        _toc = null;
        _bookHighlights = [];
        _bookMarker = null;
        _searchQuery = "";
        _searchOutcome = null;
        _searchSelection = null;
        UpdateRibbon(animated: false);
    }

    /// <summary>The book's highlights and marker, drawn on the page once it's open.</summary>
    async Task LoadMarksAsync(string bookId, Func<bool> current)
    {
        var marks = _library.Highlights.Highlights(bookId).ToList();
        if (!current()) return;
        _bookHighlights = marks;
        await _book.SetHighlightsAsync(marks.Select(m => m.Cfi).ToList(), ToolColors.Highlight(Theme));
        if (!current()) return;
        var marker = _library.Markers.Marker(bookId);
        _bookMarker = marker;
        await _book.SetMarkerAsync(marker?.Cfi);
    }

    /// <summary>Once open: a marker elsewhere in the book is pointed out.</summary>
    void MentionMarker()
    {
        if (_bookMarker is { } marker && _book.CurrentLocation?.IsMarked == false)
            ShowNotice($"Marker on page {marker.Page} — {ReaderCommand.GoToMarker.Shortcut().Label} to go there");
    }

    // MARK: The toolbar

    double Now => _clock.Elapsed.TotalSeconds;

    /// <summary>The book's behind the library, where the toolbar never wakes.</summary>
    public void SetBehind(bool behind)
    {
        _isBehind = behind;
        if (behind) SleepToolbar();
    }

    void Wake()
    {
        if (_isBehind || !_book.IsOpen) return;
        _idle.Activity(Now);
        SetAwake(true);
        _idleCheck?.Cancel();
        var check = _idleCheck = new CancellationTokenSource();
        _ = Later();
        async Task Later()
        {
            try { await Task.Delay(TimeSpan.FromSeconds(_idle.Delay), check.Token); }
            catch (TaskCanceledException) { return; }
            if (_toolbar.IsOver) Wake();
            else if (!_idle.IsAwake(Now)) SetAwake(false);
        }
    }

    void SleepToolbar()
    {
        _idle.Sleep();
        _idleCheck?.Cancel();
        SetAwake(false);
    }

    void SetAwake(bool awake)
    {
        if (_toolbar.IsAwake != awake)
        {
            if (awake) RefreshToolbar();
            _toolbar.SetAwake(awake, AnimationsOn);
        }
        // In full screen the pointer goes with the toolbar, and comes back as soon as it moves.
        var hide = !awake && _isFullscreen && _book.IsOpen && !_isBehind;
        if (hide == _isPointerHidden) return;
        _isPointerHidden = hide;
        _ = _book.SetPointerHiddenAsync(hide);
    }

    void RefreshToolbar()
    {
        var here = _book.IsOpen ? _book.CurrentLocation : null;
        _toolbar.Show(_settings, Theme, here != null ? ChapterTimeLeft.Text(here.ChapterMinutesLeft) : null, _isFullscreen, here?.IsMarked == true);
    }

    internal ReaderToolbar Toolbar => _toolbar;
    internal bool IsToolbarAwake => _toolbar.IsAwake;
    internal bool IsPointerHidden => _isPointerHidden;
    internal void WakeForChecks() => Wake();

    // MARK: Commands

    /// <summary>The commands that are the reader's own. Answers false for the window's: full screen and the library.</summary>
    bool PerformTool(ReaderCommand command)
    {
        // The shortcuts are put away once one is used.
        if (command != ReaderCommand.ShowShortcuts) CloseShortcuts();
        switch (command)
        {
            case ReaderCommand.ToggleToc: ToggleContents(); return true;
            case ReaderCommand.ToggleHighlights: ToggleHighlights(); return true;
            case ReaderCommand.GoToPage: ShowPageField(); return true;
            case ReaderCommand.ToggleMarker: ToggleMarker(); return true;
            case ReaderCommand.GoToMarker:
                if (_bookMarker is { } marker) Jump(book => book.GoToCfiAsync(marker.Cfi));
                return true;
            case ReaderCommand.Find: ShowSearch(); return true;
            case ReaderCommand.ShowShortcuts:
                if (_shortcutsShown) CloseShortcuts();
                else ShowShortcuts();
                return true;
            default: return false;
        }
    }

    void ClosePanelsForJump()
    {
        CloseContents();
        CloseHighlights();
        ClosePageField();
        CloseSearch();
    }

    // MARK: Shortcuts

    void ShowShortcuts()
    {
        CloseContents();
        CloseHighlights();
        ClosePageField();
        CloseSearch();
        HideBar();
        _shortcuts.SetTheme(Theme);
        _shortcutsShown = true;
        ToolStyle.Show(_shortcutsScrim, true, AnimationsOn);
        ToolStyle.Show(_shortcuts.Root, true, AnimationsOn);
    }

    public void CloseShortcuts()
    {
        if (!_shortcutsShown) return;
        _shortcutsShown = false;
        ToolStyle.Show(_shortcutsScrim, false, AnimationsOn);
        ToolStyle.Show(_shortcuts.Root, false, AnimationsOn);
    }

    internal bool IsShowingShortcuts => _shortcutsShown;
    internal List<string[]> ShortcutKeysShown => _shortcuts.ShownKeys;

    // MARK: Search

    /// <summary>Opens the search box over the book, with the last search still in it.</summary>
    void ShowSearch()
    {
        if (!_book.IsOpen) return;
        CloseContents();
        CloseHighlights();
        ClosePageField();
        HideBar();
        _search.SetTheme(Theme);
        _searchShown = true;
        ToolStyle.Show(_searchScrim, true, false);
        _searchScrim.Opacity = 1;
        _search.Begin(_searchQuery, _searchOutcome, _searchSelection);
        ToolStyle.Show(_search.Root, true, AnimationsOn);
    }

    /// <summary>Closes the box without moving. Called again as the field gives up the keyboard, which does nothing then.</summary>
    void CloseSearch()
    {
        if (!_searchShown) return;
        _searchShown = false;
        _searchSelection = _search.Selected;
        ToolStyle.Show(_searchScrim, false, false);
        _searchScrim.Visibility = Visibility.Collapsed;
        ToolStyle.Show(_search.Root, false, AnimationsOn);
        if (_search.HasFocus) _book.Control.Focus(FocusState.Programmatic);
    }

    /// <summary>Searches the open book straight away. A reply to a search since replaced, or to another book, is dropped.</summary>
    async Task SearchAsync(string query)
    {
        _searchQuery = query;
        var generation = ++_searchGeneration;
        var opened = _openGeneration;
        if (!_book.IsOpen || !SearchResults.IsSearchable(query))
        {
            _searchOutcome = null;
            _searchSelection = null;
            _search.Show(null);
            return;
        }
        var outcome = await _book.SearchAsync(query, SearchResults.Limit);
        if (outcome == null || generation != _searchGeneration || opened != _openGeneration) return;
        _searchOutcome = outcome;
        _search.Show(outcome);
        _searchSelection = _search.Selected;
    }

    /// <summary>Closes the box and goes to the match, which glows for a moment once there.</summary>
    void PickSearchMatch(int index)
    {
        if (_searchOutcome?.Matches is not { } matches || index < 0 || index >= matches.Count) return;
        var match = matches[index];
        _searchSelection = index;
        var glow = ToolColors.Glow(Theme);
        Jump(async book =>
        {
            var landed = await book.GoToCfiAsync(match.Cfi);
            await book.FlashAsync(match.Cfi, glow);
            return landed;
        });
    }

    internal bool IsShowingSearch => _searchShown;
    internal SearchBox Search => _search;
    internal SearchOutcome? SearchOutcome => _searchOutcome;
    internal Task SearchedAsync() => _searching ?? Task.CompletedTask;

    // MARK: Go to page

    void ShowPageField()
    {
        if (_book.CurrentLocation is not { PageCount: > 0 } here) return;
        CloseContents();
        CloseHighlights();
        CloseSearch();
        _pageField.SetTheme(Theme);
        _pageFieldShown = true;
        ToolStyle.Show(_pageField.Root, true, AnimationsOn);
        _pageField.Begin(here.Page, here.PageCount);
    }

    /// <summary>Closes the field without moving. Called again as the field gives up the keyboard, which does nothing then.</summary>
    void ClosePageField()
    {
        if (!_pageFieldShown) return;
        _pageFieldShown = false;
        var focused = FocusWatch.IsWithin(_pageField.Root);
        ToolStyle.Show(_pageField.Root, false, AnimationsOn);
        if (focused) _book.Control.Focus(FocusState.Programmatic);
    }

    /// <summary>Goes to the page typed and closes the field; false, leaving it open, if what was typed isn't a page number.</summary>
    bool GoToPageTyped(string typed)
    {
        if (_book.CurrentLocation is not { } here || GoToPage.Page(typed, here.PageCount) is not { } page) return false;
        Jump(book => book.GoToPageAsync(page));
        return true;
    }

    internal bool IsShowingPageField => _pageFieldShown;
    internal GoToPageField PageField => _pageField;

    // MARK: Contents

    /// <summary>A book with no contents has nothing to show, so this does nothing for it.</summary>
    void ToggleContents()
    {
        if (_contentsShown)
        {
            CloseContents();
            return;
        }
        if (!_book.IsOpen) return;
        var opened = _openGeneration;
        _contentsLoading = Load();
        async Task Load()
        {
            var entries = _toc ??= await _book.TocAsync();
            if (opened != _openGeneration || entries.Count == 0 || _contentsShown) return;
            OpenContents(entries, _book.CurrentLocation?.Fraction ?? 0);
        }
    }

    /// <summary>Slides the contents in over the left of the book, with the keyboard theirs.</summary>
    void OpenContents(IReadOnlyList<TocEntry> entries, double fraction)
    {
        ClosePageField();
        CloseSearch();
        CloseHighlights();
        HideBar();
        _contentsShown = true;
        _contents.SetTheme(Theme);
        _contents.Show(entries, fraction);
        Slide(_contents.Root, true);
        _contents.Focus();
    }

    void CloseContents()
    {
        if (!_contentsShown) return;
        _contentsShown = false;
        var focused = _contents.HasFocus;
        Slide(_contents.Root, false);
        if (focused) _book.Control.Focus(FocusState.Programmatic);
    }

    /// <summary>
    /// Closes the contents and goes to the chapter. A link the book can't follow just now is found by
    /// how far through it is, and one with no place in the book goes nowhere.
    /// </summary>
    void Choose(TocEntry entry)
    {
        if (entry.Fraction is not { } fraction) return;
        Jump(async book =>
        {
            var (resolved, landed) = await book.GoToHrefAsync(entry.Href);
            return resolved ? landed : await book.GoToFractionAsync(fraction);
        });
    }

    /// <summary>A sidebar slides in from the left edge, with the scrim beside it.</summary>
    void Slide(Grid panel, bool shown)
    {
        var transform = (TranslateTransform)panel.RenderTransform;
        var to = shown ? 0 : -Sidebar.Width;
        var anyShown = _contentsShown || _highlightsShown;
        _sideScrim.Visibility = anyShown ? Visibility.Visible : Visibility.Collapsed;
        _sideScrim.Opacity = 1;
        if (shown) panel.Visibility = Visibility.Visible;
        if (!AnimationsOn)
        {
            transform.X = to;
            if (!shown) panel.Visibility = Visibility.Collapsed;
            return;
        }
        var animation = new Microsoft.UI.Xaml.Media.Animation.DoubleAnimation
        {
            To = to,
            Duration = new Duration(Motion),
            EasingFunction = new Microsoft.UI.Xaml.Media.Animation.QuadraticEase { EasingMode = Microsoft.UI.Xaml.Media.Animation.EasingMode.EaseOut },
        };
        Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTarget(animation, transform);
        Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTargetProperty(animation, "X");
        var storyboard = new Microsoft.UI.Xaml.Media.Animation.Storyboard();
        storyboard.Children.Add(animation);
        storyboard.Completed += (_, _) =>
        {
            transform.X = to;
            var stillShown = panel == _contents.Root ? _contentsShown : _highlightsShown;
            if (!stillShown) panel.Visibility = Visibility.Collapsed;
        };
        storyboard.Begin();
    }

    internal bool IsShowingContents => _contentsShown;
    internal TocSidebar Contents => _contents;
    internal Task ContentsLoadedAsync() => _contentsLoading ?? Task.CompletedTask;

    // MARK: Highlights

    /// <summary>The reader selected words, or let go of them.</summary>
    void SelectionChanged(SelectionInfo? info)
    {
        if (info == null)
        {
            // A click on a highlight collapses the selection just after it's shown the bar.
            if (_barShownAt is { } shown && _targetedHighlight != null && DateTime.UtcNow - shown < TimeSpan.FromMilliseconds(400)) return;
            HideBar();
            return;
        }
        if (BookId == null || _contentsShown || _highlightsShown) return;
        _selection = info;
        if (_bookHighlights.Any(h => h.Cfi == info.Cfi))
        {
            _targetedHighlight = info.Cfi;
            ShowBar(HighlightBar.Mode.Remove, info.Rect);
        }
        else
        {
            _targetedHighlight = null;
            ShowBar(HighlightBar.Mode.Add, info.Rect);
        }
    }

    void HighlightClicked(string cfi, Box rect)
    {
        if (_contentsShown || _highlightsShown) return;
        _selection = null;
        _targetedHighlight = cfi;
        ShowBar(HighlightBar.Mode.Remove, rect);
    }

    /// <summary><paramref name="rect"/> is in the page, from its top left; the bar goes by it, on the desk.</summary>
    void ShowBar(HighlightBar.Mode mode, Box rect)
    {
        var frame = _layout.Frame;
        var target = new Box(frame.X + rect.X, frame.Y + rect.Y, rect.Width, rect.Height);
        _bar.SetTheme(Theme);
        _bar.Show(mode, ToolPlacement.HighlightBar(target, new Box(0, 0, _root.ActualWidth, _root.ActualHeight)));
        _barShownAt = DateTime.UtcNow;
    }

    void HideBar()
    {
        _bar.Hide();
        _selection = null;
        _targetedHighlight = null;
        _barShownAt = null;
    }

    void PressedBar(HighlightBar.Mode mode)
    {
        if (mode == HighlightBar.Mode.Add)
        {
            if (_selection is { } info) AddHighlight(info);
            return;
        }
        if (_targetedHighlight is { } cfi && _bookHighlights.FirstOrDefault(h => h.Cfi == cfi) is { } highlight) Remove(highlight);
        else HideBar();
    }

    void AddHighlight(SelectionInfo info)
    {
        if (BookId is not { } id) return;
        HideBar();
        var highlight = Highlight.Create(info.Cfi, info.Text, info.Fraction, info.ChapterTitle);
        _marking = Run();
        async Task Run()
        {
            _library.Highlights.Add(highlight, id);
            await _book.AddHighlightAsync(info.Cfi);
            await _book.ClearSelectionAsync();
            HighlightsChanged(id);
        }
    }

    void Remove(Highlight highlight)
    {
        if (BookId is not { } id) return;
        var wasSelected = _selection != null;
        HideBar();
        _marking = Run();
        async Task Run()
        {
            _library.Highlights.Remove(highlight.Id, id);
            await _book.RemoveHighlightAsync(highlight.Cfi);
            // Words selected to reach it aren't left selected once it's gone.
            if (wasSelected) await _book.ClearSelectionAsync();
            HighlightsChanged(id);
        }
    }

    /// <summary>Reads the book's highlights again, for the sidebar and the picture of the spread.</summary>
    void HighlightsChanged(string id)
    {
        if (BookId != id) return;
        _bookHighlights = _library.Highlights.Highlights(id).ToList();
        if (_highlightsShown)
        {
            var row = Math.Min(_highlightsPanel.SelectedRow, _bookHighlights.Count - 1);
            _highlightsPanel.Show(_bookHighlights);
            if (row >= 0) _highlightsPanel.Select(row);
            _highlightsPanel.Focus();
        }
        RememberSpread();
    }

    /// <summary>The reader changed theme: the highlights are redrawn in its colour.</summary>
    void RecolorHighlights()
    {
        if (!_book.IsOpen || _bookHighlights.Count == 0) return;
        var color = ToolColors.Highlight(Theme);
        if (color == _book.HighlightColor) return;
        _ = _book.SetHighlightsAsync(_book.HighlightCfis, color);
    }

    void ToggleHighlights()
    {
        if (_highlightsShown)
        {
            CloseHighlights();
            return;
        }
        if (!_book.IsOpen || BookId is not { } id) return;
        _bookHighlights = _library.Highlights.Highlights(id).ToList();
        ClosePageField();
        CloseSearch();
        CloseContents();
        HideBar();
        _highlightsShown = true;
        _highlightsPanel.SetTheme(Theme);
        _highlightsPanel.Show(_bookHighlights);
        Slide(_highlightsPanel.Root, true);
        _highlightsPanel.Focus();
    }

    void CloseHighlights()
    {
        if (!_highlightsShown) return;
        _highlightsShown = false;
        var focused = _highlightsPanel.HasFocus;
        Slide(_highlightsPanel.Root, false);
        if (focused) _book.Control.Focus(FocusState.Programmatic);
    }

    internal bool IsShowingHighlights => _highlightsShown;
    internal HighlightsSidebar HighlightsPanel => _highlightsPanel;
    internal HighlightBar Bar => _bar;
    internal IReadOnlyList<Highlight> BookHighlights => _bookHighlights;

    // MARK: Reading marker

    /// <summary>
    /// Marks the spread on show, moving the marker if it was elsewhere, or takes it away if this is the
    /// spread that holds it.
    /// </summary>
    void ToggleMarker()
    {
        if (!_book.IsOpen || BookId is not { } id || _book.CurrentLocation is not { } here) return;
        var previous = _marking;
        var opened = _openGeneration;
        _marking = Run();
        async Task Run()
        {
            try { await previous; } catch (Exception) { }
            try { await _turning; } catch (Exception) { }
            if (opened != _openGeneration) return;
            if (_book.CurrentLocation?.IsMarked == true)
            {
                _library.Markers.Remove(id);
                await _book.SetMarkerAsync(null);
                if (opened != _openGeneration) return;
                _bookMarker = null;
                ShowNotice("Marker removed");
            }
            else
            {
                var at = _book.CurrentLocation ?? here;
                var place = await _book.PlaceAsync() ?? at.Cfi;
                if (await _book.SetMarkerAsync(place) is not { } cfi || opened != _openGeneration) return;
                var marker = Marker.Create(cfi, at.Fraction, at.Page, at.ChapterTitle);
                _library.Markers.Set(marker, id);
                _bookMarker = marker;
                ShowNotice($"Marked page {at.Page}");
            }
            RefreshToolbar();
            UpdateRibbon(animated: true);
            RememberSpread();
        }
    }

    /// <summary>A page is about to turn: the ribbon leaves it until the turn has landed.</summary>
    void TurnBegan() => UpdateRibbon(animated: false, turning: true);

    /// <summary>Shows the ribbon again, if the spread it lands on holds the marker, once every turn has landed.</summary>
    void TurnLanded()
    {
        if (_turnsInFlight > 0) return;
        UpdateRibbon(animated: true);
        if (_toolbar.IsAwake) RefreshToolbar();
    }

    void UpdateRibbon(bool animated, bool turning = false)
    {
        var on = !turning && _turnsInFlight == 0 && _book.IsOpen && _book.CurrentLocation?.IsMarked == true;
        if (on == _isRibbonOn) return;
        _isRibbonOn = on;
        ToolStyle.Show(_ribbon, on, animated && AnimationsOn);
        _ribbon.IsHitTestVisible = false;
    }

    internal Marker? BookMarker => _bookMarker;
    internal bool IsRibbonShown => _isRibbonOn;
    internal string NoticeText => _notice.Text;
    internal Task MarkedAsync() => _marking;

    // MARK: Colours and places

    void ApplyToolColors()
    {
        _ribbon.Fill = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0.5),
            EndPoint = new Windows.Foundation.Point(1, 0.5),
            GradientStops =
            {
                new GradientStop { Offset = 0, Color = ToolStyle.Color(ToolColors.Ribbon(Theme)) },
                new GradientStop { Offset = 0.78, Color = ToolStyle.Color(ToolColors.Ribbon(Theme)) },
                new GradientStop { Offset = 0.78, Color = ToolStyle.Color(Darker(ToolColors.Ribbon(Theme))) },
                new GradientStop { Offset = 1, Color = ToolStyle.Color(Darker(ToolColors.Ribbon(Theme))) },
            },
        };
        if (_toolbar.IsAwake) RefreshToolbar();
        if (_contentsShown) { _contents.SetTheme(Theme); _contents.Show(_contents.Entries, _book.CurrentLocation?.Fraction ?? 0); }
        if (_highlightsShown) { _highlightsPanel.SetTheme(Theme); _highlightsPanel.Show(_bookHighlights); }
        RecolorHighlights();
    }

    /// <summary>The faint shade down the ribbon's side, as if it lay on the paper.</summary>
    static Rgba Darker(Rgba color) => new((byte)(color.R * 0.88), (byte)(color.G * 0.88), (byte)(color.B * 0.88), color.A);

    void PlaceTools()
    {
        var ribbon = ToolPlacement.Ribbon(_layout.Frame);
        Canvas.SetLeft(_ribbon, ribbon.X);
        Canvas.SetTop(_ribbon, ribbon.Y);
        HideBar();
    }
}
