using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using Readme.Core.Layout;
using Readme.Core.Library;
using Readme.Core.Model;
using Readme.Core.Reader;
using Readme.Core.Storage;
using Readme.Core.Zip;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace Readme.App.Library;

/// <summary>
/// The bookshelf (LibraryView.swift, CurrentBookShelf.swift, ShelfRow.swift): the current book on
/// its own ledge, the rest on shelves below, books pinned to the front first, empty shelves filling the
/// window, a search that filters the shelves in place, and a drop target for new books.
/// </summary>
sealed class LibraryView
{
    const double CoverWidth = 112;
    const double CurrentCoverWidth = 150;
    static readonly TimeSpan NoticeDuration = TimeSpan.FromSeconds(4);
    static readonly TimeSpan ProgressDelay = TimeSpan.FromMilliseconds(500);

    readonly LibraryStore _library;
    readonly Func<Book, Task> _open;
    readonly Func<IReadOnlyList<string>, Task<IReadOnlyList<(string Path, Book? Book, ImportError? Error)>>> _importAll;
    readonly Func<bool> _animations;
    readonly ShelfSelection _selection = new();
    readonly ShelfSearch _search = new();
    readonly Grid _root = new() { AllowDrop = true };
    readonly ScrollViewer _scroller = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    readonly StackPanel _shelves = new() { Spacing = ShelfLayout.ShelfGap, Padding = new Thickness(0, 0, 0, 26) };
    readonly Border _dropRing = new() { Margin = new Thickness(8), CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(2), IsHitTestVisible = false, BorderBrush = ShelfStyle.Brush(ShelfStyle.Text, 0.45), Opacity = 0 };
    readonly TextBlock _noMatch = ShelfStyle.Line("", 16, ShelfStyle.Text, italic: true);
    readonly Border _notice = new() { CornerRadius = new CornerRadius(8), Padding = new Thickness(20, 10, 20, 10), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 40), IsHitTestVisible = false, Opacity = 0, Background = ShelfStyle.Brush(ShelfStyle.NoticeBackground), BorderBrush = ShelfStyle.Brush(ShelfStyle.Text, 0.1), BorderThickness = new Thickness(1) };
    readonly StackPanel _noticeLines = new() { Spacing = 4 };
    readonly Button _searchButton = new() { Content = new FontIcon { Glyph = "", FontSize = 14 }, Padding = new Thickness(8), Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0) };
    readonly TextBox _searchBox = new() { Width = 220, PlaceholderText = "Search the library", Visibility = Visibility.Collapsed };
    readonly List<string> _noticeTexts = [];
    readonly Dictionary<string, BookCoverView> _covers = [];
    CancellationTokenSource? _noticeFading;
    int _pending;
    string? _progress;
    double _builtWidth = -1;

    public UIElement Root => _root;
    public event Action? FocusLeft;

    public LibraryView(LibraryStore library, Func<Book, Task> open,
        Func<IReadOnlyList<string>, Task<IReadOnlyList<(string Path, Book? Book, ImportError? Error)>>> importAll, Func<bool> animations)
    {
        _library = library;
        _open = open;
        _importAll = importAll;
        _animations = animations;
        _root.Background = ShelfStyle.Vertical(ShelfStyle.Top, ShelfStyle.Bottom);
        _root.RequestedTheme = ElementTheme.Dark;
        _scroller.Content = _shelves;
        _root.Children.Add(_scroller);
        _root.Children.Add(_dropRing);
        _noMatch.HorizontalAlignment = HorizontalAlignment.Center;
        _noMatch.VerticalAlignment = VerticalAlignment.Top;
        _noMatch.Margin = new Thickness(0, 80, 0, 0);
        _noMatch.IsHitTestVisible = false;
        _noMatch.Visibility = Visibility.Collapsed;
        _root.Children.Add(_noMatch);
        _notice.Child = _noticeLines;
        _root.Children.Add(_notice);
        _root.Children.Add(SearchField());

        _root.SizeChanged += (_, e) =>
        {
            if (Math.Abs(e.NewSize.Width - _builtWidth) > 0.5 || e.PreviousSize.Height != e.NewSize.Height) Rebuild();
        };
        _library.Changed += () => _root.DispatcherQueue.TryEnqueue(Rebuild);
        _selection.Changed += ShowSelection;
        // A click on the shelf itself, not on a book, puts the selection down.
        _scroller.Tapped += (_, e) =>
        {
            if (e.OriginalSource is FrameworkElement { DataContext: not Book } element && FindCover(element) == null) _selection.Clear();
        };
        _root.DragOver += OnDragOver;
        _root.DragLeave += (_, _) => _dropRing.Opacity = 0;
        _root.Drop += OnDrop;
    }

    public bool IsSearching => _search.IsOpen || _search.IsActive;

    // MARK: Shelves

    /// <summary>The books as the shelf shows them, the current one first.</summary>
    IReadOnlyList<Book> Order() => new[] { _library.Current }.OfType<Book>().Concat(_library.Others).ToList();

    /// <summary>The books a search finds, the current one first, in the shelf's order.</summary>
    IReadOnlyList<Book> Found() => ShelfSearch.Filter(Order(), _search.Query);

    public void Rebuild()
    {
        var width = _root.ActualWidth > 0 ? _root.ActualWidth : 1048;
        var height = _root.ActualHeight > 0 ? _root.ActualHeight : 620;
        _builtWidth = width;
        _shelves.Children.Clear();
        _covers.Clear();
        var current = _library.Current;
        var others = ShelfSearch.Filter(_library.Others, _search.Query);
        // While searching, the current book's shelf stays only if that book is one it finds.
        var showsCurrent = current != null ? ShelfSearch.Matches(current, _search.Query) : !_search.IsActive;
        if (showsCurrent) _shelves.Children.Add(Ledge(current));
        var rows = ShelfLayout.Rows(others, width);
        foreach (var row in rows)
        {
            var books = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 22, VerticalAlignment = VerticalAlignment.Bottom };
            foreach (var book in row) books.Children.Add(Cover(book, CoverWidth, extraShadow: false));
            _shelves.Children.Add(Shelf(books, ShelfLayout.ShelfHeight));
        }
        var empties = Math.Max(0, ShelfLayout.EmptyRowCount(height) - rows.Count);
        for (var i = 0; i < empties; i++) _shelves.Children.Add(Shelf(null, ShelfLayout.ShelfHeight));
        _noMatch.Text = ShelfText.NoMatch(_search.Query);
        _noMatch.Visibility = _search.IsActive && Found().Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowSelection();
    }

    /// <summary>One shelf: books standing on a wooden rail that runs the width of the window.</summary>
    static Grid Shelf(UIElement? books, double height)
    {
        var shelf = new Grid { Height = height, Padding = new Thickness(54, 0, 54, 0) };
        var rail = new Rectangle
        {
            Height = 14,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(-54, 0, -54, -14),
            Fill = ShelfStyle.Vertical(ShelfStyle.WoodTop, ShelfStyle.WoodBottom),
            IsHitTestVisible = false,
        };
        rail.Shadow = new ThemeShadow();
        rail.Translation = new System.Numerics.Vector3(0, 0, 12);
        shelf.Children.Add(rail);
        if (books != null) shelf.Children.Add(books);
        return shelf;
    }

    /// <summary>
    /// The top shelf: the current book with its title, author and where the reader left off, or on
    /// first open, a place to drop a first book.
    /// </summary>
    Grid Ledge(Book? book)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 28, VerticalAlignment = VerticalAlignment.Bottom };
        var info = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 20), MaxWidth = Math.Max(200, _builtWidth - 54 * 2 - CurrentCoverWidth - 28) };
        if (book != null)
        {
            row.Children.Add(Cover(book, CurrentCoverWidth, extraShadow: true));
            var label = ShelfStyle.Line("CONTINUE READING", 12, ShelfStyle.Muted);
            label.CharacterSpacing = 180;
            info.Children.Add(label);
            var title = ShelfStyle.Line(book.Title, 34, ShelfStyle.Text, BundledFonts.Fraunces);
            title.FontWeight = FontWeights.Light;
            title.TextWrapping = TextWrapping.Wrap;
            title.MaxLines = 2;
            title.Margin = new Thickness(0, 6, 0, 4);
            info.Children.Add(title);
            if (book.Author is { } author) info.Children.Add(ShelfStyle.Line(author, 17, ShelfStyle.Soft, italic: true));
            if (ShelfText.ProgressLine(book) is { } progress)
            {
                var line = ShelfStyle.Line(progress, 15, ShelfStyle.Soft);
                line.Margin = new Thickness(0, 10, 0, 0);
                info.Children.Add(line);
            }
            AutomationProperties.SetName(info, string.Join(", ", new[] { "Continue reading", book.Title, book.Author, ShelfText.ProgressLine(book) }.OfType<string>()));
        }
        else
        {
            row.Children.Add(new Rectangle
            {
                Width = CurrentCoverWidth,
                Height = CurrentCoverWidth * 1.5,
                RadiusX = 3,
                RadiusY = 3,
                Stroke = ShelfStyle.Brush(ShelfStyle.Text, 0.35),
                StrokeThickness = 1,
                StrokeDashArray = [4, 3],
            });
            var title = ShelfStyle.Line("Drop a book here", 34, ShelfStyle.Text, BundledFonts.Fraunces);
            title.FontWeight = FontWeights.Light;
            info.Children.Add(title);
            info.Children.Add(ShelfStyle.Line("Any EPUB file will do. Or press Ctrl+O.", 17, ShelfStyle.Soft, italic: true));
        }
        row.Children.Add(info);
        return Shelf(row, ShelfLayout.LedgeHeight);
    }

    BookCoverView Cover(Book book, double width, bool extraShadow)
    {
        var cover = new BookCoverView(book, width, _library, extraShadow, _animations()) { DataContext = book };
        cover.Click += async (_, _) =>
        {
            var modifiers = Keys.CurrentModifiers();
            if (_selection.Click(book.Id, modifiers, Order().Select(b => b.Id).ToList()) == ShelfSelection.Outcome.Open)
                await _open(book);
        };
        var menu = new MenuFlyout();
        menu.Opening += (_, _) => FillMenu(menu, book);
        cover.ContextFlyout = menu;
        _covers[book.Id] = cover;
        return cover;
    }

    /// <summary>Pin and Remove act on the selection if the book right-clicked is in it, else on that book.</summary>
    void FillMenu(MenuFlyout menu, Book book)
    {
        menu.Items.Clear();
        var targets = _selection.Targets(book.Id, Order().Select(b => b.Id).ToList()).Select(_library.Book).OfType<Book>().ToList();
        var allPinned = targets.All(b => b.PinnedAt != null);
        var pin = new MenuFlyoutItem { Text = ShelfSelection.PinMenuTitle(targets.Count, allPinned) };
        pin.Click += (_, _) => _library.SetPinned(targets.Select(b => b.Id), !allPinned);
        menu.Items.Add(pin);
        // Export arrives with library bundles (phase 5).
        menu.Items.Add(new MenuFlyoutSeparator());
        var remove = new MenuFlyoutItem { Text = targets.Count > 1 ? $"Remove {targets.Count} Books" : "Remove" };
        remove.Click += (_, _) =>
        {
            foreach (var target in targets) _library.Remove(target.Id);
            _selection.Clear();
        };
        menu.Items.Add(remove);
    }

    void ShowSelection()
    {
        foreach (var (id, cover) in _covers) cover.IsPicked = _selection.Ids.Contains(id);
    }

    static BookCoverView? FindCover(DependencyObject? element)
    {
        for (; element != null; element = VisualTreeHelper.GetParent(element))
            if (element is BookCoverView cover) return cover;
        return null;
    }

    // MARK: Search

    UIElement SearchField()
    {
        var close = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, Padding = new Thickness(6), Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), Visibility = Visibility.Collapsed };
        AutomationProperties.SetName(_searchButton, "Search the library");
        ToolTipService.SetToolTip(_searchButton, "Search the library (Ctrl+F)");
        AutomationProperties.SetName(close, "Clear the search");
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 12, 20, 0) };
        panel.Children.Add(_searchButton);
        panel.Children.Add(_searchBox);
        panel.Children.Add(close);
        _searchButton.Click += (_, _) => OpenSearch();
        close.Click += (_, _) => CloseSearch();
        _searchBox.TextChanged += (_, _) =>
        {
            _search.Query = _searchBox.Text;
            Rebuild();
        };
        _searchBox.KeyDown += async (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape)
            {
                CloseSearch();
                e.Handled = true;
            }
            else if (e.Key == Windows.System.VirtualKey.Enter && Found() is [var only])
            {
                e.Handled = true;
                await _open(only);
            }
        };
        void Show(bool open)
        {
            _searchBox.Visibility = close.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
            _searchButton.Visibility = open ? Visibility.Collapsed : Visibility.Visible;
        }
        _searchShown = Show;
        return panel;
    }

    Action<bool>? _searchShown;

    /// <summary>For the self-checks: types into the search field.</summary>
    internal void Type(string query)
    {
        OpenSearch();
        _searchBox.Text = query;
    }

    /// <summary>For the self-checks: a click on a book with these modifiers held, as the cover's own click does.</summary>
    internal ShelfSelection.Outcome Click(string id, Modifiers modifiers) =>
        _selection.Click(id, modifiers, Order().Select(b => b.Id).ToList());

    /// <summary>For the self-checks: which covers show the ring, and what the menu on a book offers.</summary>
    internal IReadOnlyList<string> PickedTitles() => _covers.Values.Where(c => c.IsPickedNow).Select(c => c.Book.Title).ToList();

    internal IReadOnlyList<string> MenuFor(string id, bool show)
    {
        var cover = _covers[id];
        var menu = (MenuFlyout)cover.ContextFlyout;
        FillMenu(menu, cover.Book);
        if (show) menu.ShowAt(cover, new Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowOptions { Position = new Windows.Foundation.Point(40, 60) });
        return menu.Items.OfType<MenuFlyoutItem>().Select(i => i.Text).ToList();
    }

    internal void HideMenus()
    {
        foreach (var cover in _covers.Values) cover.ContextFlyout?.Hide();
    }

    /// <summary>For the self-checks: what the shelf shows, in order.</summary>
    internal IReadOnlyList<string> ShownTitles() => _covers.Values.Select(c => c.Book.Title).ToList();

    /// <summary>Opens the field and puts the keyboard in it, as a click on the magnifier or Ctrl+F does.</summary>
    public void OpenSearch()
    {
        _search.Open();
        _searchShown?.Invoke(true);
        _searchBox.Focus(FocusState.Programmatic);
    }

    /// <summary>Empties the field, folds it back to its icon, and gives the keyboard back.</summary>
    public void CloseSearch()
    {
        var had = IsSearching;
        _search.Close();
        _searchBox.Text = "";
        _searchShown?.Invoke(false);
        if (had) Rebuild();
        FocusLeft?.Invoke();
    }

    /// <summary>Esc over the shelf clears a search, then puts the selection down; otherwise does <paramref name="fallback"/>.</summary>
    public void Escape(Action fallback)
    {
        if (IsSearching) CloseSearch();
        else if (_selection.Ids.Count > 0) _selection.Clear();
        else fallback();
    }

    /// <summary>The search is cleared when a book opens, so the shelf is whole when the reader comes back.</summary>
    public void BookOpened()
    {
        if (IsSearching) CloseSearch();
        _selection.Clear();
    }

    // MARK: Adding books

    void OnDragOver(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "Add to the library";
        _dropRing.Opacity = 1;
    }

    async void OnDrop(object sender, DragEventArgs e)
    {
        _dropRing.Opacity = 0;
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var deferral = e.GetDeferral();
        IReadOnlyList<IStorageItem> items;
        try { items = await e.DataView.GetStorageItemsAsync(); }
        finally { deferral.Complete(); }
        var files = items.OfType<StorageFile>().Select(f => f.Path).Where(p => !string.IsNullOrEmpty(p)).ToList();
        var bundles = files.Where(p => p.EndsWith(".readmelibrary", StringComparison.OrdinalIgnoreCase)).ToList();
        if (bundles.Count > 0) Say("Readme libraries can be imported once that arrives (phase 5).");
        await AddAsync(files.Except(bundles).ToList());
    }

    /// <summary>
    /// Imports the files. What goes wrong is a quiet notice that fades by itself; if it takes a while,
    /// a soft line says books are being added. Books already here are no problem.
    /// </summary>
    public async Task<IReadOnlyList<(string Path, Book? Book, ImportError? Error)>> AddAsync(IReadOnlyList<string> files)
    {
        if (files.Count == 0) return [];
        _pending += files.Count;
        var waiting = new CancellationTokenSource();
        _ = ShowProgressLater(waiting.Token);
        var results = await _importAll(files);
        waiting.Cancel();
        _pending -= files.Count;
        if (_progress != null) _progress = _pending > 0 ? ShelfText.Adding(_pending) : null;
        var failures = results.Where(r => r.Error != null).Select(r => r.Error!.Value).ToList();
        if (failures.Count > 0) Show(ShelfText.Messages(failures));
        else RefreshNotice();
        return results;
    }

    async Task ShowProgressLater(CancellationToken token)
    {
        try { await Task.Delay(ProgressDelay, token); }
        catch (TaskCanceledException) { return; }
        if (_pending == 0) return;
        _progress = ShelfText.Adding(_pending);
        RefreshNotice();
    }

    /// <summary>Shows lines like a failure's, and fades them after a while.</summary>
    public void Say(string line) => Show([line]);

    void Show(IReadOnlyList<string> lines)
    {
        foreach (var line in lines) if (!_noticeTexts.Contains(line)) _noticeTexts.Add(line);
        RefreshNotice();
        _noticeFading?.Cancel();
        var fading = _noticeFading = new CancellationTokenSource();
        _ = Fade();
        async Task Fade()
        {
            try { await Task.Delay(NoticeDuration, fading.Token); }
            catch (TaskCanceledException) { return; }
            _noticeTexts.Clear();
            RefreshNotice();
        }
    }

    void RefreshNotice()
    {
        _noticeLines.Children.Clear();
        foreach (var line in _noticeTexts) _noticeLines.Children.Add(Centered(ShelfStyle.Line(line, 16, ShelfStyle.Text, italic: true)));
        if (_progress != null) _noticeLines.Children.Add(Centered(ShelfStyle.Line(_progress, 15, ShelfStyle.Muted, italic: true)));
        var shown = _noticeLines.Children.Count > 0;
        AutomationProperties.SetName(_notice, string.Join(". ", _noticeTexts.Append(_progress ?? "")));
        Fade(_notice, shown ? 1 : 0);
    }

    static TextBlock Centered(TextBlock line)
    {
        line.HorizontalAlignment = HorizontalAlignment.Center;
        return line;
    }

    void Fade(UIElement element, double to)
    {
        if (!_animations())
        {
            element.Opacity = to;
            return;
        }
        var animation = new DoubleAnimation { To = to, Duration = new Duration(TimeSpan.FromMilliseconds(250)), EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } };
        Storyboard.SetTarget(animation, element);
        Storyboard.SetTargetProperty(animation, "Opacity");
        var storyboard = new Storyboard { Children = { animation } };
        storyboard.Begin();
    }
}
