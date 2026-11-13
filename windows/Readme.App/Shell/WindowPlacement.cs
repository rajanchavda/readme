using System.Text.Json;
using Microsoft.UI.Windowing;
using Readme.Core.Storage;
using Windows.Graphics;

namespace Readme.App;

/// <summary>
/// Where the window was and how big, in physical pixels, kept in <c>window.json</c> so it comes back
/// there. A place no longer on any display (a monitor unplugged) is ignored.
/// </summary>
sealed record WindowPlacement(int X, int Y, int Width, int Height, bool IsMaximized)
{
    static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public static WindowPlacement? Load(string path) => Files.ReadJson<WindowPlacement>(path, Options);

    public void Save(string path)
    {
        try { Files.WriteJson(path, this, Options); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    public static WindowPlacement Of(AppWindow window, bool isMaximized, RectInt32? restored) =>
        restored is { } r
            ? new(r.X, r.Y, r.Width, r.Height, isMaximized)
            : new(window.Position.X, window.Position.Y, window.Size.Width, window.Size.Height, isMaximized);

    /// <summary>Puts the window back, if its old place is still on a display. Answers whether it did.</summary>
    public bool Restore(AppWindow window)
    {
        if (Width < 200 || Height < 150) return false;
        var rect = new RectInt32(X, Y, Width, Height);
        var display = DisplayArea.GetFromRect(rect, DisplayAreaFallback.None);
        if (display == null) return false;
        var work = display.WorkArea;
        // Most of its title bar must be on that display, or it can't be dragged back.
        var visibleWidth = Math.Min(X + Width, work.X + work.Width) - Math.Max(X, work.X);
        if (visibleWidth < 100 || Y < work.Y - 10 || Y > work.Y + work.Height - 40) return false;
        window.MoveAndResize(rect);
        if (IsMaximized && window.Presenter is OverlappedPresenter presenter) presenter.Maximize();
        return true;
    }
}
