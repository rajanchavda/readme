using System.Globalization;
using Readme.Core.Model;
using Readme.Core.Reader;

namespace Readme.Core.Tests;

/// <summary>Ported from IdleTimerTests.swift.</summary>
[TestClass]
public sealed class IdleTimerTests
{
    [TestMethod]
    public void AwakeStraightAfterActivity()
    {
        var timer = new IdleTimer();
        timer.Activity(100);
        Assert.IsTrue(timer.IsAwake(100));
        Assert.IsTrue(timer.IsAwake(101.5));
    }

    [TestMethod]
    public void AsleepAfterTheDelay()
    {
        var timer = new IdleTimer();
        timer.Activity(100);
        Assert.IsFalse(timer.IsAwake(101.6));
        Assert.IsFalse(timer.IsAwake(200));
    }

    [TestMethod]
    public void ActivityWakesItAgain()
    {
        var timer = new IdleTimer();
        timer.Activity(100);
        Assert.IsFalse(timer.IsAwake(102));
        timer.Activity(102);
        Assert.IsTrue(timer.IsAwake(102));
        Assert.IsTrue(timer.IsAwake(103));
    }

    [TestMethod]
    public void AsleepBeforeAnyActivity() => Assert.IsFalse(new IdleTimer().IsAwake(0));

    [TestMethod]
    public void SleepingEndsTheWait()
    {
        var timer = new IdleTimer();
        timer.Activity(100);
        timer.Sleep();
        Assert.IsFalse(timer.IsAwake(100));
    }
}

/// <summary>Ported from TOCProgressTests.swift.</summary>
[TestClass]
public sealed class TocProgressTests
{
    static TocEntry[] Entries(params double[] fractions) =>
        fractions.Select((f, i) => new TocEntry { Title = $"Chapter {i + 1}", Href = $"ch{i + 1}.xhtml", Level = 0, Fraction = f }).ToArray();

    static void Expect(TocState[] expected, TocState[] actual) => CollectionAssert.AreEqual(expected, actual);

    const TocState R = TocState.Read, C = TocState.Current, U = TocState.Unread;

    [TestMethod] public void ChaptersBeforeTheCurrentOneAreRead() => Expect([R, C, U], TocProgress.States(Entries(0, 0.5, 0.8), 0.6));
    [TestMethod] public void TheFirstChapterIsCurrentAtTheStart() => Expect([C, U, U], TocProgress.States(Entries(0, 0.5, 0.8), 0));
    [TestMethod] public void NoEntriesHaveNoStates() => Assert.AreEqual(0, TocProgress.States([], 0.4).Length);
    [TestMethod] public void AChapterStartingWhereTheSpreadDoesIsCurrent() => Expect([R, C, U], TocProgress.States(Entries(0, 0.5, 0.8), 0.5 - 1e-12));
    [TestMethod] public void TheLastChapterIsCurrentAtTheEnd() => Expect([R, R, C], TocProgress.States(Entries(0, 0.5, 0.8), 1));
    [TestMethod] public void BeforeTheFirstEntryNothingIsCurrent() => Expect([U, U], TocProgress.States(Entries(0.1, 0.5), 0.02));

    [TestMethod]
    public void AnEntryWithNoPlaceIsNeverCurrent()
    {
        TocEntry[] entries =
        [
            new() { Title = "One", Href = "a.xhtml", Level = 0, Fraction = 0 },
            new() { Title = "Lost", Href = "missing.xhtml", Level = 0, Fraction = null },
            new() { Title = "Two", Href = "b.xhtml", Level = 0, Fraction = 0.5 },
        ];
        Expect([C, U, U], TocProgress.States(entries, 0.2));
        Expect([R, R, C], TocProgress.States(entries, 0.6));
    }
}

/// <summary>Ported from SearchResultsTests.swift.</summary>
[TestClass]
public sealed class SearchResultsTests
{
    static readonly CultureInfo English = CultureInfo.GetCultureInfo("en-US");

    static SearchMatch Match(int page, string? chapter) =>
        new() { Cfi = "epubcfi(/6/2!/4/2,/1:0,/1:5)", Pre = "the girl ", Match = "Elena", Post = " stood", Page = page, Chapter = chapter };

    static SearchOutcome Outcome(int count, bool capped = false) => new(Enumerable.Repeat(Match(1, null), count).ToList(), capped);

    [TestMethod]
    public void SearchableNeedsTwoCharacters()
    {
        Assert.IsFalse(SearchResults.IsSearchable(""));
        Assert.IsFalse(SearchResults.IsSearchable("e"));
        Assert.IsFalse(SearchResults.IsSearchable(" e "));
        Assert.IsTrue(SearchResults.IsSearchable("el"));
    }

    [TestMethod]
    public void CountText()
    {
        Assert.AreEqual("No matches", SearchResults.CountText(Outcome(0), English));
        Assert.AreEqual("1 match", SearchResults.CountText(Outcome(1), English));
        Assert.AreEqual("84 matches", SearchResults.CountText(Outcome(84), English));
        Assert.AreEqual("500+ matches, type more to narrow it down", SearchResults.CountText(Outcome(500, capped: true), English));
    }

    [TestMethod]
    public void DetailIsPageAndChapter()
    {
        Assert.AreEqual("142 · The Letter", SearchResults.Detail(Match(142, "The Letter")));
        Assert.AreEqual("142", SearchResults.Detail(Match(142, null)));
        Assert.AreEqual("142", SearchResults.Detail(Match(142, "  ")));
    }

    [TestMethod]
    public void TheLimitIsFiveHundred()
    {
        Assert.AreEqual(500, SearchResults.Limit);
        Assert.AreEqual(2, SearchResults.MinimumLength);
    }

    [TestMethod]
    public void ALongStartIsCutAtAWord()
    {
        Assert.AreEqual("the girl ", SearchResults.ShortPre("the girl "));
        var pre = "It was a bright cold day in April, and the clocks were striking ";
        Assert.AreEqual("… and the clocks were striking ", SearchResults.ShortPre(pre));
        Assert.AreEqual("…", SearchResults.ShortPre(new string('x', 40)));
    }
}

/// <summary>Ported from GoToPageTests.swift.</summary>
[TestClass]
public sealed class GoToPageTests
{
    [TestMethod]
    public void APageIsWhereItsTextBegins()
    {
        Assert.AreEqual(0.0, GoToPage.Fraction("1", 100));
        Assert.AreEqual(0.5, GoToPage.Fraction("51", 100));
        Assert.AreEqual(0.5, GoToPage.Fraction(" 51 ", 100));
    }

    [TestMethod]
    public void OnlyAWholeNumberIsAPage()
    {
        foreach (var typed in new[] { "", "  ", "twelve", "12.5", "12a" })
            Assert.IsNull(GoToPage.Fraction(typed, 100), typed);
    }

    [TestMethod]
    public void APageOutsideTheBookIsTheNearestOne()
    {
        Assert.AreEqual(0.0, GoToPage.Fraction("0", 100));
        Assert.AreEqual(0.0, GoToPage.Fraction("-4", 100));
        Assert.AreEqual(0.99, GoToPage.Fraction("100", 100));
        Assert.AreEqual(0.99, GoToPage.Fraction("5000", 100));
        Assert.AreEqual(0.99, GoToPage.Fraction("99999999999999999999999", 100));
    }

    [TestMethod]
    public void TheTypedPageIsInTheBook()
    {
        Assert.AreEqual(51, GoToPage.Page("51", 100));
        Assert.AreEqual(1, GoToPage.Page("0", 100));
        Assert.AreEqual(100, GoToPage.Page("500", 100));
        Assert.IsNull(GoToPage.Page("x", 100));
    }

    [TestMethod]
    public void ABookWithNoPagesHasNowhereToGo() => Assert.IsNull(GoToPage.Fraction("1", 0));

    [TestMethod]
    public void TheFieldShowsThePageAndTotal()
    {
        var english = CultureInfo.GetCultureInfo("en-US");
        Assert.AreEqual("214 of 1,240", GoToPage.Placeholder(214, 1240, english));
        Assert.AreEqual("1 of 9", GoToPage.Placeholder(1, 9, english));
    }
}

/// <summary>Ported from TimeLeftTests in BookFrameTests.swift.</summary>
[TestClass]
public sealed class ChapterTimeLeftTests
{
    [TestMethod]
    public void SaysHowLongIsLeft()
    {
        Assert.AreEqual("Under a minute left in chapter", ChapterTimeLeft.Text(0.4));
        Assert.AreEqual("1 min left in chapter", ChapterTimeLeft.Text(1.2));
        Assert.AreEqual("23 min left in chapter", ChapterTimeLeft.Text(23));
        Assert.AreEqual("1 hr left in chapter", ChapterTimeLeft.Text(60));
        Assert.AreEqual("1 hr 35 min left in chapter", ChapterTimeLeft.Text(95));
    }
}

/// <summary>Ported from ShortcutsHelpTests.swift, with Windows' key names.</summary>
[TestClass]
public sealed class ShortcutsHelpTests
{
    static List<ShortcutsHelp.Row> Rows => ShortcutsHelp.Sections.SelectMany(s => s.Rows).ToList();

    /// <summary>A new command can't be left out of the panel, or shown twice.</summary>
    [TestMethod]
    public void EveryCommandIsListedOnce()
    {
        foreach (var command in ReaderCommands.All)
            Assert.AreEqual(1, Rows.Count(r => r.Equals(ShortcutsHelp.RowFor(command))), command.ToString());
    }

    /// <summary>The plain keys listed are ones the reader takes for the command.</summary>
    [TestMethod]
    public void PlainKeysDoTheirCommand()
    {
        var typed = new Dictionary<string, string> { ["Home"] = "Home", ["End"] = "End", ["F"] = "f", ["?"] = "?" };
        foreach (var command in ReaderCommands.All)
            foreach (var name in ShortcutsHelp.PlainKeys(command))
                Assert.AreEqual(command, ReaderCommands.FromKey(typed[name], Modifiers.None), name);
    }

    [TestMethod]
    public void RowsShowEveryWayToDoIt()
    {
        CollectionAssert.AreEqual(new[] { "Ctrl+Home", "Home" }, ShortcutsHelp.RowFor(ReaderCommand.GoToStart).Keys);
        CollectionAssert.AreEqual(new[] { "F11", "F" }, ShortcutsHelp.RowFor(ReaderCommand.ToggleFullscreen).Keys);
        CollectionAssert.AreEqual(new[] { "Ctrl+/", "?" }, ShortcutsHelp.RowFor(ReaderCommand.ShowShortcuts).Keys);
        CollectionAssert.AreEqual(new[] { "Ctrl+F" }, ShortcutsHelp.RowFor(ReaderCommand.Find).Keys);
    }

    /// <summary>Every key named in the panel does what its row says, so the panel and the keys can't drift apart.</summary>
    [TestMethod]
    public void EveryListedShortcutIsOneTheReaderTakes()
    {
        foreach (var command in ReaderCommands.All)
        {
            var shortcut = command.Shortcut();
            Assert.AreEqual(command, ReaderCommands.FromKey(shortcut.Key, shortcut.Modifiers), command.ToString());
        }
        Assert.AreEqual(new KeyAction.Turn(TurnDirection.Forward, false), KeyAction.Of("ArrowRight", Modifiers.None, false, false, false));
        Assert.AreEqual(new KeyAction.Turn(TurnDirection.Forward, false), KeyAction.Of(" ", Modifiers.None, false, false, false));
        Assert.AreEqual(new KeyAction.Turn(TurnDirection.Backward, false), KeyAction.Of("ArrowLeft", Modifiers.None, false, false, false));
    }

    [TestMethod]
    public void LibraryKeysAreListed()
    {
        var library = ShortcutsHelp.Sections.Single(s => s.Title == "Library");
        CollectionAssert.AreEqual(new ShortcutsHelp.Row[] { new(["Ctrl+F"], "Search the library"), new(["Esc"], "Clear the search") }, library.Rows);
    }
}

/// <summary>Ported from HighlightBar.frame and MarkerRibbon.frame, measured from the top left.</summary>
[TestClass]
public sealed class ToolPlacementTests
{
    static readonly Box Desk = new(0, 0, 1000, 700);

    [TestMethod]
    public void TheBarSitsCentredAboveTheWords()
    {
        var bar = ToolPlacement.HighlightBar(new Box(400, 300, 200, 20), Desk);
        Assert.AreEqual(new Box(448, 262, 104, 30), bar);
    }

    [TestMethod]
    public void WithNoRoomAboveItGoesBelow()
    {
        var bar = ToolPlacement.HighlightBar(new Box(400, 10, 200, 20), Desk);
        Assert.AreEqual(38, bar.Y);
    }

    [TestMethod]
    public void TheBarStaysInside()
    {
        Assert.AreEqual(8, ToolPlacement.HighlightBar(new Box(0, 300, 20, 20), Desk).X);
        Assert.AreEqual(1000 - 104 - 8, ToolPlacement.HighlightBar(new Box(990, 300, 10, 20), Desk).X);
    }

    [TestMethod]
    public void TheRibbonHangsFromTheTopOfTheRightPage() =>
        Assert.AreEqual(new Box(1026 - 34 - 14, 40, 14, 36), ToolPlacement.Ribbon(new Box(70, 40, 956, 600)));

    [TestMethod]
    public void HighlightsAndGlowNeverShareAColour()
    {
        foreach (var theme in Enum.GetValues<Theme>())
            Assert.AreNotEqual(ToolColors.Highlight(theme), ToolColors.Glow(theme), theme.ToString());
    }
}
