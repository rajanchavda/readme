using Readme.Core.Curl;
using Readme.Core.Model;

namespace Readme.App.Reader.Curl;

/// <summary>
/// The reader's own book view, as the spread cache and the turn coordinator see it. The layout is
/// everything that changes how a spread looks, read from the view and the reader as they are now.
/// </summary>
sealed class VisibleSpreads(BookWebView book, Func<SpreadLayout> layout) : IVisibleSpreadView<SpreadImage>, ITurnBook
{
    public ReaderLocation? CurrentLocation => book.IsOpen ? book.CurrentLocation : null;
    public bool IsOpen => book.IsOpen;
    public int Columns => book.Columns;
    public SpreadLayout Layout => layout();

    public event Action<ReaderLocation>? Relocated
    {
        add => book.Relocated += value;
        remove => book.Relocated -= value;
    }

    public event Action<bool>? LinkFollowed
    {
        add => book.LinkFollowed += value;
        remove => book.LinkFollowed -= value;
    }

    public Task<ReaderLocation?> NextAsync() => book.NextAsync();
    public Task<ReaderLocation?> PreviousAsync() => book.PreviousAsync();
    public Task<ReaderLocation?> GoToCfiAsync(string cfi) => book.GoToCfiAsync(cfi);
    public Task SettleAsync() => book.SettleAsync();
    public Task<SpreadImage?> SnapshotAsync() => Snapshot(book);

    /// <summary>Two animation frames in the page, by which its last change has been drawn.</summary>
    public Task PagePaintedAsync() => book.FramesAsync();

    public static async Task<SpreadImage?> Snapshot(BookWebView view)
    {
        using var png = await view.SnapshotAsync();
        return png == null ? null : await SpreadImage.FromAsync(png);
    }
}

/// <summary>
/// The view nobody sees, which renders the spreads either side of the reader's for the curl: an opacity-0
/// WebView2 behind the book, kept at the book's size and in its styles (spike findings: a truly
/// offscreen one doesn't work, and one is never closed mid-session).
/// </summary>
sealed class OffscreenSpreads(BookWebView book) : IOffscreenSpreadView<SpreadImage>
{
    string? _openBook;
    SpreadLayout? _styled;

    public BookWebView View => book;
    public ReaderLocation? CurrentLocation => book.IsOpen ? book.CurrentLocation : null;
    public bool IsOpen => book.IsOpen;
    public Task<ReaderLocation?> NextAsync() => book.NextAsync();
    public Task<ReaderLocation?> PreviousAsync() => book.PreviousAsync();
    public async Task<ReaderLocation?> GoToCfiAsync(string cfi)
    {
        var landed = await book.GoToCfiAsync(cfi);
        if (book.CurrentLocation?.Cfi != cfi)
            Log.Write($"spreads: wanted {cfi} got {book.CurrentLocation?.Cfi} landed {landed?.Cfi} size {book.Control.ActualWidth}x{book.Control.ActualHeight} columns {book.Columns}");
        return landed;
    }

    public Task SettleAsync() => book.SettleAsync();
    public Task<SpreadImage?> SnapshotAsync() => VisibleSpreads.Snapshot(book);

    public async Task<bool> PrepareAsync(SpreadLayout layout, ReaderLocation at)
    {
        if (layout.Book is not { } file) return false;
        try
        {
            await book.InitializeAsync();
            // A view never sized has NaN for both, which no comparison catches.
            if (double.IsNaN(book.Control.Width) || Math.Abs(book.Control.Width - layout.Width) > 0.5
                || double.IsNaN(book.Control.Height) || Math.Abs(book.Control.Height - layout.Height) > 0.5)
            {
                book.Control.Width = layout.Width;
                book.Control.Height = layout.Height;
                // Let the view take its new size before the page is told of it.
                await Task.Delay(50);
                await book.ResizedAsync(layout.Width);
            }
            if (book.Css != layout.Css || book.Columns != layout.Columns || book.ColumnWidth != layout.ColumnWidth)
                await book.ApplyStylesAsync(layout.Css, layout.Columns, layout.ColumnWidth);
            if (_openBook != file || !book.IsOpen)
            {
                await book.OpenAsync(file, at.Cfi);
                _openBook = file;
                // Its pages must land at once, not slide, or a picture would catch one mid-slide.
                await book.SetSlideAsync(false);
                _styled = null;
            }
            if (_styled?.Highlights != layout.Highlights || _styled?.HighlightColor != layout.HighlightColor)
                await book.SetHighlightsAsync(layout.Highlights.Length == 0 ? [] : layout.Highlights.Split('\n'), layout.HighlightColor);
            _styled = layout;
            await book.SettleAsync();
            return true;
        }
        catch (Exception error) when (error is BookWebViewException or TimeoutException or IOException)
        {
            Log.Write($"spreads: the offscreen view couldn't open the book: {error.Message}");
            return false;
        }
    }

    /// <summary>Lets go of the book, as the reader's own view does when it closes.</summary>
    public void Unload()
    {
        book.Unload();
        _openBook = null;
        _styled = null;
    }
}
