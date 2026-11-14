using System.Globalization;
using Readme.Core.Layout;

namespace Readme.Core.Reader;

/// <summary>An sRGB colour with alpha, 0 to 1.</summary>
public readonly record struct Rgba(byte R, byte G, byte B, double A = 1)
{
    public static Rgba Hex(int value) => new((byte)(value >> 16), (byte)(value >> 8), (byte)value);

    /// <summary><c>#RRGGBB</c>, ignoring alpha, as the CSS uses it.</summary>
    public string ToHex() => $"#{R:X2}{G:X2}{B:X2}";

    public Rgba WithAlpha(double alpha) => this with { A = alpha };
}

public sealed record ThemeColors(Rgba Page, Rgba Ink, Rgba Soft, Rgba Desk, Rgba Spine);

/// <summary>
/// The style sheet laid over a book (ReadingCSS.swift): theme colours, font, size and spacing. Rules
/// that must beat the book's own are <c>!important</c>; italics, headings' sizes and images are left
/// alone. The same rules as on Mac; Windows adds Fraunces, its stand-in for New York.
/// </summary>
public static class ReadingCss
{
    /// <summary>Full-screen text is a third larger.</summary>
    public const double FullscreenScale = 4.0 / 3.0;

    public static ThemeColors Colors(Theme theme) => theme switch
    {
        Theme.Sepia => new(Rgba.Hex(0xEFE0C4), Rgba.Hex(0x33291B), Rgba.Hex(0x8D7650), Rgba.Hex(0x4A3A28), new Rgba(80, 50, 15, 0.36)),
        Theme.Night => new(Rgba.Hex(0x26272A), Rgba.Hex(0xBDB9AF), Rgba.Hex(0x6F6D66), Rgba.Hex(0x17181A), new Rgba(0, 0, 0, 0.45)),
        _ => new(Rgba.Hex(0xF8F5EE), Rgba.Hex(0x2B261F), Rgba.Hex(0x8A7C66), Rgba.Hex(0x3A332C), new Rgba(70, 50, 25, 0.32)),
    };

    public static string Css(ReaderSettings settings, Theme theme, bool fullscreen)
    {
        var colors = Colors(theme);
        var page = colors.Page.ToHex();
        var ink = colors.Ink.ToHex();
        var size = settings.FontSize * (fullscreen ? FullscreenScale : 1);
        const string text = "p, li, blockquote, dd, dt, td, th, div, span, a, em, i, b, strong, cite, q, small, h1, h2, h3, h4, h5, h6";
        return $$"""
            {{FontFaces}}
            html, body {
                background: {{page}} !important;
                color: {{ink}} !important;
            }
            body {
                font-family: {{Family(settings.Font)}} !important;
                font-size: {{Number(size)}}px !important;
                line-height: 1.55 !important;
                hyphens: auto;
                -webkit-hyphens: auto;
            }
            body :is({{text}}) {
                font-family: inherit !important;
                line-height: 1.55 !important;
                color: {{ink}} !important;
            }
            body :is(p, li, blockquote, dd) {
                text-align: justify;
            }
            /* Nothing runs out of its column into the gap, under the spine or onto the facing page,
               whatever the book asks: words too long for a line break where they must, everything
               wraps, verse set in <pre> keeps its line breaks, and wide boxes and tables are held to
               the column. */
            body, body * {
                overflow-wrap: anywhere !important;
                word-break: normal !important;
                max-inline-size: 100% !important;
            }
            body :is(table, td, th, col, colgroup) {
                width: auto !important;
            }
            body * {
                text-wrap-mode: wrap !important;
            }
            /* break-spaces, not pre-wrap, so the spaces where a line wraps go on to the next line
               instead of hanging out into the gap. */
            body pre {
                white-space: break-spaces !important;
            }
            @supports not (text-wrap-mode: wrap) {
                body *:not(pre, pre *) {
                    white-space: normal !important;
                }
            }
            ::selection { background: {{colors.Soft.ToHex()}}66; }
            """;
    }

    public static string Family(BookFont font) => font switch
    {
        BookFont.Literata => "\"Literata\", Georgia, serif",
        BookFont.Fraunces => "\"Fraunces\", Georgia, serif",
        _ => "\"EB Garamond\", Georgia, serif",
    };

    /// <summary>The bundled fonts, served through the book scheme. All are variable, so one file covers every weight.</summary>
    static string FontFaces => string.Join("\n", new (string Family, string File, string Style, string Weights)[]
    {
        ("EB Garamond", "EBGaramond.ttf", "normal", "400 800"),
        ("EB Garamond", "EBGaramond-Italic.ttf", "italic", "400 800"),
        ("Literata", "Literata.ttf", "normal", "200 900"),
        ("Literata", "Literata-Italic.ttf", "italic", "200 900"),
        ("Fraunces", "Fraunces.ttf", "normal", "100 900"),
    }.Select(face =>
        $"@font-face {{ font-family: \"{face.Family}\"; src: url(\"readme-book://app/fonts/{face.File}\"); " +
        $"font-style: {face.Style}; font-weight: {face.Weights}; font-display: block; }}"));

    /// <summary>As C's %g: 18 is "18", 24.000000000000004 is "24".</summary>
    static string Number(double value) => value.ToString("G6", CultureInfo.InvariantCulture);
}
