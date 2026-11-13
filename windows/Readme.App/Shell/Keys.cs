using Microsoft.UI.Input;
using Readme.App.Reader;
using Readme.Core.Reader;
using Windows.System;
using Windows.UI.Core;

namespace Readme.App;

/// <summary>
/// Keys pressed while the book's page doesn't have the focus, named as the page names them
/// (<c>KeyboardEvent.key</c>), so one mapping serves both.
/// </summary>
static class Keys
{
    /// <summary>The modifier keys held now, as for a click on the shelf.</summary>
    public static Modifiers CurrentModifiers()
    {
        var modifiers = Modifiers.None;
        if (Down(VirtualKey.Control)) modifiers |= Modifiers.Ctrl;
        if (Down(VirtualKey.Shift)) modifiers |= Modifiers.Shift;
        if (Down(VirtualKey.Menu)) modifiers |= Modifiers.Alt;
        if (Down(VirtualKey.LeftWindows) || Down(VirtualKey.RightWindows)) modifiers |= Modifiers.Win;
        return modifiers;
    }

    public static PageKey? FromVirtualKey(VirtualKey key, bool isRepeat)
    {
        var modifiers = CurrentModifiers();
        var shift = modifiers.HasFlag(Modifiers.Shift);
        string? name = key switch
        {
            VirtualKey.Right => "ArrowRight",
            VirtualKey.Left => "ArrowLeft",
            VirtualKey.Up => "ArrowUp",
            VirtualKey.Down => "ArrowDown",
            VirtualKey.Space => " ",
            VirtualKey.Home => "Home",
            VirtualKey.End => "End",
            VirtualKey.PageUp => "PageUp",
            VirtualKey.PageDown => "PageDown",
            VirtualKey.Escape => "Escape",
            VirtualKey.Enter => "Enter",
            VirtualKey.F11 => "F11",
            VirtualKey.Add => "+",
            VirtualKey.Subtract => "-",
            VirtualKey.Divide => "/",
            (VirtualKey)187 => shift ? "+" : "=", // VK_OEM_PLUS
            (VirtualKey)189 => shift ? "_" : "-", // VK_OEM_MINUS
            (VirtualKey)191 => shift ? "?" : "/", // VK_OEM_2
            >= VirtualKey.A and <= VirtualKey.Z => ((char)('a' + (key - VirtualKey.A))).ToString(),
            >= VirtualKey.Number0 and <= VirtualKey.Number9 => ((char)('0' + (key - VirtualKey.Number0))).ToString(),
            _ => null,
        };
        return name == null ? null : new PageKey(name, modifiers, isRepeat);
    }

    static bool Down(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);
}
