using Readme.Core.Layout;
using Readme.Core.Reader;
using Readme.Core.Storage;
using static Readme.Core.Tests.Samples;

namespace Readme.Core.Tests;

/// <summary>Ported from ReaderCommandsTests.swift, with the Windows key mapping from the plan.</summary>
[TestClass]
public sealed class ReaderCommandTests
{
    static ReaderCommand? Key(string key, Modifiers modifiers = Modifiers.None) => ReaderCommands.FromKey(key, modifiers);

    [TestMethod]
    public void ShortcutsFollowThePlansTable()
    {
        var expected = new Dictionary<ReaderCommand, string>
        {
            [ReaderCommand.BiggerText] = "Ctrl++",
            [ReaderCommand.SmallerText] = "Ctrl+-",
            [ReaderCommand.ToggleToc] = "Ctrl+T",
            [ReaderCommand.ToggleHighlights] = "Ctrl+Shift+H",
            [ReaderCommand.ToggleMarker] = "Ctrl+D",
            [ReaderCommand.GoToMarker] = "Ctrl+Shift+D",
            [ReaderCommand.GoToPage] = "Ctrl+G",
            [ReaderCommand.Find] = "Ctrl+F",
            [ReaderCommand.ShowLibrary] = "Ctrl+L",
            [ReaderCommand.GoToStart] = "Ctrl+Home",
            [ReaderCommand.GoToEnd] = "Ctrl+End",
            [ReaderCommand.ToggleFullscreen] = "F11",
            [ReaderCommand.ShowShortcuts] = "Ctrl+/",
        };
        foreach (var command in ReaderCommands.All) Assert.AreEqual(expected[command], command.Shortcut().Label, command.ToString());
    }

    [TestMethod]
    public void NoTwoCommandsShareAShortcut()
    {
        var shortcuts = ReaderCommands.All.Select(c => c.Shortcut()).ToList();
        Assert.AreEqual(shortcuts.Count, shortcuts.Distinct().Count());
    }

    [TestMethod]
    public void EachShortcutMapsToItsCommand()
    {
        foreach (var command in ReaderCommands.All)
            Assert.AreEqual(command, Key(command.Shortcut().Key, command.Shortcut().Modifiers), command.ToString());
    }

    [TestMethod]
    public void QuestionMarkShowsTheShortcuts()
    {
        Assert.AreEqual(ReaderCommand.ShowShortcuts, Key("?", Modifiers.Shift));
        Assert.AreEqual(ReaderCommand.ShowShortcuts, Key("?"));
        Assert.IsNull(Key("?", Modifiers.Alt | Modifiers.Shift));
        Assert.IsNull(Key("/"));
        Assert.AreEqual(new KeyAction.Command(ReaderCommand.ShowShortcuts), KeyAction.Of("?", Modifiers.Shift, false, false, false));
        Assert.IsNull(KeyAction.Of("?", Modifiers.Shift, false, false, isTyping: true));
    }

    [TestMethod]
    public void TheBrowsersUpperCaseKeysCount()
    {
        // KeyboardEvent.key is "H" with Shift held.
        Assert.AreEqual(ReaderCommand.ToggleHighlights, Key("H", Modifiers.Ctrl | Modifiers.Shift));
        Assert.AreEqual(ReaderCommand.GoToMarker, Key("D", Modifiers.Ctrl | Modifiers.Shift));
        Assert.AreEqual(ReaderCommand.Find, Key("F", Modifiers.Ctrl));
    }

    [TestMethod]
    public void BiggerTextWithOrWithoutShift()
    {
        Assert.AreEqual(ReaderCommand.BiggerText, Key("=", Modifiers.Ctrl));
        Assert.AreEqual(ReaderCommand.BiggerText, Key("+", Modifiers.Ctrl | Modifiers.Shift));
    }

    [TestMethod]
    public void HomeEndAndF()
    {
        Assert.AreEqual(ReaderCommand.GoToStart, Key("Home"));
        Assert.AreEqual(ReaderCommand.GoToEnd, Key("End"));
        Assert.AreEqual(ReaderCommand.ToggleFullscreen, Key("f"));
        Assert.IsNull(Key("f", Modifiers.Alt));
        // The Windows key is the system's, never the app's.
        Assert.AreEqual(ReaderCommand.Find, Key("f", Modifiers.Ctrl | Modifiers.Win));
    }

    [TestMethod]
    public void OtherKeysAreNotCommands()
    {
        Assert.IsNull(Key("ArrowRight"));
        Assert.IsNull(Key(" "));
        Assert.IsNull(Key("t"));
        Assert.IsNull(Key("x", Modifiers.Ctrl));
    }

    [TestMethod]
    public void FontSizeLimits()
    {
        var size = 18.0;
        for (var i = 0; i < 40; i++) size = ReaderCommands.FontSizeAfter(ReaderCommand.BiggerText, size);
        Assert.AreEqual(40, size);
        for (var i = 0; i < 40; i++) size = ReaderCommands.FontSizeAfter(ReaderCommand.SmallerText, size);
        Assert.AreEqual(12, size);
        Assert.AreEqual(40, ReaderCommands.FontSizeAfter(ReaderCommand.BiggerText, 90));
        Assert.AreEqual(12, ReaderCommands.FontSizeAfter(ReaderCommand.SmallerText, 3));
        Assert.AreEqual(18, ReaderCommands.FontSizeAfter(ReaderCommand.ToggleToc, 18));
    }

    [TestMethod]
    public void KeysTurnPages()
    {
        Assert.AreEqual(new KeyAction.Turn(TurnDirection.Forward, false), KeyAction.Of("ArrowRight", Modifiers.None, false, false, false));
        Assert.AreEqual(new KeyAction.Turn(TurnDirection.Forward, true), KeyAction.Of(" ", Modifiers.None, true, false, false));
        Assert.AreEqual(new KeyAction.Turn(TurnDirection.Backward, false), KeyAction.Of("ArrowLeft", Modifiers.Shift, false, false, false));
        Assert.IsNull(KeyAction.Of("ArrowRight", Modifiers.Ctrl, false, false, false));
        Assert.IsNull(KeyAction.Of("ArrowRight", Modifiers.None, false, false, isTyping: true));
    }

    [TestMethod]
    public void OnlyTextSizeRepeatsWhileAKeyIsHeld()
    {
        Assert.AreEqual(new KeyAction.Command(ReaderCommand.BiggerText), KeyAction.Of("=", Modifiers.Ctrl, true, false, false));
        Assert.AreEqual(new KeyAction.Ignore(), KeyAction.Of("F11", Modifiers.None, true, false, false));
    }

    [TestMethod]
    public void EscapeLeavesFullScreenOnly()
    {
        Assert.AreEqual(new KeyAction.LeaveFullscreen(), KeyAction.Of("Escape", Modifiers.None, false, true, false));
        Assert.IsNull(KeyAction.Of("Escape", Modifiers.None, false, false, false));
    }

    [TestMethod]
    public void TheContentsKeepTheirPlainKeys()
    {
        Assert.IsNull(KeyAction.Of("ArrowRight", Modifiers.None, false, false, false, isInContents: true));
        Assert.AreEqual(new KeyAction.CloseContents(), KeyAction.Of("Escape", Modifiers.None, false, false, false, isInContents: true));
        Assert.AreEqual(new KeyAction.Command(ReaderCommand.ToggleToc), KeyAction.Of("t", Modifiers.Ctrl, false, false, false, isInContents: true));
    }
}

/// <summary>Ported from BookFrameTests.swift.</summary>
[TestClass]
public sealed class BookFrameTests
{
    static readonly ReaderSettings Defaults = new();

    [TestMethod]
    public void TheMockupsWindowShowsTheMockupsBook()
    {
        var layout = new BookFrame(1048, 620, Defaults, false);
        Assert.AreEqual(new Box(34, 34, 980, 552), layout.Frame);
        Assert.AreEqual(2, layout.Columns);
        Assert.AreEqual(18, layout.FontSize);
        Assert.AreEqual(SpreadLayout.ColumnWidth(18, BookFont.EbGaramond, LineWidth.Regular), layout.ColumnWidth);
    }

    [TestMethod]
    public void AWideWindowKeepsTheBookCentred()
    {
        var layout = new BookFrame(1600, 900, Defaults, false);
        Assert.AreEqual(new Box(310, 34, 980, 832), layout.Frame);
        Assert.AreEqual(2, layout.Columns);
    }

    [TestMethod]
    public void ANarrowWindowShowsOneCentredPage()
    {
        var layout = new BookFrame(760, 620, Defaults, false);
        Assert.AreEqual(1, layout.Columns);
        Assert.AreEqual(new Box(100, 34, 560, 552), layout.Frame);
    }

    [TestMethod]
    public void ATallWindowShowsOnePage() => Assert.AreEqual(1, new BookFrame(1048, 1400, Defaults, false).Columns);

    [TestMethod]
    public void TheBookFitsTheWindow()
    {
        var layout = new BookFrame(500, 420, Defaults, false);
        Assert.IsTrue(layout.Frame.X >= 34 && layout.Frame.Right <= 466);
    }

    [TestMethod]
    public void LargeTextGetsAWiderSpreadWhenThereIsRoom()
    {
        var settings = Defaults with { FontSize = 26 };
        var wide = new BookFrame(1800, 1000, settings, false);
        Assert.AreEqual(2, wide.Columns);
        Assert.IsTrue(wide.Frame.Width > 980);
        Assert.IsTrue(SpreadLayout.AvailableColumnWidth(wide.Frame.Width, 2) >= wide.ColumnWidth);
        var narrow = new BookFrame(1048, 620, settings, false);
        Assert.AreEqual(1, narrow.Columns);
        Assert.IsTrue(SpreadLayout.AvailableColumnWidth(narrow.Frame.Width, 1) >= narrow.ColumnWidth);
    }

    [TestMethod]
    public void FullscreenHasLargerTextAndAWiderBook()
    {
        var layout = new BookFrame(1728, 1117, Defaults, true);
        Assert.AreEqual(24, layout.FontSize, 1e-9);
        Assert.AreEqual(2, layout.Columns);
        Assert.AreEqual(1117 * 0.03, layout.Frame.Y, 1);
        Assert.AreEqual(BookFrame.FullscreenSpreadWidth, layout.Frame.Width);
    }
}

/// <summary>Ported from ReaderSettingsTests.swift.</summary>
[TestClass]
public sealed class ReaderSettingsTests
{
    [TestMethod]
    public void DefaultSettings()
    {
        var settings = new ReaderSettings();
        Assert.AreEqual(BookFont.EbGaramond, settings.Font);
        Assert.AreEqual(ThemeChoice.Auto, settings.Theme);
        Assert.AreEqual(18, settings.FontSize);
        Assert.AreEqual(LineWidth.Regular, settings.LineWidth);
    }

    [TestMethod]
    public void AutoFollowsTheSystemAndAnExplicitThemeWins()
    {
        Assert.AreEqual(Theme.Night, new ReaderSettings().ResolvedTheme(true));
        Assert.AreEqual(Theme.Paper, new ReaderSettings().ResolvedTheme(false));
        var sepia = new ReaderSettings { Theme = ThemeChoice.Sepia };
        Assert.AreEqual(Theme.Sepia, sepia.ResolvedTheme(true));
        Assert.AreEqual(Theme.Sepia, sepia.ResolvedTheme(false));
    }

    [TestMethod]
    public void SavesAndLoads()
    {
        using var folder = new TempFolder();
        var settings = new ReaderSettings { Theme = ThemeChoice.Night, Font = BookFont.Literata, FontSize = 21, LineWidth = LineWidth.Wide };
        settings.Save(folder["settings.json"]);
        Assert.AreEqual(settings, ReaderSettings.Load(folder["settings.json"]));
        StringAssert.Contains(File.ReadAllText(folder["settings.json"]), "\"font\": \"literata\"");
    }

    [TestMethod]
    public void LoadsDefaultsWhenNothingSavedOrUnreadable()
    {
        using var folder = new TempFolder();
        Assert.AreEqual(new ReaderSettings(), ReaderSettings.Load(folder["settings.json"]));
        File.WriteAllText(folder["settings.json"], "not json");
        Assert.AreEqual(new ReaderSettings(), ReaderSettings.Load(folder["settings.json"]));
    }

    [TestMethod]
    public void CssValues()
    {
        var settings = new ReaderSettings();
        var css = ReadingCss.Css(settings, Theme.Paper, false);
        StringAssert.Contains(css, "line-height: 1.55");
        StringAssert.Contains(css, "hyphens: auto");
        StringAssert.Contains(css, "text-align: justify");
        StringAssert.Contains(css, "#F8F5EE");
        Assert.AreEqual("#F8F5EE", ReadingCss.Colors(Theme.Paper).Page.ToHex());
        Assert.AreEqual("#EFE0C4", ReadingCss.Colors(Theme.Sepia).Page.ToHex());
        Assert.AreEqual("#26272A", ReadingCss.Colors(Theme.Night).Page.ToHex());
        Assert.AreEqual("#BDB9AF", ReadingCss.Colors(Theme.Night).Ink.ToHex());
        Assert.AreEqual("#3A332C", ReadingCss.Colors(Theme.Paper).Desk.ToHex());
        Assert.AreEqual("#4A3A28", ReadingCss.Colors(Theme.Sepia).Desk.ToHex());
        Assert.AreEqual("#17181A", ReadingCss.Colors(Theme.Night).Desk.ToHex());
        var night = ReadingCss.Css(settings, Theme.Night, false);
        Assert.IsTrue(night.Contains("#26272A") && night.Contains("#BDB9AF"));
    }

    [TestMethod]
    public void FontFamilies()
    {
        StringAssert.Contains(ReadingCss.Css(new ReaderSettings(), Theme.Paper, false), "font-family: \"EB Garamond\"");
        StringAssert.Contains(ReadingCss.Css(new ReaderSettings { Font = BookFont.Literata }, Theme.Paper, false), "font-family: \"Literata\"");
        var fraunces = ReadingCss.Css(new ReaderSettings { Font = BookFont.Fraunces }, Theme.Paper, false);
        StringAssert.Contains(fraunces, "font-family: \"Fraunces\"");
        StringAssert.Contains(fraunces, "readme-book://app/fonts/Fraunces.ttf");
    }

    [TestMethod]
    public void FullscreenTextIsLarger()
    {
        StringAssert.Contains(ReadingCss.Css(new ReaderSettings(), Theme.Paper, false), "font-size: 18px");
        StringAssert.Contains(ReadingCss.Css(new ReaderSettings(), Theme.Paper, true), "font-size: 24px");
    }

    [TestMethod]
    public void BookStylesLoseForBodyTextButItalicsAndImagesSurvive()
    {
        var css = ReadingCss.Css(new ReaderSettings(), Theme.Paper, false);
        StringAssert.Contains(css, "color: #2B261F !important");
        StringAssert.Contains(css, "line-height: 1.55 !important");
        Assert.IsFalse(css.Contains("font-style: normal !important") || css.Contains("font-style: inherit"));
        Assert.IsFalse(css.Contains("img {"));
    }
}

[TestClass]
public sealed class PlaceKeeperTests
{
    [TestMethod]
    public void ACaptureIsUsedUnlessAPageTurnedSince()
    {
        var places = new PlaceKeeper();
        var capture = places.Take("a");
        Assert.AreEqual("a", places.Target(capture));
        Assert.IsFalse(places.HasTurnedSince(capture));
        places.Turned();
        Assert.IsNull(places.Target(capture));
        Assert.IsTrue(places.HasTurnedSince(capture));
        Assert.IsNull(places.Target(null));
        Assert.IsFalse(places.HasTurnedSince(null));
    }

    [TestMethod]
    public void ALayoutChangeKeepsItsFirstPlaceUntilItEnds()
    {
        var places = new PlaceKeeper();
        places.BeginLayoutChange("start");
        places.BeginLayoutChange("later");
        Assert.IsTrue(places.IsChangingLayout);
        Assert.AreEqual("start", places.EndLayoutChange()?.Cfi);
        Assert.IsFalse(places.IsChangingLayout);
        Assert.IsNull(places.EndLayoutChange());
    }

    [TestMethod]
    public void ThePlaceIsWhereTheReaderWent()
    {
        var places = new PlaceKeeper();
        Assert.AreEqual("shown", places.PlaceShowing("shown"));
        places.MovedTo("went");
        Assert.AreEqual("went", places.PlaceShowing("shown"));
    }
}

/// <summary>Ported from LaunchRouteTests.swift.</summary>
[TestClass]
public sealed class LaunchRouteTests
{
    static Model.ReaderLocation PlaceAt(string cfi) => Place with { Cfi = cfi };

    [TestMethod]
    public void NoBooksOrNoneReadShowTheLibrary()
    {
        using var folder = new TempFolder();
        var library = new LibraryStore(folder.Path);
        Assert.IsInstanceOfType<LaunchRoute.Library>(LaunchRoute.Resolve(library, _ => null, _ => true));
        library.Add(Book("a", 1));
        library.Add(Book("b", 2));
        Assert.IsInstanceOfType<LaunchRoute.Library>(LaunchRoute.Resolve(library, _ => null, _ => true));
    }

    [TestMethod]
    public void TheBookLastReadOpensAtItsPlace()
    {
        using var folder = new TempFolder();
        var library = new LibraryStore(folder.Path);
        library.Add(Book("old", 1, 10));
        library.Add(Book("last", 2, 20));
        library.Add(Book("new", 30));
        var places = new Dictionary<string, Model.ReaderLocation> { ["old"] = PlaceAt("epubcfi(/6/4!/4/2)"), ["last"] = PlaceAt("epubcfi(/6/8!/4/2)") };
        var route = LaunchRoute.Resolve(library, id => places.GetValueOrDefault(id), _ => true);
        Assert.AreEqual(new LaunchRoute.Read(library.Book("last")!, "epubcfi(/6/8!/4/2)"), route);
    }

    [TestMethod]
    public void WithNoPlaceItOpensAtTheStartAndWithItsFileGoneTheLibraryShows()
    {
        using var folder = new TempFolder();
        var library = new LibraryStore(folder.Path);
        library.Add(Book("last", 2, 20));
        Assert.AreEqual(new LaunchRoute.Read(library.Book("last")!, null), LaunchRoute.Resolve(library, _ => null, _ => true));
        Assert.IsInstanceOfType<LaunchRoute.Library>(LaunchRoute.Resolve(library, _ => null, _ => false));
    }
}

[TestClass]
public sealed class PlaceWriterTests
{
    /// <summary>Places for two books given faster than they're written are both kept, each its newest.</summary>
    [TestMethod]
    public async Task EachBookKeepsItsNewestPlace()
    {
        using var folder = new TempFolder();
        var store = new PositionStore(folder.Path);
        var writer = new PlaceWriter(store);
        var later = Place with { Cfi = "epubcfi(/6/16!/4/2,/1:0,/1:80)" };
        var other = Place with { Cfi = "epubcfi(/6/4!/4/2,/1:0,/1:20)" };
        for (var i = 0; i < 200; i++) writer.Save(Place with { Page = i }, "a");
        writer.Save(other, "b");
        writer.Save(later, "a");
        await writer.WrittenAsync();
        Assert.AreEqual(later, store.Location("a"));
        Assert.AreEqual(other, store.Location("b"));
    }

    [TestMethod]
    public async Task WrittenReturnsAtOnceWithNothingToWrite() =>
        await new PlaceWriter(new PositionStore(Path.GetTempPath())).WrittenAsync();
}

[TestClass]
public sealed class SpineShadowTests
{
    [TestMethod]
    public void DarkestAtTheSpineAndGoneAtItsReach()
    {
        Assert.AreEqual(0.68, SpineShadow.ShareAt(0), 1e-9);
        Assert.AreEqual(0, SpineShadow.ShareAt(SpineShadow.Reach));
        Assert.AreEqual(0, SpineShadow.ShareAt(100));
        Assert.AreEqual(0.32, SpineShadow.ShareAt(12), 1e-9);
        Assert.IsTrue(SpineShadow.ShareAt(5) > SpineShadow.ShareAt(10));
    }
}
