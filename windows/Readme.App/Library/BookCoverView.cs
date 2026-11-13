using System.Numerics;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Readme.Core.Library;
using Readme.Core.Model;
using Readme.Core.Storage;
using Windows.UI;

namespace Readme.App.Library;

/// <summary>
/// A book on the shelf (BookCoverView.swift and ShelfBook in ShelfRow.swift): its cover at a width,
/// always 2:3. The book's own cover fills it, cropped; a book without one, or whose cover can't be
/// read, gets a typographic cover from its title and author. It lifts under the pointer, carries a
/// ribbon when pinned and a ring when picked out, and is a button for the keyboard and Narrator.
/// </summary>
sealed class BookCoverView : Button
{
    const float HoverLift = 8;
    readonly Grid _face = new();
    readonly Border _ring = new() { BorderThickness = new Thickness(3), CornerRadius = new CornerRadius(3), IsHitTestVisible = false, Visibility = Visibility.Collapsed };

    public Book Book { get; }
    public double CoverWidth { get; }

    public BookCoverView(Book book, double width, LibraryStore library, bool extraShadow, bool animations)
    {
        Book = book;
        CoverWidth = width;
        var height = width * 1.5;
        Padding = new Thickness(0);
        BorderThickness = new Thickness(0);
        Background = new SolidColorBrush(Colors.Transparent);
        Width = width;
        Height = height;
        VerticalAlignment = VerticalAlignment.Bottom;
        UseSystemFocusVisuals = true;
        AutomationProperties.SetName(this, ShelfText.Label(book));
        AutomationProperties.SetHelpText(this, "Opens the book");
        // Keep the plain button's hover and pressed looks out of it; the cover lifts instead.
        Resources["ButtonBackgroundPointerOver"] = new SolidColorBrush(Colors.Transparent);
        Resources["ButtonBackgroundPressed"] = new SolidColorBrush(Colors.Transparent);
        Resources["ButtonBorderBrushPointerOver"] = new SolidColorBrush(Colors.Transparent);
        Resources["ButtonBorderBrushPressed"] = new SolidColorBrush(Colors.Transparent);

        var palette = GeneratedCover.PaletteFor(book.Id);
        _face.Width = width;
        _face.Height = height;
        _face.CornerRadius = new CornerRadius(2, 3, 3, 2);
        _face.Background = ShelfStyle.Brush(palette.Background);
        var container = new Grid { Width = width, Height = height };
        container.Children.Add(_face);
        container.Children.Add(SpineHighlight(width));
        if (book.PinnedAt != null) container.Children.Add(PinRibbon(width));
        container.Children.Add(_ring);
        Content = container;

        // The cover's shadow; the current book's casts further.
        container.Shadow = new ThemeShadow();
        container.Translation = new Vector3(0, 0, extraShadow ? 32 : 16);
        if (animations) container.TranslationTransition = new Vector3Transition { Duration = TimeSpan.FromMilliseconds(200) };
        PointerEntered += (_, _) => container.Translation = container.Translation with { Y = -HoverLift };
        PointerExited += (_, _) => container.Translation = container.Translation with { Y = 0 };
        PointerCanceled += (_, _) => container.Translation = container.Translation with { Y = 0 };

        if (book.HasCover) _ = LoadCoverAsync(library.CoverPath(book), width, palette);
        else ShowGenerated(width, palette);
    }

    public bool IsPicked
    {
        set
        {
            _ring.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
            _ring.BorderBrush = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"];
        }
    }

    async Task LoadCoverAsync(string path, double width, GeneratedCover.Palette palette)
    {
        var scale = XamlRoot?.RasterizationScale ?? 1.5;
        var image = await CoverImages.LoadAsync(path, (int)Math.Ceiling(width * Math.Max(scale, 1.5)));
        if (image == null)
        {
            ShowGenerated(width, palette);
            return;
        }
        _face.Children.Clear();
        _face.Children.Add(new Image { Source = image, Stretch = Stretch.UniformToFill, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
    }

    /// <summary>One TextBlock a line, so the lines drawn are the ones that were measured.</summary>
    void ShowGenerated(double width, GeneratedCover.Palette palette)
    {
        var layout = GeneratedCover.LayoutFor(Book.Title, Book.Author, width, BundledFonts.CoverTitle, BundledFonts.CoverAuthor);
        var padding = width * GeneratedCover.Padding;
        var ink = ShelfStyle.Brush(palette.Ink);
        var panel = new Grid { Margin = new Thickness(padding) };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var title = Lines(layout.Title, BundledFonts.Fraunces, FontWeights.SemiBold, Windows.UI.Text.FontStyle.Normal, ink);
        panel.Children.Add(title);
        if (layout.Author is { } authorLines)
        {
            var author = Lines(authorLines, BundledFonts.EbGaramondItalic, FontWeights.Normal, Windows.UI.Text.FontStyle.Italic, ink);
            author.Opacity = 0.85;
            Grid.SetRow(author, 2);
            panel.Children.Add(author);
        }
        _face.Children.Clear();
        _face.Children.Add(panel);
    }

    static StackPanel Lines(GeneratedCover.Lines lines, FontFamily family, Windows.UI.Text.FontWeight weight, Windows.UI.Text.FontStyle style, Brush ink)
    {
        var panel = new StackPanel();
        foreach (var line in lines.Text)
        {
            panel.Children.Add(new TextBlock
            {
                Text = line,
                FontFamily = family,
                FontWeight = weight,
                FontStyle = style,
                FontSize = lines.Size,
                Foreground = ink,
                LineHeight = lines.Size * GeneratedCover.LineHeight,
                LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
                TextWrapping = TextWrapping.NoWrap,
            });
        }
        return panel;
    }

    /// <summary>The edge of the book's spine, from the mockup.</summary>
    static Rectangle SpineHighlight(double width) => new()
    {
        Width = width * 0.05,
        HorizontalAlignment = HorizontalAlignment.Left,
        IsHitTestVisible = false,
        Fill = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0.5),
            EndPoint = new Windows.Foundation.Point(1, 0.5),
            GradientStops =
            {
                new GradientStop { Color = Color.FromArgb(51, 0, 0, 0), Offset = 0 },
                new GradientStop { Color = Color.FromArgb(20, 255, 255, 255), Offset = 0.6 },
                new GradientStop { Color = Colors.Transparent, Offset = 1 },
            },
        },
    };

    /// <summary>A narrow tab hanging from the top edge with a V cut into its tail, like the reading marker.</summary>
    static Microsoft.UI.Xaml.Shapes.Path PinRibbon(double width)
    {
        var scale = width / 112;
        double w = 10 * scale, h = 26 * scale, notch = w * 0.45;
        var figure = new PathFigure { StartPoint = new Windows.Foundation.Point(0, 0), IsClosed = true };
        foreach (var (x, y) in new[] { (w, 0.0), (w, h), (w / 2, h - notch), (0.0, h) })
            figure.Segments.Add(new LineSegment { Point = new Windows.Foundation.Point(x, y) });
        return new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = new PathGeometry { Figures = { figure } },
            Fill = ShelfStyle.Brush(ShelfStyle.Ribbon),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 0, 10 * scale, 0),
            IsHitTestVisible = false,
        };
    }
}
