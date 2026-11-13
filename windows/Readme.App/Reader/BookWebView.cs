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
    public string Css { get; private set; } = "";
    public int Columns { get; private set; } = 2;
    public double? ColumnWidth { get; private set; }
    public int RejectedMessages { get; private set; }

    public event Action<ReaderLocation>? Relocated;
    /// <summary>A link in the book followed (false), and again once it has landed (true).</summary>
    public event Action<bool>? LinkFollowed;
    public event Action<PageKey>? KeyPressed;
    public event Action<double, double>? Wheel;

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
        if (!File.Exists(file)) throw new BookWebViewException("The book's file can't be read");
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
        }
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
