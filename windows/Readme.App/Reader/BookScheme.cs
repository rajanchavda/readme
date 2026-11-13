using Microsoft.Web.WebView2.Core;
using Windows.Storage.Streams;

namespace Readme.App.Reader;

/// <summary>
/// Serves <c>readme-book://app/…</c> (BookScheme.swift): the bundled Web folder, plus the open book at
/// a path that changes with each open. The scheme is registered on the environment (see
/// <see cref="BookWebView"/>); this answers its requests.
/// </summary>
sealed class BookScheme(string webRoot)
{
    public const string Scheme = "readme-book";
    public const string Origin = "readme-book://app";
    public const string ReaderPath = "/reader.html";
    const string BookFolder = "/book/";

    /// <summary>
    /// The Mac's policy. foliate requires scripts blocked by CSP; book iframes inherit it through their
    /// blob: URLs. style-src names blob: because * doesn't cover it.
    /// </summary>
    public const string ContentSecurityPolicy = "default-src 'self' blob: readme-book:; script-src 'self'; connect-src 'self' blob: readme-book:; img-src * blob: data: readme-book:; style-src * blob: 'unsafe-inline'; font-src * blob: data: readme-book:";

    readonly string _webRoot = Path.GetFullPath(webRoot);
    string? _bookPath;
    string? _bookFile;

    public static string ReaderUrl(string load) => $"{Origin}{ReaderPath}?load={Uri.EscapeDataString(load)}";

    /// <summary>The reader page, whatever query it's asked for with.</summary>
    public static bool IsReader(string uri) =>
        Uri.TryCreate(uri, UriKind.Absolute, out var url)
        && url.Scheme == Scheme && url.Host == "app" && url.AbsolutePath == ReaderPath;

    /// <summary>Makes <paramref name="file"/> available to the page and returns the URL to fetch it from.</summary>
    public string Serve(string file)
    {
        _bookPath = BookFolder + Guid.NewGuid();
        _bookFile = Path.GetFullPath(file);
        return Origin + _bookPath;
    }

    public CoreWebView2WebResourceResponse Respond(CoreWebView2Environment environment, string uri)
    {
        try
        {
            if (!Uri.TryCreate(uri, UriKind.Absolute, out var url) || url.Host != "app") return Status(environment, 404);
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
            if (file == null || !File.Exists(file)) return Status(environment, 404);
            // WebView2 keeps a response's stream open for a while after it's read. FileShare.Delete
            // lets the file be moved or deleted meanwhile, as an import moves the book it just read
            // and a removal deletes it; without it Windows refuses both.
            var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete).AsRandomAccessStream();
            var headers = $"Content-Type: {type}\r\nCache-Control: no-store";
            if (path == ReaderPath) headers += $"\r\nContent-Security-Policy: {ContentSecurityPolicy}";
            return environment.CreateWebResourceResponse(stream, 200, "OK", headers);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // An exception here would be swallowed and the request aborted; answer instead.
            return Status(environment, 500);
        }
    }

    static CoreWebView2WebResourceResponse Status(CoreWebView2Environment environment, int status) =>
        environment.CreateWebResourceResponse(null, status, status == 404 ? "Not Found" : "Error", "Content-Type: text/plain");

    /// <summary>The file under root for a request path, or null if the path is empty or leaves root.</summary>
    public static string? ResourcePath(string path, string root)
    {
        var relative = path.TrimStart('/');
        if (relative.Length == 0) return null;
        var candidate = Path.GetFullPath(Path.Combine(root, relative));
        return candidate.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ? candidate : null;
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
}
