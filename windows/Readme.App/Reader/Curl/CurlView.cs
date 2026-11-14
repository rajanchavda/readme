using System.Diagnostics;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Readme.Core.Curl;
using Readme.Core.Reader;
using Windows.Storage.Streams;
using Windows.UI;
using Colors = Microsoft.UI.Colors;

namespace Readme.App.Reader.Curl;

/// <summary>A picture of one spread, decoded and ready for the compositor to draw.</summary>
public sealed class SpreadImage(LoadedImageSurface surface)
{
    public LoadedImageSurface Surface { get; } = surface;

    /// <summary>Decodes a PNG; null if it won't. Runs on the UI thread, which a LoadedImageSurface needs.</summary>
    public static async Task<SpreadImage?> FromAsync(IRandomAccessStream png)
    {
        var surface = LoadedImageSurface.StartLoadFromStream(png);
        var done = new TaskCompletionSource<bool>();
        surface.LoadCompleted += (_, e) => done.TrySetResult(e.Status == LoadedImageSourceLoadStatus.Success);
        if (!await done.Task)
        {
            surface.Dispose();
            return null;
        }
        return new SpreadImage(surface);
    }
}

/// <summary>
/// Draws a page turning over pictures of the book, covering the web view while it does (CurlView.swift).
/// The turning page is a chain of <see cref="CurlPose.Strips"/> strips hinged at their left edges, each
/// with a front and a back face showing its slice of a picture, as in
/// <c>docs/mockups/open-book-v2.html</c>, built from Composition visuals with their 3D transforms.
///
/// Every angle, shade and the cast shadow are expression animations of one progress value, so the
/// compositor poses each frame itself: a play keeps its pace while the UI thread is busy moving the page
/// beneath, and fingers move the page by setting the value. A finished play leaves the turned page lying
/// flat, showing the landed spread with no strips, until <see cref="End"/> takes it off.
///
/// With one page across, the whole page turns about its left edge: its back is the paper's colour, it
/// throws no shadow, and it fades out over the last <see cref="CurlPose.PageFadeShare"/> of the turn.
/// </summary>
public sealed class CurlView : ICurl<SpreadImage>
{
    readonly Canvas _host = new() { IsHitTestVisible = false, Visibility = Visibility.Collapsed };
    readonly Compositor _compositor;
    readonly ContainerVisual _root;
    readonly CompositionPropertySet _pose;
    readonly Stopwatch _clock = new();

    ContainerVisual? _stage;
    SpriteVisual? _cast;
    ContainerVisual? _beneath;
    CurlPieces<SpreadImage>? _pieces;
    CompositionScopedBatch? _batch;
    Action? _completion;
    Action? _finish;
    double _playFrom, _playTo, _playSeconds;
    double _progress;
    bool _isSinglePage;
    int _frames;
    TimeSpan _lastFrame;
    TimeSpan _longestFrame;

    /// <summary>The colour of the back of a single turning page: the paper's.</summary>
    public Color PageColor { get; set; } = Colors.White;

    public CurlView()
    {
        _compositor = ElementCompositionPreview.GetElementVisual(_host).Compositor;
        _root = _compositor.CreateContainerVisual();
        _pose = _compositor.CreatePropertySet();
        _pose.InsertScalar("Progress", 0);
        ElementCompositionPreview.SetElementChildVisual(_host, _root);
    }

    public FrameworkElement Element => _host;

    public bool IsShowing => _host.Visibility == Visibility.Visible;
    public bool IsPlaying => _completion != null;
    public double Width => _host.Width > 0 ? _host.Width : 0;
    double Height => _host.Height > 0 ? _host.Height : 0;

    /// <summary>Where the page is: as last set, or, mid-play, where the play has it now.</summary>
    public double Progress => IsPlaying && _playSeconds > 0
        ? _playFrom + (_playTo - _playFrom) * Math.Min(1, _clock.Elapsed.TotalSeconds / _playSeconds)
        : _progress;

    /// <summary>The frame timing of the last play, from the UI thread's frames while it ran.</summary>
    public (int Frames, double LongestMs) LastPlay => (_frames, _longestFrame.TotalMilliseconds);

    // MARK: Setting up

    public void Begin(TurnDirection direction, CurlPieces<SpreadImage> pieces)
    {
        Clear();
        _pieces = pieces;
        var width = Width;
        var height = Height;
        _root.Size = new Vector2((float)width, (float)height);
        switch (pieces)
        {
            case CurlPieces<SpreadImage>.SpreadPieces spread:
                var page = width / 2;
                _beneath = Beneath(Page(spread.BeneathLeft, page, height, 0), Page(spread.BeneathRight, page, height, page));
                _cast = Cast(width, height);
                BuildStrips(spread.Front, spread.Back, null, page, height, hinge: page);
                break;
            case CurlPieces<SpreadImage>.PagePieces one:
                _isSinglePage = true;
                _beneath = Beneath(Whole(one.Beneath, width, height));
                _cast = Cast(width, height);
                _cast.IsVisible = false;
                BuildStrips(new PageImage<SpreadImage>(one.Front, false, IsWhole: true), null, PageColor, width, height, hinge: 0);
                break;
        }
        _host.Visibility = Visibility.Visible;
        SetProgress(direction == TurnDirection.Forward ? 0 : 1);
    }

    public void Crossfade(SpreadImage from, SpreadImage to, Action completion)
    {
        Clear();
        var width = Width;
        var height = Height;
        _root.Size = new Vector2((float)width, (float)height);
        _beneath = Beneath(Whole(to, width, height));
        var top = Whole(from, width, height);
        _root.Children.InsertAtTop(top);
        _host.Visibility = Visibility.Visible;
        var fade = _compositor.CreateScalarKeyFrameAnimation();
        fade.InsertKeyFrame(0, 1);
        fade.InsertKeyFrame(1, 0, _compositor.CreateCubicBezierEasingFunction(new Vector2(0.2f, 0), new Vector2(0.6f, 1)));
        fade.Duration = TimeSpan.FromSeconds(CurlPose.CrossfadeDuration);
        Run(CurlPose.CrossfadeDuration, () => top.StartAnimation("Opacity", fade), () => _root.Children.Remove(top), completion);
    }

    ContainerVisual Beneath(params Visual[] pages)
    {
        var beneath = _compositor.CreateContainerVisual();
        beneath.Size = _root.Size;
        foreach (var page in pages) beneath.Children.InsertAtTop(page);
        _root.Children.InsertAtBottom(beneath);
        return beneath;
    }

    /// <summary>A page-sized window onto one half of a spread's picture.</summary>
    Visual Page(PageImage<SpreadImage> image, double width, double height, double x) => Slice(image, width, height, 0, width, x);

    Visual Whole(SpreadImage image, double width, double height) =>
        Slice(new PageImage<SpreadImage>(image, false, IsWhole: true), width, height, 0, width, 0);

    /// <summary>
    /// <paramref name="sliceWidth"/> of the page's picture, from <paramref name="from"/> across it, at
    /// <paramref name="x"/>. The picture is a whole spread drawn at the book's size, shifted so the half
    /// wanted shows through, so each picture is uploaded once however many pieces show it.
    /// </summary>
    ContainerVisual Slice(PageImage<SpreadImage> image, double pageWidth, double height, double from, double sliceWidth, double x)
    {
        var window = _compositor.CreateContainerVisual();
        window.Size = new Vector2((float)sliceWidth, (float)height);
        window.Offset = new Vector3((float)x, 0, 0);
        window.Clip = _compositor.CreateInsetClip();
        var spreadWidth = image.IsWhole ? pageWidth : pageWidth * 2;
        var picture = _compositor.CreateSpriteVisual();
        picture.Size = new Vector2((float)spreadWidth, (float)height);
        picture.Offset = new Vector3((float)-((image.IsRight ? pageWidth : 0) + from), 0, 0);
        var brush = _compositor.CreateSurfaceBrush(image.Spread.Surface);
        brush.Stretch = CompositionStretch.Fill;
        picture.Brush = brush;
        window.Children.InsertAtTop(picture);
        return window;
    }

    /// <summary>The soft shadow the turning page throws across the spread beneath it.</summary>
    SpriteVisual Cast(double width, double height)
    {
        var shadow = _compositor.CreateSpriteVisual();
        shadow.Size = new Vector2((float)width, (float)height);
        var gradient = _compositor.CreateLinearGradientBrush();
        gradient.StartPoint = new Vector2(0, 0.5f);
        gradient.EndPoint = new Vector2(1, 0.5f);
        gradient.ColorStops.Add(_compositor.CreateColorGradientStop(0.18f, Color.FromArgb(0, 0, 0, 0)));
        gradient.ColorStops.Add(_compositor.CreateColorGradientStop(0.5f, Color.FromArgb(51, 0, 0, 0)));
        gradient.ColorStops.Add(_compositor.CreateColorGradientStop(0.82f, Color.FromArgb(0, 0, 0, 0)));
        shadow.Brush = gradient;
        var opacity = _compositor.CreateExpressionAnimation("Sin(Pi * pose.Progress)");
        opacity.SetReferenceParameter("pose", _pose);
        shadow.StartAnimation("Opacity", opacity);
        _root.Children.InsertAtTop(shadow);
        return shadow;
    }

    /// <summary>
    /// <paramref name="hinge"/> is where the page is fixed: the spine for a spread, the left edge for one
    /// page. With no <paramref name="back"/> picture, the back is <paramref name="blank"/>.
    /// </summary>
    void BuildStrips(PageImage<SpreadImage> front, PageImage<SpreadImage>? back, Color? blank, double pageWidth, double height, double hinge)
    {
        // The book's perspective about its centre, the spine, as in the mockup.
        var stage = _compositor.CreateContainerVisual();
        stage.Size = _root.Size;
        var centre = new Vector3(_root.Size.X / 2, _root.Size.Y / 2, 0);
        var perspective = Matrix4x4.Identity;
        perspective.M34 = (float)(-1 / CurlPose.Perspective);
        stage.TransformMatrix = Matrix4x4.CreateTranslation(-centre) * perspective * Matrix4x4.CreateTranslation(centre);
        _root.Children.InsertAtTop(stage);
        _stage = stage;
        if (_isSinglePage)
        {
            var fade = _compositor.CreateExpressionAnimation(
                $"pose.Progress > {1 - CurlPose.PageFadeShare} ? Max(0, (1 - pose.Progress) / {CurlPose.PageFadeShare}) : 1");
            fade.SetReferenceParameter("pose", _pose);
            stage.StartAnimation("Opacity", fade);
        }

        var count = CurlPose.Strips;
        var stripWidth = pageWidth / count;
        ContainerVisual parent = stage;
        for (var index = 0; index < count; index++)
        {
            var strip = _compositor.CreateContainerVisual();
            strip.Size = new Vector2((float)stripWidth, (float)height);
            strip.Offset = new Vector3((float)(index == 0 ? hinge : stripWidth), 0, 0);
            strip.CenterPoint = new Vector3(0, (float)height / 2, 0);
            strip.RotationAxis = Vector3.UnitY;
            // Smoothed edges where strips meet would let a line of what's behind show through each
            // hinge, as on Mac, where only the page's outer edges are smoothed.
            strip.BorderMode = CompositionBorderMode.Hard;
            var turn = _compositor.CreateExpressionAnimation($"{Angle(index)} - {Angle(index - 1)}");
            turn.SetReferenceParameter("pose", _pose);
            strip.StartAnimation("RotationAngleInDegrees", turn);
            parent.Children.InsertAtTop(strip);

            var frontFace = Slice(front, pageWidth, height, index * stripWidth, stripWidth, 0);
            frontFace.BackfaceVisibility = CompositionBackfaceVisibility.Hidden;
            frontFace.BorderMode = CompositionBorderMode.Hard;
            frontFace.Children.InsertAtTop(Shade(index, stripWidth, height, spineOnLeft: true));
            strip.Children.InsertAtTop(frontFace);

            // Facing the other way, so its slice runs from the spine outward along the chain.
            ContainerVisual backFace;
            if (back != null) backFace = Slice(back, pageWidth, height, pageWidth - (index + 1) * stripWidth, stripWidth, 0);
            else
            {
                backFace = _compositor.CreateContainerVisual();
                backFace.Size = new Vector2((float)stripWidth, (float)height);
                var paper = _compositor.CreateSpriteVisual();
                paper.Size = backFace.Size;
                paper.Brush = _compositor.CreateColorBrush(blank ?? Colors.White);
                backFace.Children.InsertAtTop(paper);
            }
            backFace.CenterPoint = new Vector3((float)stripWidth / 2, (float)height / 2, 0);
            backFace.RotationAxis = Vector3.UnitY;
            backFace.RotationAngleInDegrees = 180;
            backFace.BackfaceVisibility = CompositionBackfaceVisibility.Hidden;
            backFace.BorderMode = CompositionBorderMode.Hard;
            backFace.Children.InsertAtTop(Shade(index, stripWidth, height, spineOnLeft: false));
            strip.Children.InsertAtTop(backFace);
            parent = strip;
        }
    }

    /// <summary>
    /// The drawn angle of strip <paramref name="k"/> as an expression of the progress: CurlPose.DrawnAngles,
    /// written out for the compositor, negative as on Mac: Composition's y runs down, as Core Animation's
    /// runs up, so the same angle lifts the page towards the reader here too.
    /// </summary>
    static string Angle(int k)
    {
        if (k < 0) return "0";
        const string t = "pose.Progress";
        var e = $"({t} * {t} * (3 - 2 * {t}))";
        var b = $"({CurlPose.Bend} * Sin(2 * Pi * {t}))";
        var root = $"(-180 * {e} + {b})";
        var d = $"(2 * {b} / {CurlPose.Strips - 1})";
        var closing = $"(Clamp(({t} - {1 - CurlPose.FlatteningShare}) / {CurlPose.FlatteningShare}, 0, 1) * 0.5)";
        return $"Max(-180, Clamp({root} - {k} * {d}, -179.5, 0) - {closing})";
    }

    /// <summary>
    /// The face's darkness, that of the hinge at each end, where neighbouring strips agree, so the page
    /// shades smoothly rather than in bands (CurlPose.HingeShades).
    /// </summary>
    SpriteVisual Shade(int index, double width, double height, bool spineOnLeft)
    {
        var shade = _compositor.CreateSpriteVisual();
        shade.Size = new Vector2((float)width, (float)height);
        var gradient = _compositor.CreateLinearGradientBrush();
        gradient.StartPoint = new Vector2(spineOnLeft ? 0 : 1, 0.5f);
        gradient.EndPoint = new Vector2(spineOnLeft ? 1 : 0, 0.5f);
        var near = _compositor.CreateColorGradientStop(0, Colors.Transparent);
        var far = _compositor.CreateColorGradientStop(1, Colors.Transparent);
        gradient.ColorStops.Add(near);
        gradient.ColorStops.Add(far);
        shade.Brush = gradient;
        var angle = $"({Angle(index)})";
        var previous = index == 0 ? angle : $"({Angle(index - 1)})";
        var outer = index == CurlPose.Strips - 1 ? angle : $"({Angle(index + 1)})";
        string Dark(string a, string b) => $"ColorRGB(Abs(Sin(({a} + {b}) / 2 * Pi / 180)) * 0.16 * 255, 0, 0, 0)";
        foreach (var (stop, expression) in new[] { (near, Dark(angle, previous)), (far, Dark(angle, outer)) })
        {
            var animation = _compositor.CreateExpressionAnimation(expression);
            animation.SetReferenceParameter("pose", _pose);
            stop.StartAnimation("Color", animation);
        }
        return shade;
    }

    // MARK: Moving

    public void SetProgress(double t)
    {
        _progress = t;
        _pose.InsertScalar("Progress", (float)t);
    }

    public void Play(double from, double to, Action completion)
    {
        SetProgress(from);
        var seconds = Math.Abs(to - from) * CurlPose.Duration;
        _playFrom = from;
        _playTo = to;
        _playSeconds = seconds;
        Run(seconds, () =>
        {
            if (seconds <= 0) return;
            var move = _compositor.CreateScalarKeyFrameAnimation();
            move.InsertKeyFrame(0, (float)from);
            move.InsertKeyFrame(1, (float)to, _compositor.CreateLinearEasingFunction());
            move.Duration = TimeSpan.FromSeconds(seconds);
            _pose.StartAnimation("Progress", move);
        }, () => LayFlat(to), completion);
    }

    /// <summary>
    /// Replaces the strips with the page they became, flat like the web view's page, so there's no jump
    /// when the web view takes over.
    /// </summary>
    void LayFlat(double t)
    {
        _pose.StopAnimation("Progress");
        SetProgress(t);
        if (_beneath == null || _pieces == null) return;
        var width = Width;
        var height = Height;
        _beneath.Children.RemoveAll();
        switch (_pieces)
        {
            case CurlPieces<SpreadImage>.SpreadPieces spread:
                var page = width / 2;
                _beneath.Children.InsertAtTop(Page(t >= 1 ? spread.Back : spread.BeneathLeft, page, height, 0));
                _beneath.Children.InsertAtTop(Page(t >= 1 ? spread.BeneathRight : spread.Front, page, height, page));
                break;
            case CurlPieces<SpreadImage>.PagePieces one:
                // Gone over, it's faded away and what was beneath is the page.
                _beneath.Children.InsertAtTop(Whole(t < 1 ? one.Front : one.Beneath, width, height));
                break;
        }
        if (_stage != null) _root.Children.Remove(_stage);
        if (_cast != null) _root.Children.Remove(_cast);
        _stage = null;
        _cast = null;
    }

    public void SnapToEnd() => FinishAnimation();

    public void End()
    {
        Clear();
        _host.Visibility = Visibility.Collapsed;
    }

    /// <summary>Places the curl exactly over the book.</summary>
    public void Place(double x, double y, double width, double height)
    {
        Canvas.SetLeft(_host, x);
        Canvas.SetTop(_host, y);
        _host.Width = Math.Max(0, width);
        _host.Height = Math.Max(0, height);
    }

    void Clear()
    {
        StopAnimation();
        _root.Children.RemoveAll();
        _stage = null;
        _cast = null;
        _beneath = null;
        _pieces = null;
        _isSinglePage = false;
    }

    // MARK: Timing

    /// <summary>
    /// Starts a timed change on the compositor, and finishes it when the compositor says it's done, or
    /// a little after its time if it never does, as for a window that's covered: a turn must still end.
    /// </summary>
    void Run(double seconds, Action start, Action finish, Action completion)
    {
        StopAnimation();
        _completion = completion;
        _finish = finish;
        var batch = _compositor.CreateScopedBatch(CompositionBatchTypes.Animation);
        _batch = batch;
        start();
        batch.End();
        batch.Completed += (_, _) =>
        {
            if (batch == _batch) _host.DispatcherQueue.TryEnqueue(FinishAnimation);
        };
        _clock.Restart();
        _frames = 0;
        _longestFrame = TimeSpan.Zero;
        _lastFrame = TimeSpan.Zero;
        CompositionTarget.Rendering += Counted;
        _ = Safety(batch, seconds);
        async Task Safety(CompositionScopedBatch started, double duration)
        {
            await Task.Delay(TimeSpan.FromSeconds(duration) + TimeSpan.FromMilliseconds(250));
            if (started == _batch) FinishAnimation();
        }
    }

    void Counted(object? sender, object e)
    {
        var now = _clock.Elapsed;
        if (_frames > 0 && now - _lastFrame > _longestFrame) _longestFrame = now - _lastFrame;
        _lastFrame = now;
        _frames++;
    }

    void FinishAnimation()
    {
        if (_completion is not { } completion) return;
        var finish = _finish;
        StopAnimation();
        finish?.Invoke();
        completion();
    }

    void StopAnimation()
    {
        CompositionTarget.Rendering -= Counted;
        _batch = null;
        _completion = null;
        _finish = null;
        _pose.StopAnimation("Progress");
    }
}
