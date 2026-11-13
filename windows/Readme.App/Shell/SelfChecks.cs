using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Readme.App.Reader;
using Readme.Core.Model;
using Readme.Core.Reader;
using Readme.Core.Storage;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Readme.App;

/// <summary>
/// <c>Readme.exe --checks &lt;dir&gt; read &lt;book.epub&gt;</c> reads a book the way a person would, with
/// keys sent into the page through the DevTools protocol, then closes the way the close button does.
/// <c>--checks &lt;dir&gt; resume</c> launches as usual and records where the book reopened. Each writes
/// <c>&lt;mode&gt;.json</c> and window screenshots to the folder. Run with README_DATA_DIR set, so the
/// reader's own library and settings are never touched.
/// </summary>
sealed class SelfChecks(AppCoordinator app, ReaderView reader, LibraryStore library, string outDir, string[] rest)
{
    readonly Dictionary<string, object?> _results = [];
    static readonly JsonSerializerOptions Indented = new() { WriteIndented = true };

    public async Task RunAsync()
    {
        Directory.CreateDirectory(outDir);
        var mode = rest.FirstOrDefault() ?? "read";
        try
        {
            if (mode == "resume") await ResumeAsync();
            else if (mode == "calibrate") await CalibrateAsync(rest[1], rest[2]);
            else if (mode == "whole") await WholeBookAsync(rest[1]);
            else if (mode == "shelf") await ShelfAsync(rest[1]);
            else await ReadAsync(rest.ElementAtOrDefault(1) ?? throw new ArgumentException("read needs a book"));
        }
        catch (Exception error)
        {
            Record("error", error.ToString());
        }
        Record("done", true);
        Save(mode);
        app.CloseAsUser();
    }

    async Task ReadAsync(string epub)
    {
        await app.ImportAndOpenAsync([epub]);
        Record("opened", reader.Location != null);
        await Task.Delay(800);
        Record("atOpen", Where());
        await Shot("1-open");

        await Key("End", ctrl: true);
        Record("afterCtrlEnd", Where());
        await Key("Home", ctrl: true);
        Record("afterCtrlHome", Where());

        for (var i = 0; i < 25; i++) await Key("ArrowRight", delay: 350);
        for (var i = 0; i < 3; i++) await Key("ArrowLeft", delay: 350);
        await Key(" ", delay: 500);
        Record("afterTurns", Where());
        await Shot("2-turned");

        // A wheel notch does nothing, down or sideways.
        await Task.Delay(1000);
        await reader.Book.SettleAsync();
        var before = reader.Location?.Cfi;
        foreach (var (dx, dy) in new[] { (0, 120), (0, -120), (120, 0) })
            await reader.Book.DevToolsAsync("Input.dispatchMouseEvent", new { type = "mouseWheel", x = 400, y = 300, deltaX = dx, deltaY = dy });
        await Task.Delay(1000);
        await reader.Book.SettleAsync();
        Record("wheelLeftThePageAlone", new { same = reader.Location?.Cfi == before, before, after = reader.Location?.Cfi });

        var place = reader.Location;
        await Key("=", ctrl: true, delay: 1500);
        Record("afterBiggerText", Where());
        Record("biggerTextKeptPlaceNear", Near(place, reader.Location));
        await Key("-", ctrl: true, delay: 1500);

        reader.Change(reader.Settings with { Theme = ThemeChoice.Sepia, Font = Core.Layout.BookFont.Fraunces });
        await Task.Delay(1500);
        await Shot("3-sepia-fraunces");
        reader.Change(reader.Settings with { Theme = ThemeChoice.Night, Font = Core.Layout.BookFont.Literata });
        await Task.Delay(1500);
        await Shot("4-night-literata");

        place = reader.Location;
        Resize(760, 620);
        await Task.Delay(1500);
        Record("narrow", Where());
        Record("narrowKeptPlaceNear", Near(place, reader.Location));
        await Shot("5-narrow");
        Resize(1048, 620);
        await Task.Delay(1500);

        place = reader.Location;
        await Key("F11", delay: 2000);
        Record("fullscreen", new { reader.IsFullscreen, presenter = app.AppWindow.Presenter.Kind.ToString(), at = Where() });
        await Shot("6-fullscreen");
        await Key("Escape", delay: 2000);
        Record("leftFullscreen", new { reader.IsFullscreen, presenter = app.AppWindow.Presenter.Kind.ToString(), at = Where() });
        Record("fullscreenKeptPlaceNear", Near(place, reader.Location));

        reader.Change(reader.Settings with { Theme = ThemeChoice.Auto, Font = Core.Layout.BookFont.EbGaramond });
        await Task.Delay(1200);
        await Key("ArrowRight", delay: 800);
        Record("final", Where());
        Record("libraryCurrent", library.Current?.Title);
        // Somewhere the next launch should put it back.
        app.AppWindow.Move(new PointInt32(app.AppWindow.Position.X + 40, app.AppWindow.Position.Y + 30));
        await Task.Delay(300);
        Record("windowAtClose", new { app.AppWindow.Position.X, app.AppWindow.Position.Y, app.AppWindow.Size.Width, app.AppWindow.Size.Height });
    }

    /// <summary>
    /// Characters per line for each font and line width in Chromium, as the Mac's LineLengthTests
    /// measure them in WebKit: averaged over paragraphs of four lines or more, leaving out each last
    /// line. Then pages through the wide-content fixture for the long-word, table and pre rules.
    /// </summary>
    async Task CalibrateAsync(string longBook, string wideBook)
    {
        await app.ImportAndOpenAsync([longBook]);
        await Task.Delay(800);
        // As the Mac's LineLengthTests: the book view 1600 by 900, styled directly. Its character
        // widths were calibrated at this size, where the bridge's columns come out as asked.
        reader.Book.Control.Width = 1600;
        reader.Book.Control.Height = 900;
        await Task.Delay(500);
        await reader.Book.ResizedAsync(1600);
        var rows = new List<object>();
        foreach (var font in Enum.GetValues<Core.Layout.BookFont>())
        {
            foreach (var width in Enum.GetValues<Core.Layout.LineWidth>())
            {
                var settings = new ReaderSettings { Font = font, LineWidth = width, FontSize = 18, Theme = ThemeChoice.Paper };
                var columns = Core.Layout.SpreadLayout.Columns(1600, 18, width, 900, font);
                await reader.Book.ApplyStylesAsync(ReadingCss.Css(settings, Theme.Paper, false), columns,
                    Core.Layout.SpreadLayout.ColumnWidth(18, font, width));
                await Task.Delay(700);
                await reader.Book.SettleAsync();
                var measured = await reader.Book.EvaluateAsync("""
                    (async () => {
                        const doc = readmeBridge.currentDocument()
                        for (const face of ['EB Garamond', 'Literata', 'Fraunces']) await doc.fonts.load(`18px "${face}"`)
                        let characters = 0, lines = 0, rects = 0, width = 0, paragraphs = 0
                        for (const p of doc.querySelectorAll('p')) {
                            const range = doc.createRange()
                            range.selectNodeContents(p)
                            const all = [...range.getClientRects()]
                            // A line is a row of boxes; Chromium may give several boxes for one line.
                            const count = new Set(all.map(r => Math.round(r.top))).size
                            if (count < 4) continue
                            characters += p.textContent.length * (count - 1) / count
                            lines += count - 1
                            rects += all.length
                            width += p.getBoundingClientRect().width
                            paragraphs++
                        }
                        return {
                            perLine: lines === 0 ? 0 : characters / lines,
                            boxesPerLine: lines === 0 ? 0 : rects / (lines + paragraphs),
                            textWidth: paragraphs ? width / paragraphs : 0,
                            family: getComputedStyle(doc.body).fontFamily,
                            hyphens: getComputedStyle(doc.body.querySelector('p')).hyphens,
                            lang: doc.documentElement.lang,
                            fontSize: getComputedStyle(doc.body.querySelector('p')).fontSize,
                            columnCss: getComputedStyle(doc.documentElement).columnWidth,
                            frame: doc.defaultView.frameElement?.getBoundingClientRect().width,
                            renderer: document.querySelector('foliate-view').renderer.getBoundingClientRect().width,
                            maxInline: document.querySelector('foliate-view').renderer.getAttribute('max-inline-size'),
                            gap: document.querySelector('foliate-view').renderer.getAttribute('gap'),
                            dpr: devicePixelRatio,
                        }
                    })()
                    """);
                var perLine = measured.GetProperty("perLine").GetDouble();
                var target = Core.Layout.SpreadLayout.Characters(width);
                rows.Add(new
                {
                    font = font.ToString(), width = width.ToString(), perLine = Math.Round(perLine, 1), target,
                    // The character width that would have hit the target exactly.
                    impliedCharacterWidth = perLine > 0 ? Math.Round(Core.Layout.SpreadLayout.CharacterWidth(font) * perLine / target, 3) : 0,
                    family = measured.GetProperty("family").GetString(),
                    boxesPerLine = Math.Round(measured.GetProperty("boxesPerLine").GetDouble(), 2),
                    textWidth = Math.Round(measured.GetProperty("textWidth").GetDouble(), 1),
                    askedColumnWidth = Math.Round(Core.Layout.SpreadLayout.ColumnWidth(18, font, width), 1),
                    columns = reader.Book.Columns,
                    probe = measured.ToString(),
                    hyphens = measured.GetProperty("hyphens").GetString(),
                    lang = measured.GetProperty("lang").GetString(),
                });
            }
        }
        Record("lineLengths", rows);

        reader.Change(new ReaderSettings { Theme = ThemeChoice.Paper, FontSize = 19 });
        await app.ImportAndOpenAsync([wideBook]);
        await Task.Delay(1000);
        for (var page = 0; page < 6; page++)
        {
            var overflow = await reader.Book.EvaluateAsync("""
                (() => {
                    const doc = readmeBridge.currentDocument()
                    const view = doc.defaultView
                    const columns = parseFloat(getComputedStyle(doc.documentElement).columnWidth) || 0
                    let worst = 0, tag = null
                    for (const el of doc.body.querySelectorAll('*')) {
                        const over = el.scrollWidth - el.clientWidth
                        if (over > worst && getComputedStyle(el).overflowX !== 'auto') { worst = over; tag = el.tagName }
                    }
                    return { columnWidth: columns, worstOverflow: worst, tag }
                })()
                """);
            Record($"wide-{page}", new { at = Where(), overflow });
            await Shot($"wide-{page}");
            await Key("ArrowRight", delay: 900);
        }
    }

    /// <summary>
    /// The phase 3 "done when": import five books (and two that must be refused), see their covers,
    /// open one, read, back to the shelf with Ctrl+L, switch to another; then pin, search, remove.
    /// </summary>
    async Task ShelfAsync(string fixtures)
    {
        string Fixture(string name) => Path.Combine(fixtures, name);
        app.ShowLibrary(animated: false);
        await Task.Delay(1000);
        await Shot("s1-empty-shelf");

        var five = new[] { "long.epub", "search.epub", "spreads.epub", "no-cover.epub", "wide-content.epub" };
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var results = await app.Shelf.AddAsync(five.Concat(["drm.epub", "not-an-epub.epub"]).Select(Fixture).ToList());
        Record("import", new
        {
            seconds = Math.Round(clock.Elapsed.TotalSeconds, 1),
            books = results.Select(r => new { file = Path.GetFileName(r.Path), r.Book?.Title, r.Book?.Author, r.Book?.HasCover, error = r.Error?.ToString() }),
        });
        await Task.Delay(1200);
        await Shot("s2-five-books");
        Record("shelfAfterImport", app.Shelf.ShownTitles());

        Book ById(string file) => library.Books.First(b => b.Id == results.First(r => Path.GetFileName(r.Path) == file).Book!.Id);
        var search = ById("search.epub");
        Record("openedSearch", await app.OpenAsync(search));
        await Task.Delay(800);
        for (var i = 0; i < 3; i++) await Key("ArrowRight", delay: 600);
        Record("searchAt", Where());
        await Key("l", ctrl: true, delay: 1200);
        Record("ctrlLShowsShelf", app.IsShowingLibrary);
        await Shot("s3-shelf-after-reading");
        Record("ledgeAfterReading", library.Current?.Title);

        var longBook = ById("long.epub");
        Record("openedLong", await app.OpenAsync(longBook));
        await Task.Delay(800);
        await Key("ArrowRight", delay: 800);
        Record("longAt", Where());
        await Key("l", ctrl: true, delay: 1000);
        Record("ledgeAfterSwitch", library.Current?.Title);

        library.SetPinned([ById("no-cover.epub").Id], true);
        await Task.Delay(800);
        Record("orderWithPin", app.Shelf.ShownTitles());
        await Shot("s4-pinned");

        app.Shelf.Type("spread");
        await Task.Delay(800);
        Record("searchSpread", app.Shelf.ShownTitles());
        await Shot("s5-search");
        app.Shelf.Type("zzz");
        await Task.Delay(600);
        await Shot("s6-no-match");
        app.Shelf.CloseSearch();
        await Task.Delay(400);

        var wide = ById("wide-content.epub");
        library.Remove(wide.Id);
        await Task.Delay(600);
        Record("removed", new
        {
            gone = library.Book(wide.Id) == null,
            copyGone = !File.Exists(library.FilePath(wide)),
            coverGone = !File.Exists(library.CoverPath(wide)),
            shelf = app.Shelf.ShownTitles(),
        });

        // Esc puts the shelf away over the book that's open.
        app.HandleKey(new PageKey("Escape", Core.Reader.Modifiers.None, false));
        await Task.Delay(800);
        Record("escapeBackToBook", new { showingShelf = app.IsShowingLibrary, at = Where() });
        await Key("ArrowRight", delay: 1500);
        Record("lastSpreads", Directory.Exists(Path.Combine(library.Directory, "LastSpreads"))
            ? Directory.GetFiles(Path.Combine(library.Directory, "LastSpreads")).Select(Path.GetFileName).ToList() : []);
        Record("libraryFiles", Directory.GetFiles(library.BooksDirectory).Length);
    }

    /// <summary>Reads the whole book with the arrow key, from the first page to the last, then back a few.</summary>
    async Task WholeBookAsync(string book)
    {
        await app.ImportAndOpenAsync([book]);
        await Task.Delay(800);
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var turns = 0;
        var pages = new List<int>();
        while (reader.Location is { IsAtEnd: false } && turns < 600)
        {
            await Key("ArrowRight", delay: 500);
            turns++;
            if (reader.Location is { } at) pages.Add(at.Page);
        }
        await reader.Book.SettleAsync();
        Record("whole", new
        {
            turns,
            seconds = Math.Round(clock.Elapsed.TotalSeconds, 1),
            reachedEnd = reader.Location?.IsAtEnd,
            // Pages only ever go forward while turning forward.
            backwardSteps = pages.Zip(pages.Skip(1)).Count(p => p.Second < p.First),
            at = Where(),
        });
        for (var i = 0; i < 5; i++) await Key("ArrowLeft", delay: 400);
        Record("final", Where());
    }

    async Task ResumeAsync()
    {
        for (var i = 0; i < 100 && reader.Location == null; i++) await Task.Delay(150);
        await Task.Delay(800);
        Record("reopened", Where());
        Record("window", new { app.AppWindow.Position.X, app.AppWindow.Position.Y, app.AppWindow.Size.Width, app.AppWindow.Size.Height });
        await Shot("7-reopened");
        // Where the saved place lands once everything has loaded, against where the reopen put it.
        if (reader.BookId is { } id && library.Positions.Location(id) is { } saved)
        {
            Record("saved", new { saved.Page, saved.Cfi });
            Record("placeAfterOpen", await reader.Book.PlaceAsync());
            await reader.Book.GoToCfiAsync(saved.Cfi);
            await reader.Book.SettleAsync();
            Record("goToSavedAgain", Where());
            var probe = await reader.Book.EvaluateAsync("""
                ({ fontsLoaded: [...readmeBridge.currentDocument().fonts].map(f => f.family + ':' + f.status).join(' '),
                   size: (() => { const r = document.querySelector('foliate-view').renderer.getBoundingClientRect(); return r.width + 'x' + r.height })() })
                """);
            Record("probe", probe.ToString());
        }
    }

    object? Where() => reader.Location is { } l
        ? new { l.Page, l.PageCount, l.Cfi, l.ChapterTitle, l.IsAtStart, l.IsAtEnd, l.Fraction, columns = reader.Book.Columns }
        : null;

    /// <summary>Within a page or two either way: pages are runs of text, so a layout change keeps the number.</summary>
    static bool Near(ReaderLocation? before, ReaderLocation? after) =>
        before != null && after != null && Math.Abs(before.Page - after.Page) <= 2;

    async Task Key(string key, bool ctrl = false, int delay = 900)
    {
        var (code, vk) = key switch
        {
            "ArrowRight" => ("ArrowRight", 39), "ArrowLeft" => ("ArrowLeft", 37), " " => ("Space", 32),
            "Home" => ("Home", 36), "End" => ("End", 35), "F11" => ("F11", 122), "Escape" => ("Escape", 27),
            "=" => ("Equal", 187), "-" => ("Minus", 189),
            { Length: 1 } letter when char.IsAsciiLetterLower(letter[0]) => ("Key" + letter.ToUpperInvariant(), letter[0] - 'a' + 65),
            _ => throw new ArgumentException(key),
        };
        var modifiers = ctrl ? 2 : 0;
        await reader.Book.DevToolsAsync("Input.dispatchKeyEvent", new { type = "rawKeyDown", key, code, windowsVirtualKeyCode = vk, nativeVirtualKeyCode = vk, modifiers });
        await reader.Book.DevToolsAsync("Input.dispatchKeyEvent", new { type = "keyUp", key, code, windowsVirtualKeyCode = vk, nativeVirtualKeyCode = vk, modifiers });
        await Task.Delay(delay);
    }

    void Resize(int width, int height)
    {
        var scale = GetDpiForWindow(Hwnd) / 96.0;
        app.AppWindow.ResizeClient(new SizeInt32((int)(width * scale), (int)(height * scale)));
    }

    nint Hwnd => Win32Interop.GetWindowFromWindowId(app.AppWindow.Id);

    void Record(string name, object? value) => _results[name] = value;

    void Save(string mode) => File.WriteAllText(Path.Combine(outDir, mode + ".json"), JsonSerializer.Serialize(_results, Indented));

    /// <summary>The whole window, WebView2 included, as a PNG.</summary>
    async Task Shot(string name)
    {
        try
        {
            GetClientRect(Hwnd, out var rect);
            int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
            var screen = GetDC(Hwnd);
            var memory = CreateCompatibleDC(screen);
            var bitmap = CreateCompatibleBitmap(screen, width, height);
            var old = SelectObject(memory, bitmap);
            PrintWindow(Hwnd, memory, 0x1 | 0x2); // client area, full content
            var info = new BITMAPINFOHEADER { biSize = 40, biWidth = width, biHeight = -height, biPlanes = 1, biBitCount = 32 };
            var pixels = new byte[width * height * 4];
            GetDIBits(memory, bitmap, 0, (uint)height, pixels, ref info, 0);
            SelectObject(memory, old);
            DeleteObject(bitmap);
            DeleteDC(memory);
            ReleaseDC(Hwnd, screen);
            for (var i = 3; i < pixels.Length; i += 4) pixels[i] = 255;
            using var stream = new InMemoryRandomAccessStream();
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)width, (uint)height, 96, 96, pixels);
            await encoder.FlushAsync();
            var bytes = new byte[stream.Size];
            stream.Seek(0);
            using var data = new DataReader(stream);
            await data.LoadAsync((uint)stream.Size);
            data.ReadBytes(bytes);
            await File.WriteAllBytesAsync(Path.Combine(outDir, name + ".png"), bytes);
        }
        catch (Exception error)
        {
            Record("shotError-" + name, error.Message);
        }
    }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER
    {
        public uint biSize; public int biWidth, biHeight; public ushort biPlanes, biBitCount;
        public uint biCompression, biSizeImage; public int biXPelsPerMeter, biYPelsPerMeter; public uint biClrUsed, biClrImportant;
    }
    [DllImport("user32.dll")] static extern bool GetClientRect(nint hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern nint GetDC(nint hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(nint hwnd, nint dc);
    [DllImport("user32.dll")] static extern bool PrintWindow(nint hwnd, nint dc, uint flags);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(nint hwnd);
    [DllImport("gdi32.dll")] static extern nint CreateCompatibleDC(nint dc);
    [DllImport("gdi32.dll")] static extern nint CreateCompatibleBitmap(nint dc, int width, int height);
    [DllImport("gdi32.dll")] static extern nint SelectObject(nint dc, nint obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(nint obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(nint dc);
    [DllImport("gdi32.dll")] static extern int GetDIBits(nint dc, nint bitmap, uint start, uint lines, byte[] bits, ref BITMAPINFOHEADER info, uint usage);
}
