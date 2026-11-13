using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Windows.Foundation;
using Windows.Storage.Streams;

namespace ReadmeSpike;

/// <summary>
/// Spike version of BookWebView.cs: one CoreWebView2 (from a XAML WebView2 or a bare, never-shown
/// controller) serving readme-book://app/, with remote loads blocked and the browser locked down.
/// </summary>
sealed class BookHost
{
    public const string Scheme = "readme-book";
    const string Origin = "readme-book://app";
    const string ReaderPath = "/reader.html";
    const string BookFolder = "/book/";

    /// Same policy as BookScheme.swift.
    public const string ContentSecurityPolicy = "default-src 'self' blob: readme-book:; script-src 'self'; connect-src 'self' blob: readme-book:; img-src * blob: data: readme-book:; style-src * blob: 'unsafe-inline'; font-src * blob: data: readme-book:";

    static readonly string[] BlockedSchemes = ["http", "https", "ws", "wss"];

    public CoreWebView2 Core { get; }
    readonly CoreWebView2Environment _environment;
    readonly string _webRoot;
    string? _bookPath;
    string? _bookFile;

    readonly Dictionary<int, TaskCompletionSource<JsonElement>> _replies = [];
    int _nextReply;
    TaskCompletionSource? _ready;
    string? _pendingLoad;
    int _loadCount;

    public static string? RegistrationReadBack { get; private set; }
    public static List<string> HiddenAttempts { get; } = [];
    public List<string> Log { get; } = [];
    public List<string> BlockedRequests { get; } = [];
    public List<string> CancelledNavigations { get; } = [];
    public int CancelledWindows { get; private set; }
    public int RejectedMessages { get; private set; }
    public List<JsonElement> Messages { get; } = [];
    public event Action<JsonElement>? MessageReceived;

    BookHost(CoreWebView2 core, CoreWebView2Environment environment, string webRoot)
    {
        Core = core;
        _environment = environment;
        _webRoot = Path.GetFullPath(webRoot);
        Configure();
    }

    /// One environment for every view: same user data folder, same scheme registration.
    public static Task<CoreWebView2Environment> CreateEnvironmentAsync(string userDataFolder)
    {
        // The WinRT projection exposes TreatAsSecure as an int (a COM BOOL), unlike its neighbour.
        var registration = new CoreWebView2CustomSchemeRegistration(Scheme)
        {
            TreatAsSecure = 1,
            HasAuthorityComponent = true,
        };
        registration.AllowedOrigins.Add(Origin);
        // The getter hands back a copy, so adding to it does nothing: the list has to be assigned.
        var options = new CoreWebView2EnvironmentOptions { CustomSchemeRegistrations = [registration] };
        RegistrationReadBack = $"schemes={options.CustomSchemeRegistrations.Count} origins={string.Join(",", options.CustomSchemeRegistrations.FirstOrDefault()?.AllowedOrigins ?? [])} secure={options.CustomSchemeRegistrations.FirstOrDefault()?.TreatAsSecure} authority={options.CustomSchemeRegistrations.FirstOrDefault()?.HasAuthorityComponent}";
        return CoreWebView2Environment.CreateWithOptionsAsync(null, userDataFolder, options).AsTask();
    }

    public static CoreWebView2ControllerOptions ControllerOptions(CoreWebView2Environment environment)
    {
        var options = environment.CreateCoreWebView2ControllerOptions();
        options.IsInPrivateModeEnabled = true;
        return options;
    }

    public static async Task<BookHost> AttachAsync(Microsoft.UI.Xaml.Controls.WebView2 control,
        CoreWebView2Environment environment, string webRoot)
    {
        var ensure = control.EnsureCoreWebView2Async(environment, ControllerOptions(environment)).AsTask();
        if (await Task.WhenAny(ensure, Task.Delay(TimeSpan.FromSeconds(10))) != ensure)
            throw new TimeoutException("EnsureCoreWebView2Async never finished");
        await ensure;
        return new BookHost(control.CoreWebView2, environment, webRoot);
    }

    /// A view with no XAML control and no visibility: what import and the curl cache need.
    public static async Task<(BookHost Host, CoreWebView2Controller Controller)> CreateHiddenAsync(
        nint parentWindow, CoreWebView2Environment environment, string webRoot, int width, int height)
    {
        var reference = CoreWebView2ControllerWindowReference.CreateFromWindowHandle((ulong)parentWindow);
        // Spike: find which way of making a second controller works.
        var attempts = new (string Name, Func<IAsyncOperation<CoreWebView2Controller>> Make)[]
        {
            ("in-private, default profile", () => environment.CreateCoreWebView2ControllerAsync(reference, ControllerOptions(environment))),
            ("in-private, own profile", () =>
            {
                var options = ControllerOptions(environment);
                options.ProfileName = "Hidden";
                return environment.CreateCoreWebView2ControllerAsync(reference, options);
            }),
            ("no options", () => environment.CreateCoreWebView2ControllerAsync(reference)),
        };
        CoreWebView2Controller? controller = null;
        foreach (var (name, make) in attempts)
        {
            try
            {
                controller = await make();
                HiddenAttempts.Add($"{name}: ok");
                break;
            }
            catch (Exception error)
            {
                HiddenAttempts.Add($"{name}: 0x{error.HResult:X8}");
            }
        }
        if (controller == null) throw new InvalidOperationException(string.Join("; ", HiddenAttempts));
        controller.Bounds = new Windows.Foundation.Rect(0, 0, width, height);
        controller.IsVisible = false;
        return (new BookHost(controller.CoreWebView2, environment, webRoot), controller);
    }

    void Configure()
    {
        var settings = Core.Settings;
        settings.AreBrowserAcceleratorKeysEnabled = false;
        settings.AreDefaultContextMenusEnabled = false;
        settings.AreDevToolsEnabled = false;
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
        Core.AddWebResourceRequestedFilter($"{Scheme}*", CoreWebView2WebResourceContext.All, all);
        Core.AddWebResourceRequestedFilter($"{Scheme}*", CoreWebView2WebResourceContext.All);
        foreach (var scheme in BlockedSchemes)
            Core.AddWebResourceRequestedFilter($"{scheme}://*", CoreWebView2WebResourceContext.All, all);
        Core.WebResourceRequested += OnWebResourceRequested;

        Core.NavigationStarting += (_, args) =>
        {
            Log.Add($"navigation starting: {args.Uri}");
            if (IsReader(args.Uri) && _pendingLoad != null) return;
            args.Cancel = true;
            CancelledNavigations.Add(args.Uri);
        };
        Core.FrameNavigationStarting += (_, args) =>
        {
            var scheme = args.Uri.Split(':', 2)[0].ToLowerInvariant();
            if (scheme is "blob" or "about") return;
            args.Cancel = true;
            CancelledNavigations.Add(args.Uri);
        };
        Core.NewWindowRequested += (_, args) =>
        {
            args.Handled = true;
            CancelledWindows++;
        };
        Core.DownloadStarting += (_, args) => args.Cancel = true;
        Core.WebMessageReceived += OnWebMessage;

        // Spike diagnostics.
        Core.NavigationCompleted += (_, args) =>
            Log.Add($"navigation completed: success={args.IsSuccess} status={args.HttpStatusCode} error={args.WebErrorStatus} url={Core.Source}");
        _ = Core.CallDevToolsProtocolMethodAsync("Runtime.enable", "{}");
        _ = Core.CallDevToolsProtocolMethodAsync("Log.enable", "{}");
        Core.GetDevToolsProtocolEventReceiver("Runtime.consoleAPICalled").DevToolsProtocolEventReceived +=
            (_, args) => Log.Add("console: " + Trim(args.ParameterObjectAsJson));
        Core.GetDevToolsProtocolEventReceiver("Runtime.exceptionThrown").DevToolsProtocolEventReceived +=
            (_, args) => Log.Add("exception: " + Trim(args.ParameterObjectAsJson));
        Core.GetDevToolsProtocolEventReceiver("Log.entryAdded").DevToolsProtocolEventReceived +=
            (_, args) => Log.Add("log: " + Trim(args.ParameterObjectAsJson));
    }

    static string Trim(string text) => text.Length > 600 ? text[..600] + "…" : text;

    static bool IsReader(string uri) =>
        Uri.TryCreate(uri, UriKind.Absolute, out var url)
        && url.Scheme == Scheme && url.Host == "app" && url.AbsolutePath == ReaderPath;

    // MARK: Serving

    void OnWebResourceRequested(CoreWebView2 sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        try
        {
            Respond(args);
        }
        catch (Exception error)
        {
            Log.Add($"handler threw for {args.Request.Uri}: {error}");
            throw;
        }
    }

    void Respond(CoreWebView2WebResourceRequestedEventArgs args)
    {
        var uri = args.Request.Uri;
        Log.Add($"requested {uri}");
        if (!uri.StartsWith($"{Scheme}:", StringComparison.OrdinalIgnoreCase))
        {
            BlockedRequests.Add(uri);
            args.Response = _environment.CreateWebResourceResponse(null, 403, "Blocked", "");
            return;
        }
        var response = Serve(uri);
        Log.Add($"served {response.StatusCode} {uri}");
        args.Response = response;
    }

    CoreWebView2WebResourceResponse Serve(string uri)
    {
        if (!Uri.TryCreate(uri, UriKind.Absolute, out var url) || url.Host != "app")
            return NotFound();
        var path = Uri.UnescapeDataString(url.AbsolutePath);
        string? file;
        string type;
        if (path.StartsWith(BookFolder, StringComparison.Ordinal))
        {
            file = path == _bookPath ? _bookFile : null;
            type = "application/epub+zip";
        }
        else
        {
            file = ResourcePath(path, _webRoot);
            type = MimeType(file);
        }
        if (file == null || !File.Exists(file)) return NotFound();

        var stream = File.OpenRead(file).AsRandomAccessStream();
        var headers = $"Content-Type: {type}\r\nCache-Control: no-store";
        if (path == ReaderPath) headers += $"\r\nContent-Security-Policy: {ContentSecurityPolicy}";
        return _environment.CreateWebResourceResponse(stream, 200, "OK", headers);
    }

    CoreWebView2WebResourceResponse NotFound() =>
        _environment.CreateWebResourceResponse(null, 404, "Not Found", "Content-Type: text/plain");

    /// The file under root for a request path, or null if the path is empty or leaves root.
    public static string? ResourcePath(string path, string root)
    {
        var relative = path.TrimStart('/');
        if (relative.Length == 0) return null;
        var candidate = Path.GetFullPath(Path.Combine(root, relative));
        return candidate.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
            ? candidate : null;
    }

    static string MimeType(string? file) => Path.GetExtension(file ?? "").ToLowerInvariant() switch
    {
        ".html" => "text/html; charset=utf-8",
        ".js" => "text/javascript; charset=utf-8",
        ".css" => "text/css; charset=utf-8",
        ".woff2" => "font/woff2",
        ".woff" => "font/woff",
        ".ttf" => "font/ttf",
        ".otf" => "font/otf",
        _ => "application/octet-stream",
    };

    // MARK: Messages

    void OnWebMessage(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        // Only the reader page may talk to the app.
        if (!IsReader(args.Source))
        {
            Log.Add($"rejected message from {args.Source}");
            RejectedMessages++;
            return;
        }
        JsonElement message;
        try
        {
            message = JsonDocument.Parse(args.TryGetWebMessageAsString()).RootElement.Clone();
        }
        catch (Exception)
        {
            RejectedMessages++;
            return;
        }
        if (!message.TryGetProperty("type", out var type))
        {
            RejectedMessages++;
            return;
        }
        switch (type.GetString())
        {
            case "reply":
                var id = message.GetProperty("id").GetInt32();
                if (_replies.Remove(id, out var reply))
                {
                    if (message.GetProperty("ok").GetBoolean())
                        reply.TrySetResult(message.GetProperty("value"));
                    else
                        reply.TrySetException(new BridgeException(message.GetProperty("error").GetString() ?? "error"));
                }
                return;
            case "ready":
                var load = message.TryGetProperty("load", out var l) ? l.GetString() : null;
                if (load != null && load == _pendingLoad)
                {
                    _pendingLoad = null;
                    _ready?.TrySetResult();
                }
                break;
        }
        Messages.Add(message);
        MessageReceived?.Invoke(message);
    }

    // MARK: Calls

    /// Runs `expression` in the page, awaiting it if it's a promise. ExecuteScriptAsync doesn't wait
    /// for promises, so the page posts the result back as a `reply` message with the call's id.
    public async Task<JsonElement> CallAsync(string expression, TimeSpan? timeout = null)
    {
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
        await Core.ExecuteScriptAsync(script);
        var finished = await Task.WhenAny(reply.Task, Task.Delay(timeout ?? TimeSpan.FromSeconds(20)));
        if (finished != reply.Task)
        {
            _replies.Remove(id);
            throw new TimeoutException($"No reply to {expression}");
        }
        return await reply.Task;
    }

    public static string Js(object? value) => JsonSerializer.Serialize(value);

    /// Loads reader.html and waits for bridge.js to say it's ready.
    public async Task LoadReaderAsync()
    {
        _ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _pendingLoad = (++_loadCount).ToString();
        Core.Navigate($"{Origin}{ReaderPath}?load={_pendingLoad}");
        var finished = await Task.WhenAny(_ready.Task, Task.Delay(TimeSpan.FromSeconds(15)));
        if (finished != _ready.Task) throw new TimeoutException("reader.html never said it was ready");
    }

    /// Makes `file` available to the page and returns the URL it's served at.
    public string Serve(FileInfo file)
    {
        _bookPath = BookFolder + Guid.NewGuid();
        _bookFile = file.FullName;
        return Origin + _bookPath;
    }

    public async Task<JsonElement> OpenAsync(string file, string? cfi = null, int columns = 2)
    {
        await LoadReaderAsync();
        var url = Serve(new FileInfo(file));
        return await CallAsync($"readmeBridge.open({Js(url)}, {Js(cfi)}, '', {columns}, null)",
            TimeSpan.FromSeconds(30));
    }

    public async Task<byte[]> SnapshotAsync()
    {
        using var stream = new InMemoryRandomAccessStream();
        await Core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
        var bytes = new byte[stream.Size];
        stream.Seek(0);
        using var reader = new DataReader(stream);
        await reader.LoadAsync((uint)stream.Size);
        reader.ReadBytes(bytes);
        return bytes;
    }
}

sealed class BridgeException(string message) : Exception(message);
