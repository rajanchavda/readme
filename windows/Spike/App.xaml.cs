using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace ReadmeSpike;

public partial class App : Application
{
    Window? _window;
    WebView2? _webView;
    BookHost? _host;

    public App() => InitializeComponent();

    static string WebRoot => Path.Combine(AppContext.BaseDirectory, "Web");

    static string UserDataFolder => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ReadmeSpike", "WebView2");

    static string FixturesFolder
    {
        get
        {
            for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            {
                var candidate = Path.Combine(dir.FullName, "ReadmeTests", "Fixtures");
                if (Directory.Exists(candidate)) return candidate;
            }
            throw new DirectoryNotFoundException("ReadmeTests/Fixtures not found above the app");
        }
    }

    static string Fixture(string name) => Path.Combine(FixturesFolder, name);

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        _webView = new WebView2();
        _window = new Window { Title = "Readme spike", Content = new Grid { Children = { _webView } } };
        _window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1400, 900));
        _window.Activate();

        var commandLine = Environment.GetCommandLineArgs();
        var checks = Array.IndexOf(commandLine, "--checks");
        try
        {
            var environment = await BookHost.CreateEnvironmentAsync(UserDataFolder);
            _host = await BookHost.AttachAsync(_webView, environment, WebRoot);
            if (checks >= 0)
            {
                var outDir = commandLine.Length > checks + 1 ? commandLine[checks + 1] : Path.GetTempPath();
                Directory.CreateDirectory(outDir);
                await new Checks(_host, environment, _webView, _window, outDir).RunAsync();
                Exit();
                return;
            }
            await RunInteractiveAsync(commandLine.Skip(1).FirstOrDefault(a => a.EndsWith(".epub"))
                ?? Fixture("long.epub"));
        }
        catch (Exception error)
        {
            Debug.WriteLine(error);
            if (checks >= 0)
            {
                File.WriteAllText(Path.Combine(Path.GetTempPath(), "readme-spike-crash.txt"), error.ToString());
                Exit();
            }
            else _window.Title = "Readme spike: " + error.Message;
        }
    }

    /// Read a book: keys and wheel turns arrive from the page and turn it.
    async Task RunInteractiveAsync(string book)
    {
        var host = _host!;
        double wheel = 0;
        host.MessageReceived += async message =>
        {
            var type = message.GetProperty("type").GetString();
            try
            {
                switch (type)
                {
                    case "relocate":
                        var location = message.GetProperty("location");
                        _window!.Title = $"Readme spike: page {location.GetProperty("page")} of {location.GetProperty("pageCount")}"
                            + $", {location.GetProperty("chapterTitle")}";
                        break;
                    case "key":
                        var key = message.GetProperty("key").GetString();
                        if (key is "ArrowRight" or "ArrowDown" or " " or "PageDown") await host.CallAsync("readmeBridge.next()");
                        else if (key is "ArrowLeft" or "ArrowUp" or "PageUp") await host.CallAsync("readmeBridge.previous()");
                        break;
                    case "wheel":
                        // Spike only: one notch (or a swipe's worth) per page.
                        var delta = message.GetProperty("deltaX").GetDouble();
                        if (delta == 0) delta = message.GetProperty("deltaY").GetDouble();
                        wheel += delta;
                        if (Math.Abs(wheel) >= 100)
                        {
                            var forward = wheel > 0;
                            wheel = 0;
                            await host.CallAsync(forward ? "readmeBridge.next()" : "readmeBridge.previous()");
                        }
                        break;
                }
            }
            catch (Exception error)
            {
                Debug.WriteLine(error);
            }
        };
        await host.OpenAsync(book);
    }
}

/// Runs every phase 0 check and writes results.json plus snapshots to `outDir`.
sealed class Checks(BookHost host, Microsoft.Web.WebView2.Core.CoreWebView2Environment environment,
    WebView2 control, Window window, string outDir)
{
    readonly Dictionary<string, object?> _results = [];
    static readonly JsonSerializerOptions Indented = new() { WriteIndented = true };

    static string WebRoot => Path.Combine(AppContext.BaseDirectory, "Web");

    static string Fixtures
    {
        get
        {
            for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            {
                var candidate = Path.Combine(dir.FullName, "ReadmeTests", "Fixtures");
                if (Directory.Exists(candidate)) return candidate;
            }
            throw new DirectoryNotFoundException("fixtures");
        }
    }

    void Record(string name, object? value)
    {
        _results[name] = value;
        Save();
    }

    void Save() => File.WriteAllText(Path.Combine(outDir, "results.json"), JsonSerializer.Serialize(_results, Indented));

    async Task Step(string name, Func<Task<object?>> run)
    {
        var clock = Stopwatch.StartNew();
        try
        {
            var value = await run();
            Record(name, new { ok = true, ms = clock.ElapsedMilliseconds, value });
        }
        catch (Exception error)
        {
            Record(name, new { ok = false, ms = clock.ElapsedMilliseconds, error = $"{error.GetType().Name} 0x{error.HResult:X8}: {error.Message}" });
        }
        Record("log", host.Log.ToList());
    }

    Task<string> Cdp(string method, object parameters) =>
        host.Core.CallDevToolsProtocolMethodAsync(method, JsonSerializer.Serialize(parameters)).AsTask();

    int Count(string type) => host.Messages.Count(m => m.GetProperty("type").GetString() == type);

    public async Task RunAsync()
    {
        Record("environment", new
        {
            browser = environment.BrowserVersionString,
            registration = BookHost.RegistrationReadBack,
            webRoot = WebRoot,
            fixtures = Fixtures,
            os = Environment.OSVersion.VersionString,
            arch = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
        });

        await Step("1 scheme and long.epub spread", async () =>
        {
            var location = await host.OpenAsync(Path.Combine(Fixtures, "long.epub"));
            await Task.Delay(800);
            var page = await host.CallAsync("""
                (() => {
                    const renderer = document.querySelector('foliate-view').renderer
                    const doc = readmeBridge.currentDocument()
                    const style = doc && getComputedStyle(doc.documentElement)
                    return {
                        url: location.href, origin: location.origin, secure: isSecureContext,
                        title: document.title, innerWidth, innerHeight,
                        maxColumnCount: renderer.getAttribute('max-column-count'),
                        docColumnWidth: style?.columnWidth, docColumnCount: style?.columnCount,
                        frameWidth: doc?.defaultView?.frameElement?.getBoundingClientRect().width,
                    }
                })()
                """);
            await File.WriteAllBytesAsync(Path.Combine(outDir, "long-visible.png"), await host.SnapshotAsync());
            return new { location, page, ready = Count("ready"), relocate = Count("relocate") };
        });

        await Step("2 next page posts relocate", async () =>
        {
            var before = Count("relocate");
            var location = await host.CallAsync("readmeBridge.next()");
            await Task.Delay(300);
            return new { location, relocatesPosted = Count("relocate") - before };
        });

        await Step("3 key after clicking the page reaches C#", async () =>
        {
            control.Focus(FocusState.Programmatic);
            var before = host.Messages.Count;
            await Cdp("Input.dispatchMouseEvent", new { type = "mousePressed", x = 500, y = 400, button = "left", clickCount = 1 });
            await Cdp("Input.dispatchMouseEvent", new { type = "mouseReleased", x = 500, y = 400, button = "left", clickCount = 1 });
            await Task.Delay(200);
            var focused = await host.CallAsync("document.activeElement?.tagName ?? null");
            await Cdp("Input.dispatchKeyEvent", new { type = "rawKeyDown", key = "ArrowRight", code = "ArrowRight", windowsVirtualKeyCode = 39, nativeVirtualKeyCode = 39 });
            await Cdp("Input.dispatchKeyEvent", new { type = "keyUp", key = "ArrowRight", code = "ArrowRight", windowsVirtualKeyCode = 39, nativeVirtualKeyCode = 39 });
            // Ctrl+F: a browser shortcut that must reach the app instead of opening find.
            await Cdp("Input.dispatchKeyEvent", new { type = "rawKeyDown", key = "f", code = "KeyF", windowsVirtualKeyCode = 70, nativeVirtualKeyCode = 70, modifiers = 2 });
            await Cdp("Input.dispatchKeyEvent", new { type = "keyUp", key = "f", code = "KeyF", windowsVirtualKeyCode = 70, nativeVirtualKeyCode = 70, modifiers = 2 });
            await Task.Delay(300);
            var keys = host.Messages.Skip(before).Where(m => m.GetProperty("type").GetString() == "key").ToList();
            return new { focusedAfterClick = focused, keys };
        });

        await Step("4 wheel deltas reach C#", async () =>
        {
            var before = host.Messages.Count;
            await Cdp("Input.dispatchMouseEvent", new { type = "mouseWheel", x = 500, y = 400, deltaX = 120, deltaY = 0 });
            await Cdp("Input.dispatchMouseEvent", new { type = "mouseWheel", x = 500, y = 400, deltaX = 0, deltaY = 120 });
            await Task.Delay(300);
            return host.Messages.Skip(before).Where(m => m.GetProperty("type").GetString() == "wheel").ToList();
        });

        await Step("5 navigations and new windows cancelled", async () =>
        {
            var navigationsBefore = host.CancelledNavigations.Count;
            await host.Core.ExecuteScriptAsync("location.href = 'https://example.com/'; 0");
            await host.Core.ExecuteScriptAsync("window.open('https://example.com/popup'); 0");
            await host.Core.ExecuteScriptAsync("window.open('readme-book://app/reader.html?load=evil'); 0");
            await Task.Delay(800);
            var stillHere = await host.CallAsync("location.href");
            return new
            {
                cancelledNavigations = host.CancelledNavigations.Skip(navigationsBefore).ToList(),
                cancelledWindows = host.CancelledWindows,
                stillHere,
            };
        });

        await Step("6 remote-image fixture makes no network request", async () =>
        {
            var blockedBefore = host.BlockedRequests.Count;
            await host.OpenAsync(Path.Combine(Fixtures, "remote-image.epub"));
            var state = await host.CallAsync("""
                (async () => {
                    const image = readmeBridge.currentDocument().getElementById('remote')
                    if (!image) return 'no image'
                    if (!image.src.startsWith('https://')) return 'src was rewritten: ' + image.src
                    for (let i = 0; i < 100 && !image.complete; i++)
                        await new Promise(resolve => setTimeout(resolve, 100))
                    return image.complete && image.naturalWidth === 0 ? 'blocked' : 'loaded'
                })()
                """);
            // A socket and a fetch from the reader page itself, which the CSP should stop first.
            var page = await host.CallAsync("""
                (async () => {
                    const results = {}
                    try { await fetch('https://example.com/'); results.fetch = 'loaded' } catch (e) { results.fetch = 'blocked: ' + e.message }
                    results.socket = await new Promise(resolve => {
                        try {
                            const socket = new WebSocket('wss://echo.websocket.org/')
                            socket.onopen = () => resolve('open')
                            socket.onerror = () => resolve('error')
                            setTimeout(() => resolve('timeout'), 3000)
                        } catch (e) { resolve('threw: ' + e.message) }
                    })
                    return results
                })()
                """);
            return new { image = state, page, blocked = host.BlockedRequests.Skip(blockedBefore).ToList() };
        });

        await Step("7 book scripts never run", async () =>
        {
            var rejectedBefore = host.RejectedMessages;
            await host.OpenAsync(Path.Combine(Fixtures, "scripted.epub"));
            await Task.Delay(500);
            var state = await host.CallAsync("""
                ({
                    chapterTitle: readmeBridge.currentDocument().title,
                    scripts: readmeBridge.currentDocument().querySelectorAll('script').length,
                    pageTitle: document.title,
                    pwned: window.__pwned === true,
                })
                """);
            return new { state, rejectedMessages = host.RejectedMessages - rejectedBefore };
        });

        await Step("8 link hints removed", async () =>
        {
            var blockedBefore = host.BlockedRequests.Count;
            await host.OpenAsync(Path.Combine(Fixtures, "link-hints.epub"));
            await Task.Delay(800);
            return new { blocked = host.BlockedRequests.Skip(blockedBefore).ToList() };
        });

        await Step("9 browser settings", () => Task.FromResult<object?>(new
        {
            host.Core.Settings.AreBrowserAcceleratorKeysEnabled,
            host.Core.Settings.AreDefaultContextMenusEnabled,
            host.Core.Settings.AreDevToolsEnabled,
            host.Core.Settings.IsZoomControlEnabled,
            host.Core.Settings.IsPinchZoomEnabled,
            host.Core.Settings.IsSwipeNavigationEnabled,
            inPrivate = host.Core.Profile.IsInPrivateModeEnabled,
            profilePath = host.Core.Profile.ProfilePath,
        }));

        // A never-shown view: tried several ways, each opened, snapshotted and checked for paint.
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        await Step("10a hidden: bare HWND controller", async () =>
        {
            var (hidden, controller) = await BookHost.CreateHiddenAsync(hwnd, environment, WebRoot, 1400, 860);
            try { return await SnapshotTrial(hidden, "bare"); }
            finally { controller.Close(); }
        });
        // Hangs the UI thread outright (run 9: no timeout could fire), so it's only run on request.
        if (Environment.GetCommandLineArgs().Contains("--try-collapsed"))
        await Step("10b hidden: XAML WebView2, Visibility collapsed", async () =>
        {
            var view = new WebView2 { Width = 1400, Height = 860, Visibility = Visibility.Collapsed };
            ((Grid)window.Content).Children.Insert(0, view);
            try { return await SnapshotTrial(await BookHost.AttachAsync(view, environment, WebRoot), "collapsed"); }
            finally { ((Grid)window.Content).Children.Remove(view); view.Close(); }
        });
        await Step("10c hidden: XAML WebView2, opacity 0 behind the reader", async () =>
        {
            var view = new WebView2 { Width = 1400, Height = 860, Opacity = 0, IsHitTestVisible = false };
            ((Grid)window.Content).Children.Insert(0, view);
            try { return await SnapshotTrial(await BookHost.AttachAsync(view, environment, WebRoot), "opacity0"); }
            finally { ((Grid)window.Content).Children.Remove(view); view.Close(); }
        });
        // Also hangs the UI thread (run 10), so only run on request.
        if (Environment.GetCommandLineArgs().Contains("--try-unshown-window"))
        await Step("10d hidden: XAML WebView2 in a window never activated", async () =>
        {
            var view = new WebView2();
            var offscreen = new Window { Content = new Grid { Children = { view } } };
            offscreen.AppWindow.Resize(new Windows.Graphics.SizeInt32(1400, 900));
            try { return await SnapshotTrial(await BookHost.AttachAsync(view, environment, WebRoot), "unshown-window"); }
            finally { view.Close(); offscreen.Close(); }
        });

        await Step("11 all fixtures", async () =>
        {
            var rows = new List<object>();
            foreach (var file in Directory.GetFiles(Fixtures, "*.epub").OrderBy(f => f))
            {
                var clock = Stopwatch.StartNew();
                try
                {
                    var location = await host.OpenAsync(file);
                    rows.Add(new
                    {
                        fixture = Path.GetFileName(file), ok = true, ms = clock.ElapsedMilliseconds,
                        page = location.GetProperty("page").GetInt32(),
                        pageCount = location.GetProperty("pageCount").GetInt32(),
                        chapter = location.GetProperty("chapterTitle").ToString(),
                    });
                }
                catch (Exception error)
                {
                    rows.Add(new { fixture = Path.GetFileName(file), ok = false, ms = clock.ElapsedMilliseconds, error = error.Message });
                }
            }
            return rows;
        });

        Record("done", true);
    }

    /// Opens long.epub in `hidden`, snapshots it, turns a page and snapshots again, as import and the
    /// curl cache would.
    async Task<object?> SnapshotTrial(BookHost hidden, string label)
    {
        var clock = Stopwatch.StartNew();
        var location = await hidden.OpenAsync(Path.Combine(Fixtures, "long.epub"));
        var openMs = clock.ElapsedMilliseconds;
        await hidden.CallAsync("readmeBridge.settled()");
        var documentHidden = await hidden.CallAsync("document.hidden");
        var size = await hidden.CallAsync("({ innerWidth, innerHeight })");
        clock.Restart();
        var first = await hidden.SnapshotAsync();
        var snapshotMs = clock.ElapsedMilliseconds;
        await File.WriteAllBytesAsync(Path.Combine(outDir, $"hidden-{label}.png"), first);
        await hidden.CallAsync("readmeBridge.next()");
        await hidden.CallAsync("readmeBridge.settled()");
        clock.Restart();
        var second = await hidden.SnapshotAsync();
        var secondMs = clock.ElapsedMilliseconds;
        await File.WriteAllBytesAsync(Path.Combine(outDir, $"hidden-{label}-next.png"), second);
        return new
        {
            openMs, documentHidden, size, snapshotMs, paint = await Analyse(first),
            secondMs, secondPaint = await Analyse(second),
            page = location.GetProperty("page").GetInt32(),
        };
    }

    /// How much of a snapshot isn't the background colour, to tell a painted page from a blank one.
    static async Task<object> Analyse(byte[] png)
    {
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(png.AsBuffer());
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        var pixels = (await decoder.GetPixelDataAsync()).DetachPixelData();
        var counts = new Dictionary<uint, int>();
        for (var i = 0; i + 3 < pixels.Length; i += 4)
        {
            var key = BitConverter.ToUInt32(pixels, i);
            counts[key] = counts.GetValueOrDefault(key) + 1;
        }
        var total = pixels.Length / 4;
        var background = counts.MaxBy(pair => pair.Value);
        return new
        {
            width = decoder.PixelWidth,
            height = decoder.PixelHeight,
            colours = counts.Count,
            inkShare = Math.Round(1 - (double)background.Value / total, 4),
        };
    }
}
