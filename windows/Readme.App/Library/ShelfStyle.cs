using Microsoft.UI.Text;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Readme.Core.Library;
using Readme.Core.Reader;
using Windows.UI;

namespace Readme.App.Library;

/// <summary>
/// The fonts the app ships in Web/fonts, for XAML (BundledFonts.swift). The reading page has its own
/// @font-face; these are for the shelf and the generated covers. Variable fonts, so one file covers
/// every weight.
/// </summary>
static class BundledFonts
{
    static FontFamily Font(string file, string family) => new($"ms-appx:///Web/fonts/{file}#{family}");

    /// <summary>Fraunces, as cover titles and the shelf's headline are set.</summary>
    public static readonly FontFamily Fraunces = Font("Fraunces.ttf", "Fraunces");
    public static readonly FontFamily EbGaramond = Font("EBGaramond.ttf", "EB Garamond");
    public static readonly FontFamily EbGaramondItalic = Font("EBGaramond-Italic.ttf", "EB Garamond");

    static readonly Dictionary<(string, double), double> Widths = [];
    static TextBlock? s_ruler;

    /// <summary>How wide a run of text is set, measured by XAML itself, so covers wrap where they draw.</summary>
    public static GeneratedCover.Measure Measurer(FontFamily family, Windows.UI.Text.FontWeight weight, Windows.UI.Text.FontStyle style) => (text, size) =>
    {
        var key = ($"{family.Source}|{weight.Weight}|{style}|{text}", size);
        if (Widths.TryGetValue(key, out var width)) return width;
        s_ruler ??= new TextBlock();
        s_ruler.FontFamily = family;
        s_ruler.FontWeight = weight;
        s_ruler.FontStyle = style;
        s_ruler.FontSize = size;
        s_ruler.Text = text;
        s_ruler.TextWrapping = Microsoft.UI.Xaml.TextWrapping.NoWrap;
        s_ruler.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        width = s_ruler.DesiredSize.Width;
        if (Widths.Count > 20_000) Widths.Clear();
        Widths[key] = width;
        return width;
    };

    /// <summary>Fraunces SemiBold, as the title is set in the mockup.</summary>
    public static readonly GeneratedCover.Measure CoverTitle = Measurer(Fraunces, FontWeights.SemiBold, Windows.UI.Text.FontStyle.Normal);
    /// <summary>EB Garamond Italic.</summary>
    public static readonly GeneratedCover.Measure CoverAuthor = Measurer(EbGaramondItalic, FontWeights.Normal, Windows.UI.Text.FontStyle.Italic);
}

/// <summary>The shelf's warm, dark palette from the mockup, the same in every reader theme.</summary>
static class ShelfStyle
{
    public static readonly Color Top = Color.FromArgb(255, 0x3A, 0x33, 0x2C);
    public static readonly Color Bottom = Color.FromArgb(255, 0x2F, 0x29, 0x23);
    public static readonly Color Text = Color.FromArgb(255, 0xF5, 0xEF, 0xE2);
    public static readonly Color Soft = Color.FromArgb(255, 0xD9, 0xCD, 0xB7);
    public static readonly Color Muted = Color.FromArgb(255, 0xB8, 0xA9, 0x8F);
    public static readonly Color WoodTop = Color.FromArgb(255, 0x6B, 0x5A, 0x46);
    public static readonly Color WoodBottom = Color.FromArgb(255, 0x4A, 0x3D, 0x2F);
    /// <summary>The pin ribbon, in the paper theme's marker colour.</summary>
    public static readonly Color Ribbon = Color.FromArgb(255, 176, 59, 51);
    public static readonly Color NoticeBackground = Color.FromArgb(255, 0x24, 0x1F, 0x1A);

    public static SolidColorBrush Brush(Color color, double opacity = 1) =>
        new(Color.FromArgb((byte)Math.Round(color.A * opacity), color.R, color.G, color.B));

    public static SolidColorBrush Brush(Rgba color) => new(Color.FromArgb((byte)Math.Round(color.A * 255), color.R, color.G, color.B));

    public static LinearGradientBrush Vertical(Color top, Color bottom) => new()
    {
        StartPoint = new Windows.Foundation.Point(0.5, 0),
        EndPoint = new Windows.Foundation.Point(0.5, 1),
        GradientStops = { new GradientStop { Color = top, Offset = 0 }, new GradientStop { Color = bottom, Offset = 1 } },
    };

    public static TextBlock Line(string text, double size, Color color, FontFamily? family = null, bool italic = false) => new()
    {
        Text = text,
        FontSize = size,
        FontFamily = family ?? (italic ? BundledFonts.EbGaramondItalic : BundledFonts.EbGaramond),
        FontStyle = italic ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
        Foreground = Brush(color),
        TextTrimming = Microsoft.UI.Xaml.TextTrimming.CharacterEllipsis,
    };
}
