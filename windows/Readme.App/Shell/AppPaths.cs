using Readme.Core.Storage;

namespace Readme.App;

/// <summary>
/// Where the app keeps things. The library lives in <c>Documents\Readme</c>, so it survives an
/// uninstall; settings, window placement and WebView2's own data live in app data, which may go.
/// <c>README_DATA_DIR</c> moves all of it into one folder, for the self-checks.
/// </summary>
static class AppPaths
{
    static readonly string? Override = Environment.GetEnvironmentVariable("README_DATA_DIR");

    static string AppData => Override ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Readme");

    public static string Library => Override != null ? Path.Combine(Override, "Library") : LibraryStore.DefaultDirectory;
    public static string Settings => Path.Combine(AppData, "settings.json");
    public static string Window => Path.Combine(AppData, "window.json");
    public static string WebViewData => Path.Combine(AppData, "WebView2");
}
