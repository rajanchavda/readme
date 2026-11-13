using System.Numerics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Readme.Core.Layout;
using Readme.Core.Reader;

namespace Readme.App.Reader.Tools;

/// <summary>
/// The quiet toolbar from <c>docs/mockups/open-book-v2.html</c> (ReaderToolbar.swift): a small blurred
/// bar at the top of the desk that eases in when the mouse moves and out when it rests. Themes, the
/// font and line width menu, text size, time left in the chapter, the marker, contents, library and
/// full screen.
/// </summary>
sealed class ReaderToolbar
{
    readonly StackPanel _row = new() { Orientation = Orientation.Horizontal, Spacing = 4 };
    bool _isAwake;
    bool _isOver;

    public Border Root { get; } = new()
    {
        CornerRadius = new CornerRadius(9),
        Padding = new Thickness(8, 5, 8, 5),
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Top,
        Margin = new Thickness(0, 12, 0, 0),
        Opacity = 0,
        IsHitTestVisible = false,
    };

    public event Action<ReaderSettings>? SettingsChanged;
    public event Action<ReaderCommand>? Command;
    /// <summary>The pointer came onto the toolbar (true) or left it. While it's there, the toolbar stays awake.</summary>
    public event Action<bool>? Hover;

    public ReaderToolbar()
    {
        Root.Child = _row;
        AutomationProperties.SetName(Root, "Reading toolbar");
        Root.PointerEntered += (_, _) => { _isOver = true; Hover?.Invoke(true); };
        Root.PointerExited += (_, _) => { _isOver = false; Hover?.Invoke(false); };
    }

    public bool IsOver => _isOver;
    public bool IsAwake => _isAwake;

    public void SetAwake(bool awake, bool animated)
    {
        if (_isAwake == awake) return;
        _isAwake = awake;
        Root.TranslationTransition = animated ? new Vector3Transition { Duration = TimeSpan.FromMilliseconds(200) } : null;
        Root.Translation = new Vector3(0, awake ? 0 : -6, 0);
        ToolStyle.Show(Root, awake, animated);
        if (!awake) _isOver = false;
    }

    /// <summary>Shows the settings and state as they are now, in the theme's colours.</summary>
    public void Show(ReaderSettings settings, Theme theme, string? timeLeft, bool isFullscreen, bool isMarked)
    {
        var ink = ToolColors.ChromeInk(theme);
        Root.Background = ToolStyle.Chrome(theme);
        _row.Children.Clear();
        foreach (var (choice, name) in Themes)
        {
            var button = ToolStyle.Quiet(new Button { Content = name }, ink, isOn: settings.Theme == choice, name: $"{name} theme");
            button.Click += (_, _) => SettingsChanged?.Invoke(settings with { Theme = choice });
            _row.Children.Add(button);
        }
        _row.Children.Add(TextMenu(settings, ink));
        var smaller = ToolStyle.Quiet(new Button { Content = "A−" }, ink, help: Help(ReaderCommand.SmallerText, "Smaller text"));
        smaller.IsEnabled = settings.FontSize > ReaderCommands.MinFontSize;
        smaller.Click += (_, _) => Command?.Invoke(ReaderCommand.SmallerText);
        var bigger = ToolStyle.Quiet(new Button { Content = "A+" }, ink, help: Help(ReaderCommand.BiggerText, "Bigger text"));
        bigger.IsEnabled = settings.FontSize < ReaderCommands.MaxFontSize;
        bigger.Click += (_, _) => Command?.Invoke(ReaderCommand.BiggerText);
        _row.Children.Add(smaller);
        _row.Children.Add(bigger);
        if (timeLeft != null)
            _row.Children.Add(new TextBlock
            {
                Text = timeLeft,
                FontSize = 12,
                Opacity = 0.7,
                Foreground = ToolStyle.Brush(ink),
                Margin = new Thickness(9, 0, 9, 0),
                VerticalAlignment = VerticalAlignment.Center,
            });
        _row.Children.Add(IconButton(MarkerIcon(isMarked, ink), Help(ReaderCommand.ToggleMarker, isMarked ? "Remove the marker" : "Mark this page"), ReaderCommand.ToggleMarker, ink));
        _row.Children.Add(IconButton(Glyph(""), Help(ReaderCommand.ToggleToc, "Contents"), ReaderCommand.ToggleToc, ink));
        _row.Children.Add(IconButton(Glyph(""), Help(ReaderCommand.ShowLibrary, "Library"), ReaderCommand.ShowLibrary, ink));
        _row.Children.Add(IconButton(Glyph(isFullscreen ? "" : ""), Help(ReaderCommand.ToggleFullscreen, isFullscreen ? "Exit full screen" : "Full screen"), ReaderCommand.ToggleFullscreen, ink));
    }

    /// <summary>Windows' way: what it does, then its shortcut.</summary>
    static string Help(ReaderCommand command, string what) => $"{what} ({command.Shortcut().Label})";

    static readonly (ThemeChoice, string)[] Themes = [(ThemeChoice.Auto, "Auto"), (ThemeChoice.Paper, "Paper"), (ThemeChoice.Sepia, "Sepia"), (ThemeChoice.Night, "Night")];

    public static string Name(BookFont font) => font switch
    {
        BookFont.Literata => "Literata",
        BookFont.Fraunces => "Fraunces",
        _ => "EB Garamond",
    };

    public static string Name(LineWidth width) => width switch
    {
        LineWidth.Narrow => "Narrow",
        LineWidth.Wide => "Wide",
        _ => "Regular",
    };

    /// <summary>Fonts and line width share one menu, to keep the bar short.</summary>
    Button TextMenu(ReaderSettings settings, Core.Reader.Rgba ink)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(new MenuFlyoutItem { Text = "Font", IsEnabled = false });
        foreach (var font in Enum.GetValues<BookFont>())
        {
            var item = new RadioMenuFlyoutItem { Text = Name(font), GroupName = "Font", IsChecked = settings.Font == font };
            item.Click += (_, _) => SettingsChanged?.Invoke(settings with { Font = font });
            menu.Items.Add(item);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(new MenuFlyoutItem { Text = "Line Width", IsEnabled = false });
        foreach (var width in Enum.GetValues<LineWidth>())
        {
            var item = new RadioMenuFlyoutItem { Text = Name(width), GroupName = "LineWidth", IsChecked = settings.LineWidth == width };
            item.Click += (_, _) => SettingsChanged?.Invoke(settings with { LineWidth = width });
            menu.Items.Add(item);
        }
        // The toolbar stays while its menu is open.
        menu.Opened += (_, _) => Hover?.Invoke(true);
        menu.Closed += (_, _) => Hover?.Invoke(_isOver);
        return ToolStyle.Quiet(new Button { Content = "Aa", Flyout = menu }, ink, help: "Font and line width");
    }

    Button IconButton(UIElement icon, string help, ReaderCommand command, Core.Reader.Rgba ink)
    {
        var button = ToolStyle.Quiet(new Button { Content = icon }, ink, help: help);
        button.Padding = new Thickness(9, 4, 9, 4);
        button.Click += (_, _) => Command?.Invoke(command);
        return button;
    }

    static FontIcon Glyph(string glyph) => new()
    {
        Glyph = glyph,
        FontFamily = new FontFamily("Segoe Fluent Icons"),
        FontSize = 13,
        Height = 15,
    };

    /// <summary>The marker's own shape, a ribbon with a V cut in its tail: filled when this page is marked.</summary>
    static Microsoft.UI.Xaml.Shapes.Path MarkerIcon(bool filled, Core.Reader.Rgba ink)
    {
        double w = 9, h = 13, notch = 3.5;
        var figure = new PathFigure { StartPoint = new Windows.Foundation.Point(0.5, 0.5), IsClosed = true };
        foreach (var (x, y) in new[] { (w - 0.5, 0.5), (w - 0.5, h - 0.5), (w / 2, h - 0.5 - notch), (0.5, h - 0.5) })
            figure.Segments.Add(new LineSegment { Point = new Windows.Foundation.Point(x, y) });
        return new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = new PathGeometry { Figures = { figure } },
            Stroke = ToolStyle.Brush(ink),
            StrokeThickness = 1.2,
            Fill = filled ? ToolStyle.Brush(ink) : ToolStyle.Clear,
            Width = w,
            Height = 15,
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    /// <summary>For the self-checks: the names Narrator reads for the toolbar's buttons, in order.</summary>
    public IEnumerable<string> ButtonNames => _row.Children.OfType<Button>().Select(b => AutomationProperties.GetName(b));

    /// <summary>For the self-checks: presses the button Narrator calls <paramref name="name"/>.</summary>
    public bool Press(string name)
    {
        var button = _row.Children.OfType<Button>().FirstOrDefault(b => AutomationProperties.GetName(b).StartsWith(name, StringComparison.Ordinal));
        if (button is not { IsEnabled: true }) return false;
        var peer = Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.CreatePeerForElement(button) as Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer;
        peer?.Invoke();
        return peer != null;
    }
}
