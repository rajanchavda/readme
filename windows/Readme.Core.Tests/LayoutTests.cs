using Readme.Core.Layout;
using static Readme.Core.Tests.Samples;

namespace Readme.Core.Tests;

/// <summary>Ported from ShelfLayoutTests.swift (the layout part) and ReaderSettingsTests.swift (SpreadLayout).</summary>
[TestClass]
public sealed class LayoutTests
{
    static int[] Counts<T>(IReadOnlyList<IReadOnlyList<T>> rows) => rows.Select(r => r.Count).ToArray();

    [TestMethod]
    public void RowsFillTheWidthInOrder()
    {
        var rows = ShelfLayout.Rows(Enumerable.Range(0, 12).ToList(), 980);
        CollectionAssert.AreEqual(new[] { 6, 6 }, Counts(rows));
        CollectionAssert.AreEqual(Enumerable.Range(0, 12).ToArray(), rows.SelectMany(r => r).ToArray());
        CollectionAssert.AreEqual(new[] { 6, 1 }, Counts(ShelfLayout.Rows(Enumerable.Range(0, 7).ToList(), 980)));
        Assert.AreEqual(0, ShelfLayout.Rows(new List<int>(), 980).Count);
        Assert.AreEqual(9, ShelfLayout.Rows(Enumerable.Range(0, 20).ToList(), 1400)[0].Count);
    }

    [TestMethod]
    public void ARowHoldsAtLeastOne()
    {
        Assert.IsTrue(ShelfLayout.Rows(Enumerable.Range(0, 3).ToList(), 400).All(r => r.Count >= 1));
        CollectionAssert.AreEqual(new[] { 1, 1, 1 }, Counts(ShelfLayout.Rows(Enumerable.Range(0, 3).ToList(), 50)));
        CollectionAssert.AreEqual(new[] { 1, 1, 1 }, Counts(ShelfLayout.Rows(Enumerable.Range(0, 3).ToList(), 0)));
        Assert.AreEqual(1, ShelfLayout.BooksPerRow(double.NaN));
    }

    [TestMethod]
    public void EmptyShelvesFillTheWindow()
    {
        foreach (var height in new[] { 0.0, 100, 300, 600, 900, 1400, double.NaN })
            Assert.IsTrue(ShelfLayout.EmptyRowCount(height) >= 1, $"{height}");
        Assert.IsTrue(ShelfLayout.EmptyRowCount(1400) > ShelfLayout.EmptyRowCount(600));
    }

    [TestMethod]
    public void TwoPagesWhenWide() => Assert.AreEqual(2, SpreadLayout.Columns(1200, 18, LineWidth.Regular));

    [TestMethod]
    public void OnePageWhenNarrow() => Assert.AreEqual(1, SpreadLayout.Columns(700, 18, LineWidth.Regular));

    [TestMethod]
    public void LargeTextDropsToOnePage() => Assert.AreEqual(1, SpreadLayout.Columns(1000, 32, LineWidth.Regular));

    [TestMethod]
    public void LineWidthSetsCharactersPerColumn()
    {
        Assert.AreEqual(45, SpreadLayout.Characters(LineWidth.Narrow));
        Assert.AreEqual(52, SpreadLayout.Characters(LineWidth.Regular));
        Assert.AreEqual(60, SpreadLayout.Characters(LineWidth.Wide));
        var narrow = SpreadLayout.ColumnWidth(18, BookFont.Literata, LineWidth.Narrow);
        var regular = SpreadLayout.ColumnWidth(18, BookFont.Literata, LineWidth.Regular);
        var wide = SpreadLayout.ColumnWidth(18, BookFont.Literata, LineWidth.Wide);
        Assert.IsTrue(narrow < regular && regular < wide);
        // Literata is wider than EB Garamond, so the same characters need more room.
        Assert.IsTrue(regular > SpreadLayout.ColumnWidth(18, BookFont.EbGaramond, LineWidth.Regular));
    }

    [TestMethod]
    public void PortraitAreaIsOnePageHoweverWide()
    {
        Assert.AreEqual(1, SpreadLayout.Columns(1200, 18, LineWidth.Regular, windowHeight: 1300));
        Assert.AreEqual(2, SpreadLayout.Columns(1200, 18, LineWidth.Regular, windowHeight: 800));
    }

    [TestMethod]
    public void AvailableColumnWidthMatchesTheMac()
    {
        // 980 * 0.93 / 2 - 980 * 0.07, as the Swift code works it out.
        Assert.AreEqual(387.1, SpreadLayout.AvailableColumnWidth(980, 2), 1e-9);
    }
}

/// <summary>Ported from ShelfSearchTests.swift.</summary>
[TestClass]
public sealed class ShelfSearchTests
{
    static Model.Book Titled(string id, string title, string? author = null) => Book(id, 0, title: title, author: author);

    [TestMethod]
    public void MatchesTitleIgnoringCaseAndAccents()
    {
        var miserables = Titled("a", "Les Misérables");
        Assert.IsTrue(ShelfSearch.Matches(miserables, "miserables"));
        Assert.IsTrue(ShelfSearch.Matches(miserables, "MISÉR"));
        Assert.IsTrue(ShelfSearch.Matches(miserables, "les mis"));
    }

    [TestMethod]
    public void MatchesAuthor() => Assert.IsTrue(ShelfSearch.Matches(Titled("a", "Anna Karenina", "Leo Tolstoy"), "tolstoy"));

    [TestMethod]
    public void EveryWordMustMatch()
    {
        var dune = Titled("a", "Dune", "Frank Herbert");
        Assert.IsTrue(ShelfSearch.Matches(dune, "dune herbert"));
        Assert.IsFalse(ShelfSearch.Matches(dune, "dune asimov"));
    }

    [TestMethod]
    public void NoAuthorMatchesOnTitle()
    {
        var emma = Titled("a", "Emma");
        Assert.IsTrue(ShelfSearch.Matches(emma, "emm"));
        Assert.IsFalse(ShelfSearch.Matches(emma, "austen"));
    }

    [TestMethod]
    public void BlankQueryMatchesEverything()
    {
        var books = new[] { Titled("b", "Emma"), Titled("a", "Dune") };
        CollectionAssert.AreEqual(new[] { "b", "a" }, ShelfSearch.Filter(books, "   ").Select(b => b.Id).ToArray());
    }

    [TestMethod]
    public void FilterKeepsOrder()
    {
        var books = new[] { Titled("c", "Dune"), Titled("a", "Dune Messiah"), Titled("b", "Emma") };
        CollectionAssert.AreEqual(new[] { "c", "a" }, ShelfSearch.Filter(books, "dune").Select(b => b.Id).ToArray());
    }

    [TestMethod]
    public void CloseClearsAndFolds()
    {
        var search = new ShelfSearch();
        search.Open();
        Assert.IsTrue(search.IsOpen);
        Assert.AreEqual(1, search.FocusRequest);
        search.Query = "x";
        search.Close();
        Assert.AreEqual("", search.Query);
        Assert.IsFalse(search.IsOpen);
    }

    [TestMethod]
    public void IsActiveIgnoresWhitespace()
    {
        var search = new ShelfSearch { Query = "  " };
        Assert.IsFalse(search.IsActive);
        search.Query = " a ";
        Assert.IsTrue(search.IsActive);
    }

    [TestMethod]
    public void EscapeClosesOpenSearchFirst()
    {
        var search = new ShelfSearch();
        search.Open();
        search.Query = "a";
        var fellThrough = 0;
        ShelfSearch.Escape(search, () => fellThrough++);
        Assert.IsFalse(search.IsOpen);
        Assert.AreEqual("", search.Query);
        Assert.AreEqual(0, fellThrough);
        ShelfSearch.Escape(search, () => fellThrough++);
        Assert.AreEqual(1, fellThrough);
    }
}
