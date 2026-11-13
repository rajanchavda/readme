using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Readme.Core.Model;
using Readme.Core.Reader;
using Windows.System;

namespace Readme.App.Reader.Tools;

/// <summary>
/// A quiet sidebar that slides in over the left of the book, with the book blurred beneath it, holding
/// a list. Every colour is the theme's ink at some strength, never the system's accent: the selection,
/// which the arrows move, is a faint wash of it.
/// </summary>
abstract class Sidebar
{
    public const double Width = 280;
    protected Rgba Ink = ReadingCss.Colors(Theme.Paper).Ink;
    protected ListView List = new();
    readonly Rectangle _edge = new() { Width = 1, HorizontalAlignment = HorizontalAlignment.Right };

    public Grid Root { get; } = new() { Width = Width, HorizontalAlignment = HorizontalAlignment.Left };

    protected Sidebar(string name)
    {
        AutomationProperties.SetName(Root, name);
        Root.RenderTransform = new TranslateTransform { X = -Width };
        Root.Visibility = Visibility.Collapsed;
    }

    public void SetTheme(Theme theme)
    {
        Ink = ReadingCss.Colors(theme).Ink;
        Root.Background = ToolStyle.Sidebar(theme);
        Root.RequestedTheme = theme == Theme.Night ? ElementTheme.Dark : ElementTheme.Light;
        _edge.Fill = ToolStyle.Brush(Ink.WithAlpha(0.12));
    }

    /// <summary>A new list each time, so its colours are the theme's from the start.</summary>
    protected void Fill(IEnumerable<FrameworkElement> rows, int selected, double rowHeight)
    {
        Root.Children.Clear();
        var wash = ToolStyle.Brush(Ink.WithAlpha(0.08));
        var stronger = ToolStyle.Brush(Ink.WithAlpha(0.12));
        List = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            IsItemClickEnabled = true,
            Padding = new Thickness(0, 12, 0, 12),
        };
        foreach (var key in new[] { "ListViewItemBackgroundSelected", "ListViewItemBackgroundSelectedPointerOver", "ListViewItemBackgroundPointerOver" })
            List.Resources[key] = wash;
        foreach (var key in new[] { "ListViewItemBackgroundPressed", "ListViewItemBackgroundSelectedPressed" })
            List.Resources[key] = stronger;
        List.Resources["ListViewItemSelectionIndicatorBrush"] = ToolStyle.Clear;
        List.Resources["ListViewItemSelectionIndicatorVisualEnabled"] = false;
        List.Resources["ListViewItemForeground"] = ToolStyle.Brush(Ink);
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, rowHeight));
        style.Setters.Add(new Setter(FrameworkElement.MarginProperty, new Thickness(8, 1, 8, 1)));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        List.ItemContainerStyle = style;
        foreach (var row in rows) List.Items.Add(row);
        List.ItemClick += (_, e) => Chose(List.Items.IndexOf(e.ClickedItem));
        List.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Delete && List.SelectedIndex >= 0)
            {
                e.Handled = true;
                Deleted(List.SelectedIndex);
            }
        };
        Root.Children.Add(List);
        Root.Children.Add(_edge);
        if (selected >= 0 && selected < List.Items.Count)
        {
            List.SelectedIndex = selected;
            List.Loaded += (_, _) => List.ScrollIntoView(List.Items[selected]);
        }
    }

    protected abstract void Chose(int row);
    protected virtual void Deleted(int row) { }

    /// <summary>Hands the keyboard to the list, on the selected row, once the list is on screen with its rows made.</summary>
    public void Focus()
    {
        var list = List;
        if (!list.IsLoaded)
        {
            void Loaded(object sender, RoutedEventArgs e)
            {
                list.Loaded -= Loaded;
                list.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => FocusRow(list));
            }
            list.Loaded += Loaded;
            return;
        }
        FocusRow(list);
    }

    void FocusRow(ListView list)
    {
        if (list != List || !Root.IsHitTestVisible || Root.Visibility != Visibility.Visible) return;
        if (list.SelectedIndex >= 0 && list.ContainerFromIndex(list.SelectedIndex) is ListViewItem item) item.Focus(FocusState.Programmatic);
        else list.Focus(FocusState.Programmatic);
    }

    public bool HasFocus
    {
        get
        {
            if (Root.XamlRoot == null) return false;
            for (var e = FocusManager.GetFocusedElement(Root.XamlRoot) as DependencyObject; e != null; e = VisualTreeHelper.GetParent(e))
                if (e == Root) return true;
            return false;
        }
    }

    public int SelectedRow => List.SelectedIndex;

    public void Select(int row) => List.SelectedIndex = row;
}

/// <summary>
/// The table of contents (TOCSidebar.swift). Chapters already read are dimmed, the one being read is
/// in full ink with a small dot. A click, or Enter on the selected chapter, chooses it.
/// </summary>
sealed class TocSidebar() : Sidebar("Contents")
{
    const double RowHeight = 28, Indent = 14;
    TocState[] _states = [];

    public IReadOnlyList<TocEntry> Entries { get; private set; } = [];
    public event Action<TocEntry>? Chosen;

    /// <summary>Fills the list, with <paramref name="fraction"/> where the spread starts, selecting the chapter being read.</summary>
    public void Show(IReadOnlyList<TocEntry> entries, double fraction)
    {
        Entries = entries;
        _states = TocProgress.States(entries, fraction);
        var current = Array.IndexOf(_states, TocState.Current);
        Fill(entries.Select((e, i) => Row(e, _states[i])), Math.Max(0, current), RowHeight);
    }

    /// <summary>The title's strength: full ink for the chapter being read, dimmer behind, dimmest for one with no place.</summary>
    public double Strength(int row) => Strength(Entries[row], _states[row]);

    static double Strength(TocEntry entry, TocState state) => entry.Fraction == null ? 0.3 : state switch
    {
        TocState.Read => 0.45,
        TocState.Current => 1,
        _ => 0.75,
    };

    public bool IsMarkedCurrent(int row) => _states.ElementAtOrDefault(row) == TocState.Current;

    FrameworkElement Row(TocEntry entry, TocState state)
    {
        var indent = Indent + entry.Level * Indent;
        var isCurrent = state == TocState.Current;
        var title = string.IsNullOrEmpty(entry.Title) ? "Untitled" : entry.Title;
        var row = new Grid { Height = RowHeight };
        row.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 13,
            FontWeight = isCurrent ? FontWeights.Medium : FontWeights.Normal,
            Foreground = ToolStyle.Brush(Ink.WithAlpha(Strength(entry, state))),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(indent, 0, 10, 0),
        });
        if (isCurrent)
            row.Children.Add(new Ellipse
            {
                Width = 5,
                Height = 5,
                Fill = ToolStyle.Brush(Ink),
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(indent - 9, 0, 0, 0),
            });
        ToolTipService.SetToolTip(row, entry.Title);
        AutomationProperties.SetName(row, isCurrent ? $"{title}, reading now" : entry.Fraction == null ? $"{title}, not in this book" : title);
        return row;
    }

    /// <summary>Chooses the entry in <paramref name="row"/>, unless it has no place in the book.</summary>
    public void Choose(int row)
    {
        if (row < 0 || row >= Entries.Count || Entries[row].Fraction == null) return;
        Chosen?.Invoke(Entries[row]);
    }

    protected override void Chose(int row) => Choose(row);
}

/// <summary>
/// The reader's highlights in the open book, in reading order (HighlightsSidebar.swift): each the
/// marked words over their chapter. A click, or Enter, goes there; Delete, or the row's menu, removes it.
/// </summary>
sealed class HighlightsSidebar() : Sidebar("Highlights")
{
    public const string EmptyText = "No highlights yet. Select text to highlight it.";

    public IReadOnlyList<Highlight> Highlights { get; private set; } = [];
    public event Action<Highlight>? Chosen;
    public event Action<Highlight>? Removed;

    public void Show(IReadOnlyList<Highlight> highlights)
    {
        Highlights = highlights;
        Fill(highlights.Select(Row), highlights.Count > 0 ? 0 : -1, 64);
        if (highlights.Count == 0)
            Root.Children.Add(new TextBlock
            {
                Text = EmptyText,
                FontSize = 13,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                Foreground = ToolStyle.Brush(Ink.WithAlpha(0.5)),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(24, 0, 24, 0),
            });
    }

    FrameworkElement Row(Highlight highlight)
    {
        var text = highlight.Text.ReplaceLineEndings(" ");
        var panel = new StackPanel { Margin = new Thickness(14, 6, 14, 6), VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(new TextBlock
        {
            Text = text,
            FontSize = 13,
            MaxLines = 2,
            TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = ToolStyle.Brush(Ink.WithAlpha(0.85)),
        });
        panel.Children.Add(new TextBlock
        {
            Text = highlight.ChapterTitle ?? "",
            FontSize = 11,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = ToolStyle.Brush(Ink.WithAlpha(0.45)),
            Margin = new Thickness(0, 3, 0, 0),
        });
        var row = new Grid { MinHeight = 64, Background = ToolStyle.Clear };
        row.Children.Add(panel);
        ToolTipService.SetToolTip(row, highlight.Text);
        AutomationProperties.SetName(row, highlight.ChapterTitle is { } chapter ? $"{text}, {chapter}" : text);
        var menu = new MenuFlyout();
        var remove = new MenuFlyoutItem { Text = "Remove Highlight" };
        remove.Click += (_, _) => Removed?.Invoke(highlight);
        menu.Items.Add(remove);
        row.ContextFlyout = menu;
        return row;
    }

    public void Choose(int row)
    {
        if (row >= 0 && row < Highlights.Count) Chosen?.Invoke(Highlights[row]);
    }

    public void Remove(int row)
    {
        if (row >= 0 && row < Highlights.Count) Removed?.Invoke(Highlights[row]);
    }

    protected override void Chose(int row) => Choose(row);
    protected override void Deleted(int row) => Remove(row);
}
