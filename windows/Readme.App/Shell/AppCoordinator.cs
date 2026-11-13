using System.Diagnostics;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Readme.App.Reader;
using Readme.Core.Layout;
using Readme.Core.Model;
using Readme.Core.Reader;
using Readme.Core.Storage;
using Readme.Core.Zip;
using Windows.Graphics;
using Windows.Storage.Pickers;

namespace Readme.App;

/// <summary>
/// Owns the library, the window and the reader (AppCoordinator.swift and the window parts of
/// ReadmeApp.swift): where the app opens, opening books, full screen, and keeping everything on close.
/// Until the shelf arrives (phase 3), the library is a plain list with an Open button.
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
    readonly Window _window = new();
    readonly Grid _content = new();
    readonly ReaderView _reader;
    readonly Grid _libraryPanel = new();
    readonly StackPanel _bookList = new() { Spacing = 4 };
    readonly TextBlock _libraryMessage = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Opacity = 0.75, MaxWidth = 420 };
    readonly Button _settingsButton = new() { Content = "Aa", HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 8, 12, 0), Padding = new Thickness(10, 2, 10, 4), Opacity = 0.8 };
    bool _isShowingLibrary;
    bool _isClosing;
    bool _closeKept;
    RectInt32? _restoredBounds;

    public AppCoordinator(string[] arguments, Action exit)
    {
        _arguments = arguments;
        _exit = exit;
        _reader = new ReaderView(_library, ReaderSettings.Load(AppPaths.Settings));
        _reader.Read += (id, location) => _library.MarkRead(id, location);
        _reader.OpenFailed += (book, _) => ShowLibrary($"“{book.Title}” couldn't be opened.");
        _reader.TitleChanged += title => _window.Title = $"{title} — Readme";
        _reader.CommandRequested += Perform;
        _reader.UnhandledKey += key =>
        {
            if (key.Key == "o" && key.Modifiers == Modifiers.Ctrl) _ = ChooseBookAsync();
        };

        BuildLibraryPanel();
        _settingsButton.Flyout = SettingsMenu();
        _content.Children.Add(_reader.Root);
        _content.Children.Add(_libraryPanel);
        _content.Children.Add(_settingsButton);
        _content.KeyDown += OnKeyDown;
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

    async Task OpenAsUsualAsync()
    {
        var file = _arguments.FirstOrDefault(a => a.EndsWith(".epub", StringComparison.OrdinalIgnoreCase) && File.Exists(a));
        if (file != null)
        {
            await ImportAndOpenAsync(file);
            return;
        }
        switch (LaunchRoute.Resolve(_library, _library.Positions.Location, File.Exists))
        {
            case LaunchRoute.Read read:
                await OpenAsync(read.Book, read.Cfi);
                break;
            default:
                ShowLibrary();
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
        _settingsButton.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>
    /// Closing waits for the turns and restyles under way and writes the reader's place, then the
    /// window's, then closes for real. The Mac does the same as it quits.
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
        _closeKept = true;
        _window.Close();
    }

    public void Close() => _window.AppWindow.Destroy();

    /// <summary>
    /// Closes the way the close button does (WM_CLOSE), which is what raises AppWindow.Closing and so
    /// keeps everything first. Window.Close() would skip that.
    /// </summary>
    public void CloseAsUser() => PostMessage(Win32Interop.GetWindowFromWindowId(_window.AppWindow.Id), 0x0010, 0, 0);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern bool PostMessage(nint hwnd, uint message, nint wParam, nint lParam);

    internal AppWindow AppWindow => _window.AppWindow;

    // MARK: Keys

    /// <summary>
    /// Keys pressed with the focus outside the page. The page passes its own on, so a key pressed in it
    /// is left alone here, rather than acted on twice.
    /// </summary>
    void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (FocusManager.GetFocusedElement(_content.XamlRoot) is WebView2) return;
        if (Keys.FromVirtualKey(e.Key, e.KeyStatus.WasKeyDown) is not { } key) return;
        if (key.Key == "o" && key.Modifiers == Modifiers.Ctrl)
        {
            _ = ChooseBookAsync();
            e.Handled = true;
            return;
        }
        if (_isShowingLibrary)
        {
            if (key.Key == "Escape" && _reader.Location != null) ShowBook();
            else if (key.Key == "F11" || (key.Key == "f" && key.Modifiers == Modifiers.None)) ToggleFullscreen();
            else return;
            e.Handled = true;
            return;
        }
        e.Handled = _reader.HandleKey(key);
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
            // Contents, highlights, marker, go to page, find and shortcuts arrive in phase 4.
        }
    }

    // MARK: Library

    void BuildLibraryPanel()
    {
        var colors = ReadingCss.Colors(Theme.Paper);
        _libraryPanel.Background = new SolidColorBrush(Windows.UI.Color.FromArgb(255, colors.Desk.R, colors.Desk.G, colors.Desk.B));
        _libraryPanel.RequestedTheme = ElementTheme.Dark;
        var open = new Button { Content = "Open a Book…", HorizontalAlignment = HorizontalAlignment.Center };
        open.Click += (_, _) => _ = ChooseBookAsync();
        ToolTipService.SetToolTip(open, "Ctrl+O");
        var panel = new StackPanel { Spacing = 16, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 460 };
        panel.Children.Add(new TextBlock { Text = "Readme", FontSize = 30, FontFamily = new FontFamily("Georgia"), HorizontalAlignment = HorizontalAlignment.Center });
        panel.Children.Add(_libraryMessage);
        panel.Children.Add(open);
        panel.Children.Add(new ScrollViewer { Content = _bookList, MaxHeight = 360 });
        _libraryPanel.Children.Add(panel);
        _libraryPanel.Visibility = Visibility.Collapsed;
    }

    public void ShowLibrary(string? message = null)
    {
        _isShowingLibrary = true;
        _libraryMessage.Text = message ?? (_library.Books.Count == 0
            ? "Your library is empty. Open an EPUB to start reading."
            : "The shelf arrives in the next build. For now, pick a book.");
        _bookList.Children.Clear();
        foreach (var book in new[] { _library.Current }.Concat(_library.Others).OfType<Book>())
        {
            var item = new Button
            {
                Content = book.Author is { } author ? $"{book.Title} — {author}" : book.Title,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = new SolidColorBrush(Colors.Transparent),
            };
            item.Click += (_, _) => _ = OpenAsync(book);
            _bookList.Children.Add(item);
        }
        _libraryPanel.Visibility = Visibility.Visible;
        _settingsButton.Visibility = Visibility.Collapsed;
        _window.Title = "Readme";
    }

    void ShowBook()
    {
        _isShowingLibrary = false;
        _libraryPanel.Visibility = Visibility.Collapsed;
        _settingsButton.Visibility = _window.AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen ? Visibility.Collapsed : Visibility.Visible;
        _reader.Book.Control.Focus(FocusState.Programmatic);
    }

    public async Task<bool> OpenAsync(Book book, string? cfi = null)
    {
        if (!File.Exists(_library.FilePath(book)))
        {
            _library.RemoveMissing(File.Exists);
            ShowLibrary($"“{book.Title}” is no longer in the library folder.");
            return false;
        }
        var opened = await _reader.OpenAsync(book, cfi);
        if (!opened) return false;
        ShowBook();
        // A book added under its file name learns its real title and author once it's open.
        if (_library.Book(book.Id) is { } record && record.Author == null)
        {
            var (title, author) = await _reader.Book.BookInfoAsync();
            if (!string.IsNullOrWhiteSpace(title) && (title != record.Title || author != null))
            {
                _library.SetDetails(record.Id, title, author);
                _window.Title = $"{title} — Readme";
            }
        }
        return true;
    }

    async Task ChooseBookAsync()
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".epub");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Win32Interop.GetWindowFromWindowId(_window.AppWindow.Id));
        var file = await picker.PickSingleFileAsync();
        if (file != null) await ImportAndOpenAsync(file.Path);
    }

    /// <summary>
    /// Checks the file, copies it into the library as <c>&lt;id&gt;.epub</c> and opens it. The same book
    /// twice is one book. Phase 3 replaces this with the full importer (covers, a hidden check).
    /// </summary>
    public async Task<bool> ImportAndOpenAsync(string path)
    {
        try
        {
            EpubInspector.Check(path);
            var id = await BookId.OfAsync(path);
            if (_library.Book(id) is not { } book)
            {
                Directory.CreateDirectory(_library.BooksDirectory);
                var destination = Path.Combine(_library.BooksDirectory, id + ".epub");
                if (!File.Exists(destination))
                {
                    var temporary = destination + ".tmp";
                    File.Copy(path, temporary, overwrite: true);
                    File.Move(temporary, destination, overwrite: true);
                }
                book = new Book
                {
                    Id = id,
                    Title = Path.GetFileNameWithoutExtension(path),
                    FileName = id + ".epub",
                    HasCover = false,
                    AddedAt = DateTimeOffset.UtcNow,
                };
                _library.Add(book);
            }
            return await OpenAsync(_library.Book(id)!);
        }
        catch (ImportException error)
        {
            ShowLibrary(error.Error switch
            {
                ImportError.NotAnEpub => "This file isn't an EPUB book.",
                ImportError.CopyProtected => "This book is copy-protected, so it can't be opened here.",
                _ => "This book couldn't be read.",
            });
            return false;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            ShowLibrary("This book couldn't be read.");
            return false;
        }
    }

    // MARK: Settings menu

    /// <summary>Theme, font, line width and text size. The toolbar of phase 4 takes this over.</summary>
    MenuFlyout SettingsMenu()
    {
        var menu = new MenuFlyout();
        void Group<T>(string title, IEnumerable<(string Label, T Value)> choices, Func<ReaderSettings, T> current, Func<ReaderSettings, T, ReaderSettings> apply)
        {
            var sub = new MenuFlyoutSubItem { Text = title };
            foreach (var (label, value) in choices)
            {
                var item = new RadioMenuFlyoutItem { Text = label, GroupName = title };
                item.Click += (_, _) => _reader.Change(apply(_reader.Settings, value));
                sub.Items.Add(item);
            }
            menu.Opening += (_, _) =>
            {
                foreach (var (item, (_, value)) in sub.Items.OfType<RadioMenuFlyoutItem>().Zip(choices))
                    item.IsChecked = EqualityComparer<T>.Default.Equals(value, current(_reader.Settings));
            };
            menu.Items.Add(sub);
        }
        Group("Theme", [("Auto", ThemeChoice.Auto), ("Paper", ThemeChoice.Paper), ("Sepia", ThemeChoice.Sepia), ("Night", ThemeChoice.Night)],
            s => s.Theme, (s, v) => s with { Theme = v });
        Group("Font", [("EB Garamond", BookFont.EbGaramond), ("Literata", BookFont.Literata), ("Fraunces", BookFont.Fraunces)],
            s => s.Font, (s, v) => s with { Font = v });
        Group("Line Width", [("Narrow", LineWidth.Narrow), ("Regular", LineWidth.Regular), ("Wide", LineWidth.Wide)],
            s => s.LineWidth, (s, v) => s with { LineWidth = v });
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach (var command in new[] { ReaderCommand.BiggerText, ReaderCommand.SmallerText, ReaderCommand.ToggleFullscreen, ReaderCommand.ShowLibrary })
        {
            var item = new MenuFlyoutItem { Text = command.Title(), KeyboardAcceleratorTextOverride = command.Shortcut().Label };
            item.Click += (_, _) => _reader.Perform(command);
            menu.Items.Add(item);
        }
        var open = new MenuFlyoutItem { Text = "Open a Book…", KeyboardAcceleratorTextOverride = "Ctrl+O" };
        open.Click += (_, _) => _ = ChooseBookAsync();
        menu.Items.Add(open);
        menu.Closed += (_, _) => _reader.Book.Control.Focus(FocusState.Programmatic);
        return menu;
    }
}
