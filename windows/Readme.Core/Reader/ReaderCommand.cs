namespace Readme.Core.Reader;

[Flags]
public enum Modifiers { None = 0, Ctrl = 1, Shift = 2, Alt = 4, Win = 8 }

/// <summary>
/// A key and the modifiers held with it. <see cref="Key"/> is named as a browser's
/// <c>KeyboardEvent.key</c> names it ("ArrowRight", " ", "Home", "f", "+"), since most keys reach the
/// app from the page that way; keys pressed with the focus elsewhere are mapped to the same names.
/// </summary>
public readonly record struct KeyShortcut(string Key, Modifiers Modifiers)
{
    /// <summary>How the shortcuts panel shows it, Windows style: "Ctrl+Shift+H".</summary>
    public string Label => LabelOf(Key, Modifiers);

    static string LabelOf(string key, Modifiers modifiers) => string.Join("+",
        new[] { (Modifiers.Ctrl, "Ctrl"), (Modifiers.Alt, "Alt"), (Modifiers.Shift, "Shift") }
            .Where(m => modifiers.HasFlag(m.Item1)).Select(m => m.Item2)
            .Append(key switch
            {
                "ArrowUp" => "Up", "ArrowDown" => "Down", "ArrowLeft" => "Left", "ArrowRight" => "Right",
                " " => "Space",
                { Length: 1 } k => k.ToUpperInvariant(),
                var k => k,
            }));
}

/// <summary>What the reader can ask of the window besides turning pages (ReaderCommand.swift).</summary>
public enum ReaderCommand
{
    BiggerText, SmallerText, ToggleToc, ToggleHighlights, ToggleMarker, ToggleFullscreen, ShowLibrary,
    GoToStart, GoToEnd, GoToPage, GoToMarker, Find, ShowShortcuts,
}

public static class ReaderCommands
{
    public const double MinFontSize = 12;
    public const double MaxFontSize = 40;
    public const double FontSizeStep = 2;

    public static readonly IReadOnlyList<ReaderCommand> All = Enum.GetValues<ReaderCommand>();

    /// <summary>
    /// Each command's shortcut, by the plan's Windows mapping: Cmd becomes Ctrl, except Ctrl+Cmd+F full
    /// screen (F11), and Cmd+Up and Cmd+Down (Ctrl+Home and Ctrl+End).
    /// </summary>
    public static KeyShortcut Shortcut(this ReaderCommand command) => command switch
    {
        ReaderCommand.BiggerText => new("+", Modifiers.Ctrl),
        ReaderCommand.SmallerText => new("-", Modifiers.Ctrl),
        ReaderCommand.ToggleToc => new("t", Modifiers.Ctrl),
        ReaderCommand.ToggleHighlights => new("h", Modifiers.Ctrl | Modifiers.Shift),
        ReaderCommand.ToggleMarker => new("d", Modifiers.Ctrl),
        ReaderCommand.ToggleFullscreen => new("F11", Modifiers.None),
        ReaderCommand.ShowLibrary => new("l", Modifiers.Ctrl),
        ReaderCommand.GoToStart => new("Home", Modifiers.Ctrl),
        ReaderCommand.GoToEnd => new("End", Modifiers.Ctrl),
        ReaderCommand.GoToPage => new("g", Modifiers.Ctrl),
        ReaderCommand.GoToMarker => new("d", Modifiers.Ctrl | Modifiers.Shift),
        ReaderCommand.Find => new("f", Modifiers.Ctrl),
        ReaderCommand.ShowShortcuts => new("/", Modifiers.Ctrl),
        _ => throw new ArgumentOutOfRangeException(nameof(command)),
    };

    public static string Title(this ReaderCommand command) => command switch
    {
        ReaderCommand.BiggerText => "Bigger Text",
        ReaderCommand.SmallerText => "Smaller Text",
        ReaderCommand.ToggleToc => "Contents",
        ReaderCommand.ToggleHighlights => "Highlights",
        ReaderCommand.ToggleMarker => "Mark This Page",
        ReaderCommand.ToggleFullscreen => "Full Screen",
        ReaderCommand.ShowLibrary => "Library",
        ReaderCommand.GoToStart => "Go to Start",
        ReaderCommand.GoToEnd => "Go to End",
        ReaderCommand.GoToPage => "Go to Page…",
        ReaderCommand.GoToMarker => "Go to Marker",
        ReaderCommand.Find => "Find…",
        ReaderCommand.ShowShortcuts => "Keyboard Shortcuts",
        _ => throw new ArgumentOutOfRangeException(nameof(command)),
    };

    /// <summary>
    /// The command a key press asks for, if any: a shortcut, or one of the plain keys that stand in for
    /// one. Home and End go to the start and end, F toggles full screen, and ? shows the shortcuts.
    /// </summary>
    public static ReaderCommand? FromKey(string key, Modifiers modifiers)
    {
        modifiers &= Modifiers.Ctrl | Modifiers.Shift | Modifiers.Alt;
        if (key.Length == 1) key = key.ToLowerInvariant();
        // Ctrl+ is Ctrl= on most layouts, or Ctrl+Shift+= typed as the plus; the number pad's own keys count too.
        if (modifiers.HasFlag(Modifiers.Ctrl) && key is "=" or "+")
        {
            key = "+";
            modifiers &= ~Modifiers.Shift;
        }
        foreach (var command in All)
            if (command.Shortcut() == new KeyShortcut(key, modifiers)) return command;
        // ? is typed with Shift on most layouts, and without it on some.
        if (key == "?" && (modifiers & ~Modifiers.Shift) == Modifiers.None) return ReaderCommand.ShowShortcuts;
        if (modifiers != Modifiers.None) return null;
        return key switch
        {
            "Home" => ReaderCommand.GoToStart,
            "End" => ReaderCommand.GoToEnd,
            "f" => ReaderCommand.ToggleFullscreen,
            _ => null,
        };
    }

    /// <summary>The font size after this command, which only the text size commands change, kept within limits.</summary>
    public static double FontSizeAfter(ReaderCommand command, double size)
    {
        var changed = command switch
        {
            ReaderCommand.BiggerText => size + FontSizeStep,
            ReaderCommand.SmallerText => size - FontSizeStep,
            _ => size,
        };
        return Math.Clamp(changed, MinFontSize, MaxFontSize);
    }
}

public enum TurnDirection { Forward, Backward }

/// <summary>What a key press in the reading window does (KeyAction in ReaderCommand.swift).</summary>
public abstract record KeyAction
{
    public sealed record Command(ReaderCommand Value) : KeyAction;
    public sealed record Turn(TurnDirection Direction, bool IsRepeat) : KeyAction;
    public sealed record LeaveFullscreen : KeyAction;
    public sealed record CloseContents : KeyAction;
    /// <summary>A held key's repeat that does nothing, as only text size changes while a key is held.</summary>
    public sealed record Ignore : KeyAction;

    /// <summary>
    /// Null leaves the key to the rest of the app. Keys typed into a field are the field's. While the
    /// contents are open, the plain keys are theirs, and Esc closes them.
    /// </summary>
    public static KeyAction? Of(string key, Modifiers modifiers, bool isRepeat, bool isFullscreen, bool isTyping,
        bool isInContents = false)
    {
        if (isTyping) return null;
        modifiers &= Modifiers.Ctrl | Modifiers.Shift | Modifiers.Alt;
        var withCommandKeys = modifiers & (Modifiers.Ctrl | Modifiers.Alt);
        if (isInContents && withCommandKeys == Modifiers.None)
        {
            if (key != "Escape" || modifiers != Modifiers.None) return null;
            return isRepeat ? new Ignore() : new CloseContents();
        }
        if (ReaderCommands.FromKey(key, modifiers) is { } command)
        {
            var repeats = command is ReaderCommand.BiggerText or ReaderCommand.SmallerText;
            return isRepeat && !repeats ? new Ignore() : new Command(command);
        }
        // As in the mockup, Esc also leaves full screen.
        if (key == "Escape" && modifiers == Modifiers.None && isFullscreen)
            return isRepeat ? new Ignore() : new LeaveFullscreen();
        if (withCommandKeys != Modifiers.None) return null;
        return key switch
        {
            "ArrowRight" or " " => new Turn(TurnDirection.Forward, isRepeat),
            "ArrowLeft" => new Turn(TurnDirection.Backward, isRepeat),
            _ => null,
        };
    }
}
