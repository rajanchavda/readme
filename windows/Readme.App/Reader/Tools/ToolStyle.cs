using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Readme.Core.Reader;
using Windows.UI;

namespace Readme.App.Reader.Tools;

/// <summary>The reading tools' shared look: colours from the theme, and the toolbar's quiet buttons.</summary>
static class ToolStyle
{
    public static Color Color(Rgba color) => Windows.UI.Color.FromArgb((byte)Math.Round(color.A * 255), color.R, color.G, color.B);

    public static SolidColorBrush Brush(Rgba color) => new(Color(color));

    public static SolidColorBrush Clear => new(Colors.Transparent);

    /// <summary>The toolbar's ground: its tint over a blur of what's behind, as the Mac's material.</summary>
    public static Brush Chrome(Theme theme)
    {
        var chrome = ToolColors.Chrome(theme);
        return new AcrylicBrush
        {
            TintColor = Color(chrome with { A = 1 }),
            TintOpacity = chrome.A,
            TintLuminosityOpacity = 0.6,
            FallbackColor = Color(chrome with { A = 0.92 }),
        };
    }

    /// <summary>A sidebar's ground: the page's colour over a blur of the book beneath.</summary>
    public static Brush Sidebar(Theme theme)
    {
        var page = ReadingCss.Colors(theme).Page;
        return new AcrylicBrush
        {
            TintColor = Color(page),
            TintOpacity = 0.9,
            TintLuminosityOpacity = 1,
            FallbackColor = Color(page),
        };
    }

    /// <summary>
    /// The mockup's buttons: no border, a faint white fill under the pointer and a stronger one when
    /// chosen or pressed, in the ink given. The template's own looks are replaced through its resources.
    /// </summary>
    public static T Quiet<T>(T button, Rgba ink, bool isOn = false, string? help = null, string? name = null) where T : ButtonBase
    {
        var on = new SolidColorBrush(Windows.UI.Color.FromArgb(56, 255, 255, 255));
        var hover = new SolidColorBrush(Windows.UI.Color.FromArgb(36, 255, 255, 255));
        var inkBrush = Brush(ink);
        var resources = button.Resources;
        resources["ButtonBackground"] = isOn ? on : Clear;
        resources["ButtonBackgroundPointerOver"] = isOn ? on : hover;
        resources["ButtonBackgroundPressed"] = on;
        resources["ButtonBackgroundDisabled"] = Clear;
        foreach (var state in new[] { "", "PointerOver", "Pressed" }) resources["ButtonForeground" + state] = inkBrush;
        resources["ButtonForegroundDisabled"] = Brush(ink.WithAlpha(0.4));
        foreach (var state in new[] { "", "PointerOver", "Pressed", "Disabled" }) resources["ButtonBorderBrush" + state] = Clear;
        button.Background = isOn ? on : Clear;
        button.Foreground = inkBrush;
        button.BorderThickness = new Thickness(0);
        button.CornerRadius = new CornerRadius(6);
        button.Padding = new Thickness(9, 3, 9, 4);
        button.MinWidth = 0;
        button.MinHeight = 0;
        button.FontSize = 12;
        button.VerticalAlignment = VerticalAlignment.Center;
        if (help != null) ToolTipService.SetToolTip(button, help);
        if ((name ?? help) is { } label) AutomationProperties.SetName(button, label);
        return button;
    }

    /// <summary>Single-line text on the toolbar's ground, with none of the box's own border, fill or focus line.</summary>
    public static TextBox QuietField(TextBox field, Rgba ink, double size)
    {
        var inkBrush = Brush(ink);
        var resources = field.Resources;
        foreach (var state in new[] { "", "PointerOver", "Focused", "Disabled" })
        {
            resources["TextControlBackground" + state] = Clear;
            resources["TextControlBorderBrush" + state] = Clear;
            resources["TextControlForeground" + state] = inkBrush;
            resources["TextControlPlaceholderForeground" + state] = Brush(ink.WithAlpha(0.5));
        }
        resources["TextControlSelectionHighlightColor"] = Brush(ink.WithAlpha(0.3));
        field.Background = Clear;
        field.BorderThickness = new Thickness(0);
        field.Foreground = inkBrush;
        field.FontSize = size;
        field.MinHeight = 0;
        field.Padding = new Thickness(0);
        field.VerticalAlignment = VerticalAlignment.Center;
        field.IsSpellCheckEnabled = false;
        field.IsTextPredictionEnabled = false;
        return field;
    }

    /// <summary>Fades in or out over the app's 200 ms, or at once with animations off.</summary>
    public static void Show(UIElement element, bool shown, bool animated)
    {
        element.OpacityTransition = animated ? new ScalarTransition { Duration = TimeSpan.FromMilliseconds(200) } : null;
        if (shown) element.Visibility = Visibility.Visible;
        element.Opacity = shown ? 1 : 0;
        element.IsHitTestVisible = shown;
    }

    /// <summary>Windows' error sound, where the Mac beeps.</summary>
    public static void Beep() => MessageBeep(0);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern bool MessageBeep(uint type);
}
