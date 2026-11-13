using System.Diagnostics;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Animation;
using Readme.App.Library;
using Readme.App.Reader;
using Readme.Core.Layout;
using Readme.Core.Library;
using Readme.Core.Model;
using Readme.Core.Reader;
using Readme.Core.Storage;
using Readme.Core.Zip;
using Windows.Graphics;
using Windows.Storage.Pickers;
using Windows.UI.ViewManagement;

namespace Readme.App;

/// <summary>
/// Owns the library, the window and the reader (AppCoordinator.swift and the window parts of
/// ReadmeApp.swift): where the app opens, the shelf over the desk, importing and opening books, full
/// screen, and keeping everything on close.
/// </summary>
sealed class AppCoordinator
{
    /// <summary>The mockup's stage, which makes the book the size the curl was approved at.</summary>
    const double ContentWidth = 1048, ContentHeight = 620;
    /// <summary>Narrow enough for one page.</summary>
    const double MinimumWidth = 640, MinimumHeight = 420;

    readonly string[] _arguments;
    readonly Action _exit;
    readonly LibraryStore _library = new(AppPaths.Library);
    readonly LastSpreadCache _spreads;
    readonly UISettings _system = new();
    readonly Window _window = new();
    readonly Grid _content = new();
    readonly ReaderView _reader;
    readonly LibraryView _shelf;
    readonly BookImporter _importer;
    readonly LibraryExporter _exporter;
    readonly LibraryImporter _libraryImporter;
    /// <summary>
    /// Books a running import is combining into. Opening one waits for it, so the reader starts from
    /// the place the import leaves, and nothing it writes lands over what the import brought.
    /// </summary>
    readonly HashSet<string> _combining = [];
    TaskCompletionSource? _combined;
    ContentDialog? _openDialog;
    /// <summary>
    /// The view nobody sees, which import opens each book in: one, made once and kept, since closing a
    /// WebView2 straight after use can crash the app (spike findings). At opacity 0 behind everything,
    /// as a collapsed or never-shown one doesn't work.
    /// </summary>
    readonly BookWebView _hidden = new();
    readonly SemaphoreSlim _hiddenTurn = new(1, 1);
    bool _isShowingLibrary;
    bool _isClosing;
    bool _closeKept;
    RectInt32? _restoredBounds;

    public AppCoordinator(string[] arguments, Action exit)
    {
        _arguments = arguments;
        _exit = exit;
        _spreads = new LastSpreadCache(Path.Combine(AppPaths.Library, "LastSpreads"));
        _importer = new BookImporter(_library, DetailsAsync);
        _exporter = new LibraryExporter(_library);
        _libraryImporter = new LibraryImporter(_library, _importer, _spreads);
        _reader = new ReaderView(_library, _spreads, ReaderSettings.Load(AppPaths.Settings));
        _shelf = new LibraryView(_library, book => OpenAsync(book), ImportAllAsync, () => _system.AnimationsEnabled);
        _library.Removing += id =>
        {
            _spreads.Remove(id);
            // The book open can't stay open once it's off the shelf.
            if (_reader.Record?.Id == id) _reader.CloseBook();
        };
        _reader.Read += (id, location) => _library.MarkRead(id, location);
        _reader.OpenFailed += (book, _) =>
        {
            ShowLibrary();
            _shelf.Say(ShelfText.Message(ImportError.Unreadable));
        };
        _reader.TitleChanged += title => _window.Title = string.IsNullOrEmpty(title) ? "Readme" : $"{title} — Readme";
        _reader.CommandRequested += Perform;
        _reader.UnhandledKey += key =>
        {
            if (key.Key == "o" && key.Modifiers == Modifiers.Ctrl) _ = ChooseBookAsync();
        };
        _reader.Intercept = key => _isShowingLibrary ? HandleKey(key) : null;
        _shelf.FocusLeft += () => _content.Focus(FocusState.Programmatic);
        _shelf.Export = books => ExportAsync(books);
        _shelf.ImportBundles = paths => ImportBundlesAsync(paths);
        _shelf.OpenFile = ChooseBookAsync;
        _shelf.ExportLibrary = () => ExportAsync(_library.Books);

        _hidden.Control.Width = 600;
        _hidden.Control.Height = 800;
        _hidden.Control.Opacity = 0;
        _hidden.Control.IsHitTestVisible = false;
        _hidden.Control.IsTabStop = false;
        _hidden.Control.HorizontalAlignment = HorizontalAlignment.Left;
        _hidden.Control.VerticalAlignment = VerticalAlignment.Top;
        _content.Children.Add(_hidden.Control);
        _content.Children.Add(_reader.Root);
        _content.Children.Add(_shelf.Root);
        _shelf.Root.Visibility = Visibility.Collapsed;
        _content.KeyDown += OnKeyDown;
        _content.IsTabStop = true;
        _window.Content = _content;
        _window.Title = "Readme";
        _window.AppWindow.Closing += OnClosing;
        _window.AppWindow.Changed += (_, change) =>
        {
            // The size it has when it's neither maximized nor full screen, which is what's restored.
            if ((change.DidPositionChange || change.DidSizeChange) && _window.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Restored })
                _restoredBounds = new RectInt32(_window.AppWindow.Position.X, _window.AppWindow.Position.Y, _window.AppWindow.Size.Width, _window.AppWindow.Size.Height);
        };
        _window.Closed += (_, _) => _exit();
    }

    public void Launch()
    {
        PlaceWindow();
        _window.Activate();
        _ = StartAsync();
    }

    async Task StartAsync()
    {
        var checks = Array.IndexOf(_arguments, "--checks");
        if (checks >= 0 && _arguments.Length > checks + 1)
        {
            var selfChecks = new SelfChecks(this, _reader, _library, _arguments[checks + 1], _arguments.Skip(checks + 2).ToArray());
            // The resume check is of the normal launch, so that happens first.
            if (_arguments.ElementAtOrDefault(checks + 2) == "resume") _ = OpenAsUsualAsync();
            await selfChecks.RunAsync();
            return;
        }
        await OpenAsUsualAsync();
    }

    /// <summary>Straight into the book last read, at its place, or the shelf; or the books given on the command line.</summary>
    async Task OpenAsUsualAsync()
    {
        // Books whose copy has gone are taken off the shelf quietly, as on Mac.
        _library.RemoveMissing(File.Exists);
        var (files, bundles) = LibraryView.Split(_arguments.Where(a => File.Exists(a)
            && (a.EndsWith(".epub", StringComparison.OrdinalIgnoreCase) || a.EndsWith(LibraryBundle.Extension, StringComparison.OrdinalIgnoreCase))));
        if (bundles.Count > 0)
        {
            // Straight to the library, not the last book, which would only be replaced.
            ShowLibrary(animated: false);
            await ImportBundlesAsync(bundles);
        }
        if (files.Count > 0)
        {
            await ImportAndOpenAsync(files);
            return;
        }
        if (bundles.Count > 0) return;
        switch (LaunchRoute.Resolve(_library, _library.Positions.Location, File.Exists))
        {
            case LaunchRoute.Read read:
                await OpenAsync(read.Book, read.Cfi);
                break;
            default:
                ShowLibrary(animated: false);
                break;
        }
    }

    // MARK: Window

    void PlaceWindow()
    {
        var appWindow = _window.AppWindow;
        var scale = ScaleOf(appWindow);
        if (appWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(MinimumWidth * scale);
            presenter.PreferredMinimumHeight = (int)(MinimumHeight * scale);
        }
        if (WindowPlacement.Load(AppPaths.Window) is { } placement && placement.Restore(appWindow)) return;
        // The first time: the mockup's stage, centred on the display.
        appWindow.ResizeClient(new SizeInt32((int)(ContentWidth * scale), (int)(ContentHeight * scale)));
        var work = DisplayArea.GetFromWindowId(appWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        appWindow.Move(new PointInt32(work.X + (work.Width - appWindow.Size.Width) / 2, work.Y + (work.Height - appWindow.Size.Height) / 2));
    }

    static double ScaleOf(AppWindow window)
    {
        var dpi = GetDpiForWindow(Win32Interop.GetWindowFromWindowId(window.Id));
        return dpi > 0 ? dpi / 96.0 : 1;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern uint GetDpiForWindow(nint hwnd);

    public void ToggleFullscreen()
    {
        var appWindow = _window.AppWindow;
        var on = appWindow.Presenter.Kind != AppWindowPresenterKind.FullScreen;
        _reader.SetFullscreen(on);
        appWindow.SetPresenter(on ? AppWindowPresenterKind.FullScreen : AppWindowPresenterKind.Overlapped);
    }

    /// <summary>
    /// Closing waits for the turns and restyles under way and writes the reader's place, then the
    /// window's, then the picture of the spread, then closes for real. The Mac does the same as it quits.
    /// </summary>
    async void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_closeKept) return;
        args.Cancel = true;
        if (_isClosing) return;
        _isClosing = true;
        try { await _reader.PlacesKeptAsync(); }
        catch (Exception error) { Debug.WriteLine(error); }
        var maximized = sender.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized };
        if (sender.Presenter.Kind == AppWindowPresenterKind.Overlapped || _restoredBounds != null)
            WindowPlacement.Of(sender, maximized, _restoredBounds).Save(AppPaths.Window);
        try { if (!_isShowingLibrary) await _reader.KeepPlaceAsync(); }
        catch (Exception error) { Debug.WriteLine(error); }
        _closeKept = true;
        _window.Close();
    }

    /// <summary>
    /// Closes the way the close button does (WM_CLOSE), which is what raises AppWindow.Closing and so
    /// keeps everything first. Window.Close() would skip that.
    /// </summary>
    public void CloseAsUser() => PostMessage(Win32Interop.GetWindowFromWindowId(_window.AppWindow.Id), 0x0010, 0, 0);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern bool PostMessage(nint hwnd, uint message, nint wParam, nint lParam);

    internal AppWindow AppWindow => _window.AppWindow;
    internal LibraryView Shelf => _shelf;
    internal bool IsShowingLibrary => _isShowingLibrary;

    // MARK: Keys

    /// <summary>
    /// Keys pressed with the focus outside the page. The page passes its own on, so a key pressed in it
    /// is left alone here, rather than acted on twice. Keys typed into the shelf's search are its own.
    /// </summary>
    void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var focused = FocusManager.GetFocusedElement(_content.XamlRoot);
        if (focused is WebView2 or TextBox) return;
        if (Keys.FromVirtualKey(e.Key, e.KeyStatus.WasKeyDown) is not { } key) return;
        e.Handled = HandleKey(key);
    }

    /// <summary>Over the shelf only what's about the window, the shelf's search and Esc do anything.</summary>
    internal bool HandleKey(PageKey key)
    {
        if (key.Key == "o" && key.Modifiers == Modifiers.Ctrl)
        {
            _ = ChooseBookAsync();
            return true;
        }
        if (!_isShowingLibrary) return _reader.HandleKey(key);
        if (key.Key == "l" && key.Modifiers == Modifiers.Ctrl) return true;
        switch (key.Key, key.Modifiers)
        {
            case ("Escape", Modifiers.None):
                _shelf.Escape(() => { if (_reader.Location != null) ShowBook(); });
                return true;
            case ("f", Modifiers.Ctrl):
                _shelf.OpenSearch();
                return true;
            case ("F11", Modifiers.None):
                ToggleFullscreen();
                return true;
            default:
                return false;
        }
    }

    void Perform(ReaderCommand command)
    {
        switch (command)
        {
            case ReaderCommand.ToggleFullscreen:
                ToggleFullscreen();
                break;
            case ReaderCommand.ShowLibrary:
                ShowLibrary();
                break;
        }
    }

    // MARK: Library

    /// <summary>Fades the shelf in over the book, which stays open beneath it at its place.</summary>
    public void ShowLibrary(bool animated = true)
    {
        if (_isShowingLibrary) return;
        _isShowingLibrary = true;
        _shelf.Rebuild();
        _shelf.Root.Visibility = Visibility.Visible;
        Fade(_shelf.Root, 1, animated);
        _reader.SetBehind(true);
        _window.Title = "Readme";
        _content.Focus(FocusState.Programmatic);
        _ = _reader.KeepPlaceAsync();
    }

    /// <summary>Fades the shelf away from over the book that's open.</summary>
    void ShowBook()
    {
        if (!_isShowingLibrary) return;
        _isShowingLibrary = false;
        _shelf.BookOpened();
        Fade(_shelf.Root, 0, true, () =>
        {
            if (!_isShowingLibrary) _shelf.Root.Visibility = Visibility.Collapsed;
        });
        _reader.SetBehind(false);
        if (_reader.Record is { } book) _window.Title = $"{book.Title} — Readme";
        _reader.Book.Control.Focus(FocusState.Programmatic);
    }

    void Fade(UIElement element, double to, bool animated, Action? done = null)
    {
        if (!animated || !_system.AnimationsEnabled)
        {
            element.Opacity = to;
            done?.Invoke();
            return;
        }
        var animation = new DoubleAnimation { To = to, Duration = new Duration(TimeSpan.FromMilliseconds(200)), EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } };
        Storyboard.SetTarget(animation, element);
        Storyboard.SetTargetProperty(animation, "Opacity");
        var storyboard = new Storyboard { Children = { animation } };
        storyboard.Completed += (_, _) => done?.Invoke();
        storyboard.Begin();
    }

    /// <summary>
    /// Opens a library book. The shelf stays until there's a book to show instead, so one that won't
    /// open leaves it where it is, with a notice.
    /// </summary>
    public async Task<bool> OpenAsync(Book book, string? cfi = null)
    {
        while (_combining.Contains(book.Id) && _combined != null) await _combined.Task;
        if (!File.Exists(_library.FilePath(book)))
        {
            _library.RemoveMissing(File.Exists);
            ShowLibrary();
            _shelf.Say("That book's file is no longer in the library folder.");
            return false;
        }
        // The same book, already open beneath the shelf: just put the shelf away.
        if (cfi == null && _reader.Record?.Id == book.Id && _reader.Location != null)
        {
            ShowBook();
            return true;
        }
        var opened = await _reader.OpenAsync(book, cfi);
        if (opened) ShowBook();
        return opened;
    }

    /// <summary>Ctrl+O: books, or library bundles, which the Mac's File menu has as Open… and Import….</summary>
    async Task ChooseBookAsync()
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".epub");
        picker.FileTypeFilter.Add(LibraryBundle.Extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        var files = await picker.PickMultipleFilesAsync();
        if (files.Count == 0) return;
        var (paths, bundles) = LibraryView.Split(files.Select(f => f.Path));
        if (bundles.Count > 0)
        {
            ShowLibrary();
            await ImportBundlesAsync(bundles);
        }
        if (paths.Count == 0) return;
        // Several books chosen at once are for the shelf, not for reading one of them.
        if (paths.Count > 1)
        {
            ShowLibrary();
            await _shelf.AddAsync(paths);
        }
        else await ImportAndOpenAsync(paths);
    }

    /// <summary>Adds the books and opens the first that could be added. Those that can't get a quiet line, never a dialog.</summary>
    public async Task ImportAndOpenAsync(IReadOnlyList<string> paths)
    {
        IReadOnlyList<(string Path, Book? Book, ImportError? Error)> results;
        if (_isShowingLibrary) results = await _shelf.AddAsync(paths);
        else
        {
            results = await ImportAllAsync(paths);
            var lines = ShelfText.Messages(results.Where(r => r.Error != null).Select(r => r.Error!.Value));
            if (lines.Count > 0)
            {
                if (_reader.Location == null)
                {
                    ShowLibrary(animated: false);
                    foreach (var line in lines) _shelf.Say(line);
                }
                else _reader.ShowNotice(string.Join("\n", lines));
            }
        }
        if (results.FirstOrDefault(r => r.Book != null).Book is { } book) await OpenAsync(book);
    }

    nint Hwnd => Win32Interop.GetWindowFromWindowId(_window.AppWindow.Id);

    // MARK: Library bundles

    /// <summary>
    /// Imports each bundle in turn, over the library. If some of a bundle's books are here already,
    /// the reader is asked what to do with them, unless <paramref name="answer"/> is given (null from it
    /// is Cancel). A book open in the reader that's about to be combined is closed first, so nothing it
    /// still holds is written over what the import brings, and it opens next on the place the import left.
    /// </summary>
    public async Task ImportBundlesAsync(IReadOnlyList<string> paths, Func<PreparedImport, ImportChoice?>? answer = null)
    {
        foreach (var path in paths)
        {
            ShowLibrary();
            PreparedImport prepared;
            try { prepared = await _libraryImporter.PrepareAsync(path); }
            catch (BundleException error)
            {
                _shelf.Say(error.Message);
                continue;
            }
            var choice = ImportChoice.KeepMine;
            if (prepared.ExistingIds.Count > 0)
            {
                var asked = answer != null
                    ? answer(prepared)
                    : await AskImportChoiceAsync(prepared.ExistingIds.Count, prepared.Bundle.Manifest.BookIds.Count);
                if (asked == null) continue;
                choice = asked.Value;
            }
            if (choice == ImportChoice.Combine && _reader.Record?.Id is { } open && prepared.ExistingIds.Contains(open))
            {
                await _reader.PlacesKeptAsync();
                _reader.CloseBook();
            }
            if (choice == ImportChoice.Combine)
            {
                _combining.UnionWith(prepared.ExistingIds);
                _combined = new TaskCompletionSource();
            }
            _shelf.SetWorking(LibraryView.WorkingLine("Importing", prepared.Bundle.Manifest.BookIds.Count));
            ImportSummary summary;
            try { summary = await _libraryImporter.RunAsync(prepared, choice); }
            finally
            {
                _combining.Clear();
                _combined?.TrySetResult();
                _combined = null;
                _shelf.SetWorking(null);
            }
            _shelf.Say(summary.Line);
        }
    }

    /// <summary>Keep Mine, Combine, or Cancel, which is null. Enter is Keep Mine, Esc is Cancel.</summary>
    async Task<ImportChoice?> AskImportChoiceAsync(int existing, int total)
    {
        if (_openDialog != null) return null;
        var dialog = new ContentDialog
        {
            Title = ImportQuestion.Message(existing, total),
            Content = new TextBlock { Text = ImportQuestion.Informative, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = ImportQuestion.Buttons[0],
            SecondaryButtonText = ImportQuestion.Buttons[1],
            CloseButtonText = ImportQuestion.Buttons[2],
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = _content.XamlRoot,
            RequestedTheme = ElementTheme.Dark,
        };
        _openDialog = dialog;
        try
        {
            return await dialog.ShowAsync() switch
            {
                ContentDialogResult.Primary => ImportChoice.KeepMine,
                ContentDialogResult.Secondary => ImportChoice.Combine,
                _ => null,
            };
        }
        finally
        {
            _openDialog = null;
        }
    }

    /// <summary>For the self-checks: the question showing, if one is.</summary>
    internal ContentDialog? OpenDialog => _openDialog;

    /// <summary>
    /// Asks where to save <paramref name="books"/>, unless <paramref name="destination"/> is given, and
    /// writes them there. How it went is said on the shelf.
    /// </summary>
    public async Task ExportAsync(IReadOnlyList<Book> books, string? destination = null)
    {
        if (books.Count == 0) return;
        ShowLibrary();
        var path = destination ?? await ChooseExportDestinationAsync(books.Count == 1 ? books[0].Title : "Readme Library");
        if (path == null) return;
        _shelf.SetWorking(LibraryView.WorkingLine("Exporting", books.Count));
        try
        {
            var summary = await _exporter.ExportAsync(books, path);
            _shelf.Say(summary.Line);
        }
        catch (BundleException error)
        {
            _shelf.Say(error.Message);
        }
        finally
        {
            _shelf.SetWorking(null);
        }
    }

    async Task<string?> ChooseExportDestinationAsync(string suggestedName)
    {
        var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, SuggestedFileName = SafeFileName(suggestedName) };
        picker.FileTypeChoices.Add("Readme library", [LibraryBundle.Extension]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        var file = await picker.PickSaveFileAsync();
        return file?.Path;
    }

    /// <summary>A title as a file name: the characters Windows won't have in one become spaces.</summary>
    internal static string SafeFileName(string title)
    {
        var bad = Path.GetInvalidFileNameChars();
        var name = new string(title.Select(c => bad.Contains(c) ? ' ' : c).ToArray()).Trim().TrimEnd('.').Trim();
        return string.IsNullOrWhiteSpace(name) ? "Readme Library" : name;
    }

    Task<IReadOnlyList<(string Path, Book? Book, ImportError? Error)>> ImportAllAsync(IReadOnlyList<string> paths) =>
        _importer.ImportAllAsync(paths);

    /// <summary>
    /// Opens a staged book in the hidden view, for its title, author and cover. One at a time, since
    /// there's one view. A book that won't open throws, and the importer calls it unreadable.
    /// </summary>
    async Task<BookDetails> DetailsAsync(string path)
    {
        await _hiddenTurn.WaitAsync();
        try
        {
            await _hidden.OpenAsync(path, null);
            var (title, author) = await _hidden.BookInfoAsync();
            var cover = await _hidden.CoverAsync();
            var png = cover == null ? null : await CoverImages.PngAsync(cover);
            _hidden.Unload();
            return new BookDetails(title, author, png);
        }
        catch (Exception error)
        {
            Log.Write($"import: opening in the hidden view failed: {error}");
            throw;
        }
        finally
        {
            _hiddenTurn.Release();
        }
    }
}
