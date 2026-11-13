using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Readme.Core.Model;
using Readme.Core.Reader;
using Readme.Core.Storage;
using Windows.Storage.Streams;

namespace Readme.App.Reader;

public sealed class BookWebViewException(string message) : Exception(message);

/// <summary>A key pressed in the page, as bridge.js reports it.</summary>
public readonly record struct PageKey(string Key, Modifiers Modifiers, bool IsRepeat);

/// <summary>Words the reader selected in the page: where they are, and their box in the view.</summary>
public sealed record SelectionInfo(string Cfi, string Text, double Fraction, string? ChapterTitle, Box Rect);

/// <summary>
/// Shows one EPUB, paginated by foliate-js in a WebView2 (BookWebView.swift). Moves run in the order
/// they're asked for and return the new location, or null if nothing moved. <see cref="Relocated"/>
/// hears each settled location once, whatever caused it.
///
/// The page has no network: every http(s) and ws(s) request is refused in WebResourceRequested,
/// navigations away from the reader and new windows are cancelled, and the browser's own keys, menus,
/// zoom and dev tools are off. Async calls send a request id in and the page posts the result back,
/// since ExecuteScriptAsync doesn't wait for promises. See the spike findings in the checklist.
/// </summary>
public sealed class BookWebView
{
    static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(20); // outlasts bridge.js's own 15 s
    static readonly TimeSpan OpenTimeout = TimeSpan.FromSeconds(60);
    static readonly TimeSpan LoadTimeout = TimeSpan.FromSeconds(15);
    static Task<CoreWebView2Environment>? s_environment;

    public WebView2 Control { get; } = new();
    CoreWebView2? _core;
    CoreWebView2Environment? _environment;
    readonly BookScheme _scheme = new(Path.Combine(AppContext.BaseDirectory, "Web"));
    readonly Dictionary<int, TaskCompletionSource<JsonElement>> _replies = [];
    int _nextReply;
    TaskCompletionSource? _ready;
    string? _pendingLoad;
    int _loadCount;
    int _openGeneration;
    int _relocationsHeard;

    public ReaderLocation? CurrentLocation { get; private set; }
    public bool IsOpen { get; private set; }
    /// <summary>The file last opened, which the spread cache's layout names.</summary>
    public string? File { get; private set; }
    public string Css { get; private set; } = "";
    public int Columns { get; private set; } = 2;
    public double? ColumnWidth { get; private set; }
    public int RejectedMessages { get; private set; }

    public event Action<ReaderLocation>? Relocated;
    /// <summary>A link in the book followed (false), and again once it has landed (true).</summary>
    public event Action<bool>? LinkFollowed;
    public event Action<PageKey>? KeyPressed;
    public event Action<double, double>? Wheel;
    /// <summary>The pointer moved over the page.</summary>
    public event Action? PointerMoved;
    /// <summary>Words selected, or null once the selection's gone.</summary>
    public event Action<SelectionInfo?>? SelectionChanged;
    /// <summary>A click on a highlight, with its box in the view.</summary>
    public event Action<string, Box>? HighlightClicked;

    /// <summary>The highlights drawn, and their colour, as last set.</summary>
    public IReadOnlyList<string> HighlightCfis { get; private set; } = [];
    public string HighlightColor { get; private set; } = "";

    /// <summary>
    /// One environment for every view in the app: the user data folder in app data, and the book scheme
    /// registered on it. The scheme list must be assigned whole: the getter hands back a copy.
    /// </summary>
    static Task<CoreWebView2Environment> Environment(string userDataFolder) => s_environment ??= Create();

    static Task<CoreWebView2Environment> Create()
    {
        var registration = new CoreWebView2CustomSchemeRegistration(BookScheme.Scheme)
        {
            TreatAsSecure = 1, // an int in this projection
            HasAuthorityComponent = true,
        };
        registration.AllowedOrigins.Add(BookScheme.Origin);
        var options = new CoreWebView2EnvironmentOptions { CustomSchemeRegistrations = [registration] };
        return CoreWebView2Environment.CreateWithOptionsAsync(null, AppPaths.WebViewData, options).AsTask();
    }

    public async Task InitializeAsync()
    {
        if (_core != null) return;
        _environment = await Environment(AppPaths.WebViewData);
        var controllerOptions = _environment.CreateCoreWebView2ControllerOptions();
        // Nothing persists between sessions, as the Mac's non-persistent data store.
        controllerOptions.IsInPrivateModeEnabled = true;
        await Control.EnsureCoreWebView2Async(_environment, controllerOptions);
        _core = Control.CoreWebView2;
        Configure(_core);
    }

    void Configure(CoreWebView2 core)
    {
        var settings = core.Settings;
        settings.AreBrowserAcceleratorKeysEnabled = false;
        settings.AreDefaultContextMenusEnabled = false;
        settings.AreDevToolsEnabled = System.Environment.GetEnvironmentVariable("README_DEVTOOLS") == "1";
        settings.IsZoomControlEnabled = false;
        settings.IsPinchZoomEnabled = false;
        settings.IsSwipeNavigationEnabled = false;
        settings.IsStatusBarEnabled = false;
        settings.IsGeneralAutofillEnabled = false;
        settings.IsPasswordAutosaveEnabled = false;
        settings.AreDefaultScriptDialogsEnabled = false;
        settings.IsBuiltInErrorPageEnabled = false;

        // Every frame and worker, not just the main document: book chapters live in iframes.
        const CoreWebView2WebResourceRequestSourceKinds all = CoreWebView2WebResourceRequestSourceKinds.All;
        foreach (var scheme in new[] { BookScheme.Scheme, "http", "https", "ws", "wss" })
            core.AddWebResourceRequestedFilter($"{scheme}*", CoreWebView2WebResourceContext.All, all);
        core.WebResourceRequested += (_, args) =>
        {
            var uri = args.Request.Uri;
            args.Response = uri.StartsWith(BookScheme.Scheme + ":", StringComparison.OrdinalIgnoreCase)
                ? _scheme.Respond(_environment!, uri)
                : _environment!.CreateWebResourceResponse(null, 403, "Blocked", "");
        };
        // The main frame only changes while the reader is loading; a book's frames only to blob: and about:.
        core.NavigationStarting += (_, args) =>
        {
            if (!(BookScheme.IsReader(args.Uri) && _pendingLoad != null)) args.Cancel = true;
        };
        core.FrameNavigationStarting += (_, args) =>
        {
            var scheme = args.Uri.Split(':', 2)[0].ToLowerInvariant();
            if (scheme is not ("blob" or "about")) args.Cancel = true;
        };
        core.NavigationCompleted += (_, args) =>
        {
            if (!args.IsSuccess && _pendingLoad != null)
                _ready?.TrySetException(new BookWebViewException($"The reader didn't load ({args.WebErrorStatus})"));
        };
        core.NewWindowRequested += (_, args) => args.Handled = true;
        core.DownloadStarting += (_, args) => args.Cancel = true;
        core.WebMessageReceived += OnMessage;
    }

    // MARK: Opening

    /// <summary>
    /// Opens <paramref name="file"/> at <paramref name="cfi"/>, or its start. A newer open supersedes
    /// this one, which then throws <see cref="OperationCanceledException"/>.
    /// </summary>
    public async Task<ReaderLocation> OpenAsync(string file, string? cfi)
    {
        await InitializeAsync();
        var generation = ++_openGeneration;
        IsOpen = false;
        CurrentLocation = null;
        // A new page has none drawn.
        HighlightCfis = [];
        if (!System.IO.File.Exists(file)) throw new BookWebViewException("The book's file can't be read");
        await LoadReaderAsync();
        if (generation != _openGeneration) throw new OperationCanceledException();
        var url = _scheme.Serve(file);
        JsonElement reply;
        try
        {
            reply = await CallAsync($"readmeBridge.open({Js(url)}, {Js(cfi)}, {Js(Css)}, {Columns}, {Js(ColumnWidth)})", OpenTimeout);
        }
        catch (BookWebViewException) when (generation != _openGeneration)
        {
            throw new OperationCanceledException();
        }
        if (generation != _openGeneration) throw new OperationCanceledException();
        var location = Location(reply) ?? throw new BookWebViewException("The book has no pages");
        IsOpen = true;
        File = file;
        CurrentLocation = location;
        return location;
    }

    /// <summary>Loads reader.html and waits for bridge.js to say it's ready.</summary>
    async Task LoadReaderAsync()
    {
        _ready?.TrySetCanceled();
        // The page these were sent to is going; they won't be answered.
        foreach (var pending in _replies.Values) pending.TrySetException(new BookWebViewException("Superseded by a new page"));
        _replies.Clear();
        _ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _pendingLoad = (++_loadCount).ToString();
        var ready = _ready.Task;
        _core!.Navigate(BookScheme.ReaderUrl(_pendingLoad));
        if (await Task.WhenAny(ready, Task.Delay(LoadTimeout)) != ready)
            throw new BookWebViewException("The reader page didn't load in time");
        await ready;
    }

    // MARK: Moving

    public Task<ReaderLocation?> NextAsync() => NavigateAsync("readmeBridge.next()");
    public Task<ReaderLocation?> PreviousAsync() => NavigateAsync("readmeBridge.previous()");
    public Task<ReaderLocation?> GoToCfiAsync(string cfi) => NavigateAsync($"readmeBridge.goToCFI({Js(cfi)})");
    public Task<ReaderLocation?> GoToFractionAsync(double fraction) =>
        double.IsFinite(fraction) ? NavigateAsync($"readmeBridge.goToFraction({Js(Math.Clamp(fraction, 0, 1))})") : Task.FromResult<ReaderLocation?>(null);
    public Task<ReaderLocation?> GoToStartAsync() => NavigateAsync("readmeBridge.goToStart()");
    public Task<ReaderLocation?> GoToEndAsync() => NavigateAsync("readmeBridge.goToEnd()");
    public Task<ReaderLocation?> GoToPageAsync(int page) => NavigateAsync($"readmeBridge.goToPage({page})");

    /// <summary>
    /// Follows a link of the book's: whether it led anywhere, and where the book went, or null if it
    /// was already there.
    /// </summary>
    public async Task<(bool Resolved, ReaderLocation? Location)> GoToHrefAsync(string href)
    {
        if (!IsOpen) return (false, null);
        var heard = _relocationsHeard;
        try
        {
            var reply = await CallAsync($"readmeBridge.goToHref({Js(href)})");
            var resolved = reply.TryGetProperty("resolved", out var r) && r.ValueKind == JsonValueKind.True;
            var location = reply.TryGetProperty("location", out var l) ? Location(l) : null;
            Take(location, heard);
            return (resolved, location);
        }
        catch (Exception error) when (error is BookWebViewException or TimeoutException) { return (false, null); }
    }

    // MARK: Reading tools

    /// <summary>The book's table of contents, flattened, each entry with its level.</summary>
    public async Task<IReadOnlyList<TocEntry>> TocAsync()
    {
        if (!IsOpen) return [];
        try { return (await CallAsync("readmeBridge.toc()")).Deserialize<List<TocEntry>>(Json.Library) ?? []; }
        catch (Exception error) when (error is BookWebViewException or TimeoutException or JsonException)
        {
            Debug.WriteLine($"Reading the contents failed: {error.Message}");
            return [];
        }
    }

    /// <summary>Searches the whole book. Null if it failed, or a newer search replaced it.</summary>
    public async Task<SearchOutcome?> SearchAsync(string query, int limit)
    {
        if (!IsOpen) return null;
        try
        {
            var reply = await CallAsync($"readmeBridge.search({Js(query)}, {limit})", TimeSpan.FromSeconds(120));
            if (reply.TryGetProperty("isCancelled", out var cancelled) && cancelled.ValueKind == JsonValueKind.True) return null;
            var matches = reply.GetProperty("matches").Deserialize<List<SearchMatch>>(Json.Library) ?? [];
            return new SearchOutcome(matches, reply.TryGetProperty("isCapped", out var capped) && capped.ValueKind == JsonValueKind.True);
        }
        catch (Exception error) when (error is BookWebViewException or TimeoutException or JsonException or KeyNotFoundException)
        {
            Debug.WriteLine($"Searching failed: {error.Message}");
            return null;
        }
    }

    /// <summary>The words at <paramref name="cfi"/> glow for a moment in <paramref name="color"/>.</summary>
    public Task FlashAsync(string cfi, string color) => TryAsync($"readmeBridge.flash({Js(cfi)}, {Js(color)})");

    /// <summary>Draws exactly <paramref name="cfis"/> as highlights, in <paramref name="color"/>.</summary>
    public async Task SetHighlightsAsync(IReadOnlyList<string> cfis, string color)
    {
        HighlightCfis = cfis;
        HighlightColor = color;
        if (IsOpen) await TryAsync($"readmeBridge.setHighlights({Js(cfis)}, {Js(color)})");
    }

    public async Task AddHighlightAsync(string cfi)
    {
        HighlightCfis = [.. HighlightCfis.Where(c => c != cfi), cfi];
        await TryAsync($"readmeBridge.addHighlight({Js(cfi)})");
    }

    public async Task RemoveHighlightAsync(string cfi)
    {
        HighlightCfis = [.. HighlightCfis.Where(c => c != cfi)];
        await TryAsync($"readmeBridge.removeHighlight({Js(cfi)})");
    }

    public Task ClearSelectionAsync() => TryAsync("readmeBridge.clearSelection()");

    /// <summary>
    /// Sets the reading marker at the start of <paramref name="cfi"/>, or takes it away with null.
    /// Answers the point kept, and notes whether the spread on show now holds it.
    /// </summary>
    public async Task<string?> SetMarkerAsync(string? cfi)
    {
        if (!IsOpen) return cfi;
        try
        {
            var reply = await CallAsync($"readmeBridge.setMarker({Js(cfi)})");
            var kept = reply.TryGetProperty("cfi", out var c) && c.ValueKind == JsonValueKind.String ? c.GetString() : null;
            var marked = reply.TryGetProperty("isMarked", out var m) && m.ValueKind == JsonValueKind.True;
            if (CurrentLocation is { } here) CurrentLocation = here with { IsMarked = marked };
            return kept;
        }
        catch (Exception error) when (error is BookWebViewException or TimeoutException) { return cfi; }
    }

    /// <summary>
    /// Hides the pointer over the page, or shows it again: the page's documents, the chapters' frames
    /// among them, each get a rule. A chapter loaded later has none, but by then the pointer has moved.
    /// </summary>
    public Task SetPointerHiddenAsync(bool hidden) => TryAsync($$"""
        (() => {
            const view = document.querySelector('foliate-view')
            const docs = [document, ...(view?.renderer?.getContents?.() ?? []).map(c => c.doc).filter(Boolean)]
            for (const doc of docs) {
                let style = doc.getElementById('readme-pointer')
                if (!style) {
                    style = doc.createElement('style')
                    style.id = 'readme-pointer'
                    ;(doc.head ?? doc.documentElement).append(style)
                }
                style.textContent = {{Js(hidden)}} ? '*, *::before, *::after { cursor: none !important }' : ''
            }
            return true
        })()
        """);

    async Task TryAsync(string expression)
    {
        if (!IsOpen) return;
        try { await CallAsync(expression); }
        catch (Exception error) when (error is BookWebViewException or TimeoutException) { Debug.WriteLine(error.Message); }
    }

    async Task<ReaderLocation?> NavigateAsync(string expression)
    {
        if (!IsOpen) return null;
        var heard = _relocationsHeard;
        try
        {
            var location = Location(await CallAsync(expression));
            Take(location, heard);
            return location;
        }
        catch (Exception error) when (error is BookWebViewException or TimeoutException)
        {
            Debug.WriteLine($"Navigation failed: {error.Message}");
            return null;
        }
    }

    /// <summary>
    /// A relocation heard while a call ran is at least as new as the call's reply, so the reply's
    /// location only counts if none was.
    /// </summary>
    void Take(ReaderLocation? location, int heard)
    {
        if (location != null && _relocationsHeard == heard) CurrentLocation = location;
    }

    /// <summary>Returns once the page has stopped changing: relayouts run, fonts and images in.</summary>
    public async Task SettleAsync()
    {
        if (!IsOpen) return;
        var heard = _relocationsHeard;
        try { Take(Location(await CallAsync("readmeBridge.settled()")), heard); }
        catch (Exception error) when (error is BookWebViewException or TimeoutException) { }
    }

    /// <summary>Where the reader is, as the page holds it across layout changes.</summary>
    public async Task<string?> PlaceAsync()
    {
        if (!IsOpen) return null;
        try { return (await CallAsync("readmeBridge.place()")).GetString(); }
        catch (Exception error) when (error is BookWebViewException or TimeoutException or InvalidOperationException) { return null; }
    }

    /// <summary>Follows the link at a point in the view, if there is one, and says whether there was.</summary>
    public async Task<bool> FollowLinkAtAsync(double x, double y)
    {
        if (!IsOpen) return false;
        try { return (await CallAsync($"readmeBridge.followLinkAt({Js(x)}, {Js(y)})")).ValueKind == JsonValueKind.True; }
        catch (Exception error) when (error is BookWebViewException or TimeoutException) { return false; }
    }

    public async Task<(string? Title, string? Author)> BookInfoAsync()
    {
        try
        {
            var info = await CallAsync("readmeBridge.bookInfo()");
            static string? Text(JsonElement e, string name) =>
                e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            return (Text(info, "title"), Text(info, "author"));
        }
        catch (Exception error) when (error is BookWebViewException or TimeoutException) { return (null, null); }
    }

    /// <summary>The book's own cover image, as the file holds it, or null if it has none or it can't be read.</summary>
    public async Task<byte[]?> CoverAsync()
    {
        try
        {
            var reply = await CallAsync("readmeBridge.cover()");
            return reply.ValueKind == JsonValueKind.String ? Convert.FromBase64String(reply.GetString()!) : null;
        }
        catch (Exception error) when (error is BookWebViewException or TimeoutException or FormatException) { return null; }
    }

    /// <summary>Lets go of the book: nothing more is read or kept from it, until the next open.</summary>
    public void Unload()
    {
        ++_openGeneration;
        IsOpen = false;
        CurrentLocation = null;
    }

    // MARK: Styles

    /// <summary>
    /// Applies reading styles and columns, and holds the reader's place; they also apply to any book
    /// opened later. By the time this returns, the position has re-settled.
    /// </summary>
    public async Task ApplyStylesAsync(string css, int columns, double? columnWidth)
    {
        Css = css;
        Columns = Math.Max(1, columns);
        ColumnWidth = columnWidth;
        if (!IsOpen) return;
        var heard = _relocationsHeard;
        try
        {
            await CallAsync($"readmeBridge.applyStyles({Js(css)}, {Columns}, {Js(columnWidth)})");
            Take(Location(await CallAsync("readmeBridge.location()")), heard);
        }
        catch (Exception error) when (error is BookWebViewException or TimeoutException)
        {
            Debug.WriteLine($"Applying styles failed: {error.Message}");
        }
    }

    /// <summary>Tells the page its new width, so it lays out again and holds the place.</summary>
    public async Task ResizedAsync(double width)
    {
        if (!IsOpen) return;
        try { await CallAsync($"readmeBridge.resized({Js(width)})"); }
        catch (Exception error) when (error is BookWebViewException or TimeoutException) { }
    }

    /// <summary>
    /// foliate's own slide between pages. Set on its renderer from here, so bridge.js, shared with the
    /// Mac (which turns with its curl), is unchanged. Off for reduced motion.
    /// </summary>
    public async Task SetSlideAsync(bool on)
    {
        if (!IsOpen) return;
        try { await CallAsync($"document.querySelector('foliate-view')?.renderer?.toggleAttribute('animated', {Js(on)})"); }
        catch (Exception error) when (error is BookWebViewException or TimeoutException) { }
    }

    /// <summary>
    /// Returns after two of the page's animation frames, by which its last change has been drawn: the
    /// turn coordinator waits for this before taking the curl off a landed page.
    /// </summary>
    public async Task FramesAsync()
    {
        if (_core == null) return;
        try { await CallAsync("new Promise(done => requestAnimationFrame(() => requestAnimationFrame(() => done(true))))", TimeSpan.FromSeconds(1)); }
        catch (Exception error) when (error is BookWebViewException or TimeoutException) { }
    }

    /// <summary>A PNG of what the view shows now.</summary>
    public async Task<IRandomAccessStream?> SnapshotAsync()
    {
        if (_core == null) return null;
        var stream = new InMemoryRandomAccessStream();
        try
        {
            await _core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
            stream.Seek(0);
            return stream;
        }
        catch (Exception error) when (error is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            stream.Dispose();
            return null;
        }
    }

    /// <summary>For the self-checks: runs an expression in the page and returns its JSON value.</summary>
    internal Task<JsonElement> EvaluateAsync(string expression) => CallAsync(expression);

    /// <summary>For the self-checks: sends input through the DevTools protocol, as a real device would.</summary>
    internal Task<string> DevToolsAsync(string method, object parameters) =>
        _core!.CallDevToolsProtocolMethodAsync(method, JsonSerializer.Serialize(parameters)).AsTask();

    // MARK: Messages and calls

    void OnMessage(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        // Only the reader page may talk to the app; a book's scripts never run, but if one did, it's refused.
        if (!BookScheme.IsReader(args.Source)) { RejectedMessages++; return; }
        JsonElement message;
        try { message = JsonDocument.Parse(args.TryGetWebMessageAsString()).RootElement.Clone(); }
        catch (Exception error) when (error is JsonException or ArgumentException) { RejectedMessages++; return; }
        if (message.ValueKind != JsonValueKind.Object || !message.TryGetProperty("type", out var type)) { RejectedMessages++; return; }
        switch (type.GetString())
        {
            case "reply":
                if (!message.TryGetProperty("id", out var id) || !_replies.Remove(id.GetInt32(), out var reply)) return;
                if (message.GetProperty("ok").GetBoolean()) reply.TrySetResult(message.GetProperty("value"));
                else reply.TrySetException(new BookWebViewException(message.GetProperty("error").GetString() ?? "error"));
                break;
            case "ready":
                var load = message.TryGetProperty("load", out var l) ? l.GetString() : null;
                if (load != null && load == _pendingLoad)
                {
                    _pendingLoad = null;
                    _ready?.TrySetResult();
                }
                break;
            case "relocate":
                if (Location(message.GetProperty("location")) is { } location)
                {
                    _relocationsHeard++;
                    CurrentLocation = location;
                    Relocated?.Invoke(location);
                }
                break;
            case "link":
                LinkFollowed?.Invoke(message.TryGetProperty("landed", out var landed) && landed.GetBoolean());
                break;
            case "key":
                var modifiers = Modifiers.None;
                if (Flag(message, "ctrl")) modifiers |= Modifiers.Ctrl;
                if (Flag(message, "shift")) modifiers |= Modifiers.Shift;
                if (Flag(message, "alt")) modifiers |= Modifiers.Alt;
                if (Flag(message, "meta")) modifiers |= Modifiers.Win;
                KeyPressed?.Invoke(new PageKey(message.GetProperty("key").GetString() ?? "", modifiers, Flag(message, "repeat")));
                break;
            case "wheel":
                Wheel?.Invoke(message.GetProperty("deltaX").GetDouble(), message.GetProperty("deltaY").GetDouble());
                break;
            case "pointer":
                PointerMoved?.Invoke();
                break;
            case "selection":
                SelectionChanged?.Invoke(Selection(message));
                break;
            case "highlight":
                if (message.TryGetProperty("cfi", out var cfi) && cfi.GetString() is { } value && Rect(message) is { } rect)
                    HighlightClicked?.Invoke(value, rect);
                break;
        }
    }

    static Box? Rect(JsonElement message)
    {
        if (!message.TryGetProperty("rect", out var r) || r.ValueKind != JsonValueKind.Object) return null;
        try { return new Box(r.GetProperty("x").GetDouble(), r.GetProperty("y").GetDouble(), r.GetProperty("width").GetDouble(), r.GetProperty("height").GetDouble()); }
        catch (Exception error) when (error is KeyNotFoundException or InvalidOperationException or FormatException) { return null; }
    }

    static SelectionInfo? Selection(JsonElement message)
    {
        static string? Text(JsonElement e, string name) =>
            e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        if (Text(message, "cfi") is not { } cfi || Text(message, "text") is not { } text || Rect(message) is not { } rect) return null;
        var fraction = message.TryGetProperty("fraction", out var f) && f.ValueKind == JsonValueKind.Number ? f.GetDouble() : 0;
        var label = Text(message, "label")?.Trim();
        return new SelectionInfo(cfi, text, fraction, string.IsNullOrEmpty(label) ? null : label, rect);
    }

    static bool Flag(JsonElement message, string name) =>
        message.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    static ReaderLocation? Location(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object) return null;
        try { return element.Deserialize<ReaderLocation>(Json.Library); }
        catch (JsonException) { return null; }
    }

    /// <summary>Runs <paramref name="expression"/> in the page, awaiting it if it's a promise.</summary>
    async Task<JsonElement> CallAsync(string expression, TimeSpan? timeout = null)
    {
        if (_core == null) throw new BookWebViewException("The view isn't ready");
        var id = ++_nextReply;
        var reply = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        _replies[id] = reply;
        var script = $$"""
            (async () => {
                const send = message => chrome.webview.postMessage(JSON.stringify(message))
                try {
                    const value = await ({{expression}})
                    send({ type: 'reply', id: {{id}}, ok: true, value: value ?? null })
                } catch (error) {
                    send({ type: 'reply', id: {{id}}, ok: false, error: String(error?.message ?? error) })
                }
            })(); 0
            """;
        var label = expression[..Math.Min(40, expression.Length)].ReplaceLineEndings(" ");
        var clock = Stopwatch.StartNew();
        await _core.ExecuteScriptAsync(script);
        var answered = reply.Task;
        if (await Task.WhenAny(answered, Task.Delay(timeout ?? CommandTimeout)) != answered)
        {
            _replies.Remove(id);
            Readme.App.Log.Write($"call {id} timed out: {label}");
            throw new TimeoutException($"No reply to {label}");
        }
        Readme.App.Log.Write($"call {id} {clock.ElapsedMilliseconds} ms: {label}{(answered.IsFaulted ? " FAILED " + answered.Exception?.InnerException?.Message : "")}");
        return await answered;
    }

    static string Js(object? value) => JsonSerializer.Serialize(value);
}
