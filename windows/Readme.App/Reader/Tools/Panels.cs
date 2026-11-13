using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Readme.Core.Reader;
using Windows.System;

namespace Readme.App.Reader.Tools;

static class FocusWatch
{
    /// <summary>Whether the keyboard's focus is in <paramref name="root"/>.</summary>
    public static bool IsWithin(UIElement root)
    {
        if (root.XamlRoot == null) return false;
        for (var e = FocusManager.GetFocusedElement(root.XamlRoot) as DependencyObject; e != null; e = VisualTreeHelper.GetParent(e))
            if (e == root) return true;
        return false;
    }

    /// <summary>
    /// Calls <paramref name="left"/> once the focus has really left <paramref name="root"/>: LostFocus
    /// also comes as it moves between the root's own parts.
    /// </summary>
    public static void OnLeaving(UIElement root, UIElement field, Action left) =>
        field.LostFocus += (_, _) => Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().TryEnqueue(() =>
        {
            if (!IsWithin(root)) left();
        });
}

/// <summary>
/// The small quiet field Ctrl+G shows, for typing a page number into (GoToPageField.swift). Enter asks
/// to go there; Esc, or a click anywhere else, closes it without moving. Keys typed into it never
/// turn pages, as the window leaves keys to a field being typed in.
/// </summary>
sealed class GoToPageField
{
    public const double Width = 168, Height = 30;
    readonly TextBox _field = new() { TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Stretch };

    public Border Root { get; } = new()
    {
        Width = Width,
        Height = Height,
        CornerRadius = new CornerRadius(9),
        Padding = new Thickness(10, 0, 10, 0),
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Top,
        Margin = new Thickness(0, 52, 0, 0),
        Opacity = 0,
        Visibility = Visibility.Collapsed,
    };

    /// <summary>Asked with what was typed; true if it was a page, and the field can close.</summary>
    public Func<string, bool>? OnGo { get; set; }
    public event Action? Closed;

    public GoToPageField()
    {
        Root.Child = _field;
        AutomationProperties.SetName(_field, "Go to page");
        _field.KeyDown += (_, e) =>
        {
            switch (e.Key)
            {
                case VirtualKey.Enter:
                    e.Handled = true;
                    if (OnGo?.Invoke(_field.Text) != true) ToolStyle.Beep();
                    break;
                case VirtualKey.Escape:
                    e.Handled = true;
                    Closed?.Invoke();
                    break;
            }
        };
        FocusWatch.OnLeaving(Root, _field, () => Closed?.Invoke());
    }

    public void SetTheme(Theme theme)
    {
        Root.Background = ToolStyle.Chrome(theme);
        ToolStyle.QuietField(_field, ToolColors.ChromeInk(theme), 13);
    }

    /// <summary>Empties the field, shows where the reader is, and takes the keyboard.</summary>
    public void Begin(int page, int pageCount)
    {
        _field.Text = "";
        _field.PlaceholderText = GoToPage.Placeholder(page, pageCount);
        _field.Focus(FocusState.Programmatic);
    }

    public string Placeholder => _field.PlaceholderText;

    /// <summary>For the self-checks: types into the field and presses Enter.</summary>
    public bool Enter(string typed)
    {
        _field.Text = typed;
        var went = OnGo?.Invoke(typed) == true;
        if (!went) ToolStyle.Beep();
        return went;
    }
}

/// <summary>
/// The floating box Ctrl+F shows (SearchBox.swift): a field, how many matches there are, and a list of
/// them with the words around each. Arrows move through the list, Enter or a click goes to a match, and
/// Esc closes it without moving. The field keeps the keyboard the whole time; the rows never take it.
/// </summary>
sealed class SearchBox
{
    public const double Width = 420;
    static readonly TimeSpan Pause = TimeSpan.FromMilliseconds(250);
    const int VisibleRows = 7;
    const double FieldHeight = 40, CountHeight = 22, RowHeight = 30;

    readonly TextBox _field = new() { PlaceholderText = "Find in book", HorizontalAlignment = HorizontalAlignment.Stretch };
    readonly TextBlock _count = new() { FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(14, 0, 14, 6) };
    readonly StackPanel _rows = new();
    readonly ScrollViewer _scroll = new() { IsTabStop = false, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    Rgba _ink = ToolColors.ChromeInk(Theme.Paper);
    SearchOutcome? _outcome;
    CancellationTokenSource? _pending;

    public Border Root { get; } = new()
    {
        Width = Width,
        CornerRadius = new CornerRadius(10),
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Top,
        Margin = new Thickness(0, 52, 0, 0),
        Opacity = 0,
        Visibility = Visibility.Collapsed,
    };

    /// <summary>Called with what's typed, once typing pauses.</summary>
    public event Action<string>? Query;
    /// <summary>Called with the row the reader chose.</summary>
    public event Action<int>? Picked;
    public event Action? Closed;

    public int? Selected { get; private set; }
    public string Text => _field.Text;

    public SearchBox()
    {
        var panel = new Grid();
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(FieldHeight) });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _field.Margin = new Thickness(14, 0, 14, 0);
        AutomationProperties.SetName(_field, "Find in book");
        panel.Children.Add(_field);
        Grid.SetRow(_count, 1);
        panel.Children.Add(_count);
        _scroll.Content = _rows;
        _scroll.Margin = new Thickness(0, 0, 0, 6);
        Grid.SetRow(_scroll, 2);
        panel.Children.Add(_scroll);
        Root.Child = panel;
        _field.TextChanged += (_, _) => Typed();
        // Before the box's own handling, which takes the arrows to move the caret.
        _field.PreviewKeyDown += (_, e) =>
        {
            switch (e.Key)
            {
                case VirtualKey.Down: Move(1); break;
                case VirtualKey.Up: Move(-1); break;
                case VirtualKey.Enter:
                    if (Selected is { } row) Pick(row);
                    else ToolStyle.Beep();
                    break;
                case VirtualKey.Escape:
                    _pending?.Cancel();
                    Closed?.Invoke();
                    break;
                default: return;
            }
            e.Handled = true;
        };
        FocusWatch.OnLeaving(Root, _field, () =>
        {
            _pending?.Cancel();
            Closed?.Invoke();
        });
    }

    public void SetTheme(Theme theme)
    {
        _ink = ToolColors.ChromeInk(theme);
        Root.Background = ToolStyle.Chrome(theme);
        ToolStyle.QuietField(_field, _ink, 15);
        _count.Foreground = ToolStyle.Brush(_ink.WithAlpha(0.55));
        Rebuild();
    }

    /// <summary>Fills the box with a search kept from before, if any, and takes the keyboard.</summary>
    public void Begin(string query, SearchOutcome? outcome, int? selected)
    {
        _pending?.Cancel();
        _field.Text = query;
        _pending?.Cancel();
        Selected = selected;
        Show(outcome);
        _field.Focus(FocusState.Programmatic);
        _field.SelectAll();
    }

    /// <summary>Shows what a search found. Null shows no list and no count.</summary>
    public void Show(SearchOutcome? outcome)
    {
        _outcome = outcome;
        if (outcome != null)
        {
            if (Selected is { } row && row >= outcome.Matches.Count) Selected = null;
            if (Selected == null && outcome.Matches.Count > 0) Selected = 0;
        }
        else Selected = null;
        _count.Text = outcome != null ? SearchResults.CountText(outcome) : "";
        _count.Visibility = outcome != null ? Visibility.Visible : Visibility.Collapsed;
        Rebuild();
    }

    public int RowCount => _rows.Children.Count;

    void Rebuild()
    {
        _rows.Children.Clear();
        var matches = _outcome?.Matches ?? [];
        _scroll.Height = Math.Min(matches.Count, VisibleRows) * RowHeight;
        for (var i = 0; i < matches.Count; i++) _rows.Children.Add(Row(matches[i], i));
        ScrollToSelected();
    }

    FrameworkElement Row(SearchMatch match, int index)
    {
        var excerpt = new TextBlock { FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        var quiet = ToolStyle.Brush(_ink.WithAlpha(0.7));
        excerpt.Inlines.Add(new Run { Text = SearchResults.ShortPre(match.Pre), Foreground = quiet });
        excerpt.Inlines.Add(new Run { Text = match.Match, FontWeight = FontWeights.SemiBold, Foreground = ToolStyle.Brush(_ink) });
        excerpt.Inlines.Add(new Run { Text = match.Post, Foreground = quiet });
        var detail = new TextBlock
        {
            Text = SearchResults.Detail(match),
            FontSize = 11,
            MaxWidth = 150,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = ToolStyle.Brush(_ink.WithAlpha(0.45)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(12, 0, 0, 0),
        };
        var grid = new Grid
        {
            Height = RowHeight,
            Margin = new Thickness(6, 0, 6, 0),
            Padding = new Thickness(8, 0, 8, 0),
            CornerRadius = new CornerRadius(6),
            Background = index == Selected ? ToolStyle.Brush(_ink.WithAlpha(0.1)) : ToolStyle.Clear,
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(excerpt);
        Grid.SetColumn(detail, 1);
        grid.Children.Add(detail);
        AutomationProperties.SetName(grid, $"{match.Pre}{match.Match}{match.Post}, page {SearchResults.Detail(match)}");
        // A press picks the row; the field keeps the keyboard.
        grid.PointerPressed += (_, e) =>
        {
            e.Handled = true;
            Pick(index);
        };
        return grid;
    }

    void ScrollToSelected()
    {
        if (Selected is not { } row) return;
        var top = row * RowHeight;
        var height = Math.Min(_outcome?.Matches.Count ?? 0, VisibleRows) * RowHeight;
        var offset = _scroll.VerticalOffset;
        if (top < offset) _scroll.ChangeView(null, top, null, true);
        else if (top + RowHeight > offset + height) _scroll.ChangeView(null, top + RowHeight - height, null, true);
    }

    void Move(int step)
    {
        if (_outcome is not { Matches.Count: > 0 } outcome) return;
        Selected = Math.Clamp((Selected ?? -1) + step, 0, outcome.Matches.Count - 1);
        Rebuild();
    }

    public void Pick(int row)
    {
        if (_outcome == null || row < 0 || row >= _outcome.Matches.Count) return;
        Selected = row;
        Picked?.Invoke(row);
    }

    void Typed()
    {
        _pending?.Cancel();
        var pending = _pending = new CancellationTokenSource();
        var query = _field.Text;
        _ = Later();
        async Task Later()
        {
            try { await Task.Delay(Pause, pending.Token); }
            catch (TaskCanceledException) { return; }
            Query?.Invoke(query);
        }
    }

    /// <summary>For the self-checks: types into the field, as the keyboard would.</summary>
    public void Type(string text) => _field.Text = text;

    public bool HasFocus => FocusWatch.IsWithin(Root);
}

/// <summary>
/// The small bar that floats by words the reader selected (HighlightBar.swift), with one button:
/// Highlight, or Remove over a highlight already there. It lives in the window, never in the page.
/// </summary>
sealed class HighlightBar
{
    public enum Mode { Add, Remove }

    readonly Button _button = new() { HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch };

    public Border Root { get; } = new()
    {
        Width = ToolPlacement.BarWidth,
        Height = ToolPlacement.BarHeight,
        CornerRadius = new CornerRadius(ToolPlacement.BarHeight / 2),
        Visibility = Visibility.Collapsed,
        Translation = new System.Numerics.Vector3(0, 0, 24),
        Shadow = new ThemeShadow(),
    };

    public Mode Shown { get; private set; }
    public bool IsShown => Root.Visibility == Visibility.Visible;
    public event Action<Mode>? Pressed;

    public HighlightBar()
    {
        Root.Child = _button;
        _button.Click += (_, _) => Pressed?.Invoke(Shown);
    }

    public void SetTheme(Theme theme)
    {
        var colors = ReadingCss.Colors(theme);
        Root.Background = ToolStyle.Brush(colors.Page);
        Root.BorderBrush = ToolStyle.Brush(colors.Ink.WithAlpha(0.15));
        Root.BorderThickness = new Thickness(1);
        ToolStyle.Quiet(_button, colors.Ink);
        _button.CornerRadius = new CornerRadius(ToolPlacement.BarHeight / 2);
        _button.FontWeight = FontWeights.Medium;
        _button.Resources["ButtonBackgroundPointerOver"] = ToolStyle.Brush(colors.Ink.WithAlpha(0.06));
        _button.Resources["ButtonBackgroundPressed"] = ToolStyle.Brush(colors.Ink.WithAlpha(0.12));
    }

    public void Show(Mode mode, Box frame)
    {
        Shown = mode;
        var title = mode == Mode.Add ? "Highlight" : "Remove";
        _button.Content = title;
        AutomationProperties.SetName(_button, mode == Mode.Add ? "Highlight the selected words" : "Remove this highlight");
        Canvas.SetLeft(Root, frame.X);
        Canvas.SetTop(Root, frame.Y);
        Root.Visibility = Visibility.Visible;
    }

    public void Hide() => Root.Visibility = Visibility.Collapsed;

    /// <summary>For the self-checks.</summary>
    public void Press() => Pressed?.Invoke(Shown);
}

/// <summary>
/// The panel ? shows over the book (ShortcutsPanel.swift): every shortcut in two columns of groups,
/// each row a few words on the left and its keys, drawn as key caps, on the right.
/// </summary>
sealed class ShortcutsPanel
{
    public const double Width = 600;
    const double Inset = 22, Gutter = 28, RowHeight = 26;

    public Border Root { get; } = new()
    {
        Width = Width,
        CornerRadius = new CornerRadius(12),
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Padding = new Thickness(Inset, 12, Inset, Inset),
        Opacity = 0,
        Visibility = Visibility.Collapsed,
    };

    /// <summary>The keys shown on each row, in order. For the self-checks.</summary>
    public List<string[]> ShownKeys { get; } = [];

    public ShortcutsPanel()
    {
        AutomationProperties.SetName(Root, "Keyboard Shortcuts");
        // A click on the panel isn't a click on the scrim behind it.
        Root.PointerPressed += (_, e) => e.Handled = true;
    }

    public void SetTheme(Theme theme)
    {
        var ink = ToolColors.ChromeInk(theme);
        Root.Background = ToolStyle.Chrome(theme);
        ShownKeys.Clear();
        var grid = new Grid { ColumnSpacing = Gutter };
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(38) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.Children.Add(new TextBlock { Text = "Keyboard Shortcuts", FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = ToolStyle.Brush(ink), VerticalAlignment = VerticalAlignment.Center });
        var hint = new TextBlock { Text = "Esc to close", FontSize = 11, Foreground = ToolStyle.Brush(ink.WithAlpha(0.45)), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(hint, 1);
        grid.Children.Add(hint);
        for (var c = 0; c < ShortcutsHelp.Columns.Length; c++)
        {
            var column = new StackPanel { Spacing = 10 };
            foreach (var section in ShortcutsHelp.Columns[c])
            {
                var group = new StackPanel();
                group.Children.Add(new TextBlock
                {
                    Text = section.Title.ToUpperInvariant(),
                    FontSize = 10.5,
                    FontWeight = FontWeights.SemiBold,
                    CharacterSpacing = 40,
                    Foreground = ToolStyle.Brush(ink.WithAlpha(0.5)),
                    Margin = new Thickness(0, 8, 0, 6),
                });
                foreach (var row in section.Rows)
                {
                    group.Children.Add(Row(row, ink));
                    ShownKeys.Add(row.Keys);
                }
                column.Children.Add(group);
            }
            Grid.SetRow(column, 1);
            Grid.SetColumn(column, c);
            grid.Children.Add(column);
        }
        Root.Child = grid;
    }

    static Grid Row(ShortcutsHelp.Row row, Rgba ink)
    {
        var grid = new Grid { Height = RowHeight };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new TextBlock
        {
            Text = row.Description,
            FontSize = 13,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = ToolStyle.Brush(ink.WithAlpha(0.85)),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var caps = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(8, 0, 0, 0) };
        foreach (var key in row.Keys)
            caps.Children.Add(new Border
            {
                Height = 20,
                MinWidth = 24,
                Padding = new Thickness(7, 0, 7, 0),
                CornerRadius = new CornerRadius(5),
                BorderThickness = new Thickness(1),
                Background = ToolStyle.Brush(ink.WithAlpha(0.1)),
                BorderBrush = ToolStyle.Brush(ink.WithAlpha(0.22)),
                VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock { Text = key, FontSize = 12, FontWeight = FontWeights.Medium, Foreground = ToolStyle.Brush(ink), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            });
        Grid.SetColumn(caps, 1);
        grid.Children.Add(caps);
        AutomationProperties.SetName(grid, $"{row.Description}: {string.Join(" or ", row.Keys)}");
        return grid;
    }
}
