using Readme.Core.Model;
using Readme.Core.Storage;
using static Readme.Core.Tests.Samples;

namespace Readme.Core.Tests;

/// <summary>Ported from PositionStoreTests.swift.</summary>
[TestClass]
public sealed class PositionStoreTests
{
    static readonly ReaderLocation Here = Place with { Cfi = "epubcfi(/6/14!/4/2/10,/1:12,/3:40)" };

    [TestMethod]
    public void RoundTrip()
    {
        using var folder = new TempFolder();
        var store = new PositionStore(folder.Path);
        Assert.IsNull(store.Location("book"));
        store.Save(Here, "book");
        Assert.AreEqual(Here, store.Location("book"));
        Assert.IsNull(store.Location("other"));
    }

    [TestMethod]
    public void SurvivesRestart()
    {
        using var folder = new TempFolder();
        new PositionStore(folder.Path).Save(Here, "book");
        Assert.AreEqual(Here, new PositionStore(folder.Path).Location("book"));
    }

    [TestMethod]
    public void CorruptFileIsIgnored()
    {
        using var folder = new TempFolder();
        var store = new PositionStore(folder.Path);
        store.Save(Here, "book");
        File.WriteAllText(Directory.GetFiles(folder.Path).Single(), "{ not a place");
        Assert.IsNull(store.Location("book"));
    }

    [TestMethod]
    public void PlaceSavedWithoutMarkedFlagLoads()
    {
        using var folder = new TempFolder();
        File.WriteAllText(folder["book.json"],
            """{"cfi":"x","fraction":0.5,"chapterMinutesLeft":1,"isAtStart":false,"isAtEnd":false,"page":3,"pageCount":9}""");
        var loaded = new PositionStore(folder.Path).Location("book");
        Assert.IsNotNull(loaded);
        Assert.IsFalse(loaded.IsMarked);
        Assert.IsNull(loaded.ChapterTitle);
    }

    [TestMethod]
    public void TheLatestSaveWins()
    {
        using var folder = new TempFolder();
        var store = new PositionStore(folder.Path);
        var later = Here with { Cfi = "epubcfi(/6/16!/4/2,/1:0,/1:80)", Page = 230 };
        store.Save(Here, "book");
        store.Save(later, "book");
        Assert.AreEqual(later, new PositionStore(folder.Path).Location("book"));
    }

    [TestMethod]
    public void RemoveForgetsTheBook()
    {
        using var folder = new TempFolder();
        var store = new PositionStore(folder.Path);
        store.Save(Here, "book");
        store.Save(Here, "other");
        store.Remove("book");
        Assert.IsNull(store.Location("book"));
        Assert.AreEqual(Here, store.Location("other"));
        store.Remove("never");
    }

    [TestMethod]
    public void MakesItsFolder()
    {
        using var parent = new TempFolder();
        var folder = parent["Positions"];
        new PositionStore(folder).Save(Here, "book");
        Assert.AreEqual(Here, new PositionStore(folder).Location("book"));
    }

    [TestMethod]
    public void OddBookIdsStayInTheFolder()
    {
        using var parent = new TempFolder();
        var store = new PositionStore(parent["Positions"]);
        store.Save(Here, "../escape");
        store.Save(Here, @"..\escape");
        Assert.AreEqual(Here, store.Location("../escape"));
        CollectionAssert.AreEqual(new[] { "Positions" }, Directory.GetFileSystemEntries(parent.Path).Select(Path.GetFileName).ToArray());
        CollectionAssert.AreEquivalent(new[] { "%2E%2E%2Fescape.json", "%2E%2E%5Cescape.json" },
            Directory.GetFiles(parent["Positions"]).Select(Path.GetFileName).ToArray());
    }

    [TestMethod]
    public async Task ABookIdIsTheSameForTheSameFile()
    {
        using var folder = new TempFolder();
        var copy = folder["renamed.epub"];
        File.Copy(Fixtures.Of("long.epub"), copy);
        var id = await BookId.OfAsync(Fixtures.Of("long.epub"));
        Assert.AreEqual(id, await BookId.OfAsync(copy));
        Assert.AreNotEqual(id, await BookId.OfAsync(Fixtures.Of("no-toc.epub")));
        Assert.AreEqual(64, id.Length);
        Assert.IsTrue(BookId.IsValid(id));
    }

    [TestMethod]
    public void ImportMergeKeepsTheFurtherPlace()
    {
        Assert.IsTrue(ImportMerge.IsFurther(Here, null));
        Assert.IsTrue(ImportMerge.IsFurther(Here with { Fraction = 0.5 }, Here));
        Assert.IsFalse(ImportMerge.IsFurther(Here with { Fraction = 0.1 }, Here));
        Assert.IsFalse(ImportMerge.IsFurther(Here, Here));
    }
}

/// <summary>Ported from HighlightStoreTests.swift.</summary>
[TestClass]
public sealed class HighlightStoreTests
{
    static Highlight Mark(string cfi, double fraction, string text = "some words") =>
        Highlight.Create(cfi, text, fraction, "Chapter 1");

    [TestMethod]
    public void RoundTripInReadingOrder()
    {
        using var folder = new TempFolder();
        var store = new HighlightStore(folder.Path);
        Assert.AreEqual(0, store.Highlights("book").Count);
        var late = Mark("epubcfi(/6/8!/4,/1:0,/1:4)", 0.6);
        var early = Mark("epubcfi(/6/2!/4,/1:0,/1:4)", 0.1);
        store.Add(late, "book");
        store.Add(early, "book");
        CollectionAssert.AreEqual(new[] { early.Cfi, late.Cfi }, store.Highlights("book").Select(h => h.Cfi).ToArray());
        Assert.AreEqual(0, store.Highlights("other").Count);
    }

    [TestMethod]
    public void SurvivesRestart()
    {
        using var folder = new TempFolder();
        var one = Mark("epubcfi(/6/2!/4,/1:0,/1:4)", 0.1);
        new HighlightStore(folder.Path).Add(one, "book");
        var loaded = new HighlightStore(folder.Path).Highlights("book");
        Assert.AreEqual(one.Id, loaded.Single().Id);
        Assert.AreEqual("some words", loaded.Single().Text);
        // The file keeps whole seconds, as on Mac.
        Assert.AreEqual(Iso8601SecondsConverter.Truncate(one.Created), loaded.Single().Created);
    }

    [TestMethod]
    public void SamePassageIsKeptOnce()
    {
        using var folder = new TempFolder();
        var store = new HighlightStore(folder.Path);
        store.Add(Mark("epubcfi(/6/2!/4,/1:0,/1:4)", 0.1), "book");
        store.Add(Mark("epubcfi(/6/2!/4,/1:0,/1:4)", 0.1), "book");
        Assert.AreEqual(1, store.Highlights("book").Count);
    }

    [TestMethod]
    public void RemoveTakesOutOne()
    {
        using var folder = new TempFolder();
        var store = new HighlightStore(folder.Path);
        var one = Mark("epubcfi(/6/2!/4,/1:0,/1:4)", 0.1);
        var two = Mark("epubcfi(/6/4!/4,/1:0,/1:4)", 0.2);
        store.Add(one, "book");
        store.Add(two, "book");
        store.Remove(one.Id, "book");
        CollectionAssert.AreEqual(new[] { two.Id }, store.Highlights("book").Select(h => h.Id).ToArray());
    }

    [TestMethod]
    public void RemoveBookDeletesItsFile()
    {
        using var folder = new TempFolder();
        var store = new HighlightStore(folder.Path);
        store.Add(Mark("epubcfi(/6/2!/4,/1:0,/1:4)", 0.1), "book");
        store.Remove("book");
        Assert.AreEqual(0, Directory.GetFileSystemEntries(folder.Path).Length);
    }

    [TestMethod]
    public void CorruptFileIsIgnored()
    {
        using var folder = new TempFolder();
        var store = new HighlightStore(folder.Path);
        store.Add(Mark("epubcfi(/6/2!/4,/1:0,/1:4)", 0.1), "book");
        foreach (var file in Directory.GetFiles(folder.Path)) File.WriteAllText(file, "not json");
        Assert.AreEqual(0, store.Highlights("book").Count);
    }

    [TestMethod]
    public void MergeAddsOnlyNewOnes()
    {
        using var folder = new TempFolder();
        var store = new HighlightStore(folder.Path);
        var mine = Mark("epubcfi(/6/2!/4,/1:0,/1:4)", 0.1);
        store.Add(mine, "book");
        var sameId = mine with { Cfi = "epubcfi(/6/9!/4,/1:0,/1:4)" };
        var samePassage = Mark(mine.Cfi, 0.1, "other words");
        var fresh = Mark("epubcfi(/6/4!/4,/1:0,/1:4)", 0.2);
        Assert.AreEqual(1, store.Merge([sameId, samePassage, fresh], "book"));
        CollectionAssert.AreEqual(new[] { mine.Id, fresh.Id }, store.Highlights("book").Select(h => h.Id).ToArray());
        Assert.AreEqual(0, store.Merge([fresh], "book"));
    }
}

/// <summary>Ported from MarkerStoreTests.swift.</summary>
[TestClass]
public sealed class MarkerStoreTests
{
    static Marker Mark(string cfi, int page = 12) => Marker.Create(cfi, 0.2, page, "Chapter 2");

    [TestMethod]
    public void SetAndRead()
    {
        using var folder = new TempFolder();
        var store = new MarkerStore(folder.Path);
        Assert.IsNull(store.Marker("book"));
        var one = Mark("epubcfi(/6/8!/4/2/1:0)");
        store.Set(one, "book");
        Assert.AreEqual(one, store.Marker("book"));
        Assert.IsNull(store.Marker("other"));
    }

    [TestMethod]
    public void SurvivesRestart()
    {
        using var folder = new TempFolder();
        var one = Mark("epubcfi(/6/8!/4/2/1:0)");
        new MarkerStore(folder.Path).Set(one, "book");
        Assert.AreEqual(one, new MarkerStore(folder.Path).Marker("book"));
    }

    [TestMethod]
    public void SettingAgainReplaces()
    {
        using var folder = new TempFolder();
        var store = new MarkerStore(folder.Path);
        store.Set(Mark("epubcfi(/6/8!/4/2/1:0)", 12), "book");
        var moved = Mark("epubcfi(/6/10!/4/2/1:0)", 30);
        store.Set(moved, "book");
        Assert.AreEqual(moved, store.Marker("book"));
    }

    [TestMethod]
    public void SetIfNoneLeavesAnExistingMarker()
    {
        using var folder = new TempFolder();
        var store = new MarkerStore(folder.Path);
        var first = Mark("epubcfi(/6/8!/4/2/1:0)", 12);
        Assert.IsTrue(store.SetIfNone(first, "book"));
        Assert.IsFalse(store.SetIfNone(Mark("epubcfi(/6/10!/4/2/1:0)", 30), "book"));
        Assert.AreEqual(first, store.Marker("book"));
    }

    [TestMethod]
    public void RemoveDeletesIt()
    {
        using var folder = new TempFolder();
        var store = new MarkerStore(folder.Path);
        store.Set(Mark("epubcfi(/6/8!/4/2/1:0)"), "book");
        store.Remove("book");
        Assert.IsNull(store.Marker("book"));
        Assert.AreEqual(0, Directory.GetFileSystemEntries(folder.Path).Length);
    }

    [TestMethod]
    public void CorruptFileIsIgnored()
    {
        using var folder = new TempFolder();
        var store = new MarkerStore(folder.Path);
        store.Set(Mark("epubcfi(/6/8!/4/2/1:0)"), "book");
        foreach (var file in Directory.GetFiles(folder.Path)) File.WriteAllText(file, "not json");
        Assert.IsNull(store.Marker("book"));
    }

    [TestMethod]
    public void OddIdsGetFilesOfTheirOwn()
    {
        using var folder = new TempFolder();
        var store = new MarkerStore(folder.Path);
        var a = Mark("epubcfi(/6/2!/4/2/1:0)");
        var b = Mark("epubcfi(/6/4!/4/2/1:0)");
        store.Set(a, "a/b");
        store.Set(b, "a_b");
        Assert.AreEqual(a, store.Marker("a/b"));
        Assert.AreEqual(b, store.Marker("a_b"));
        Assert.IsNull(store.Marker("../a"));
    }

    [TestMethod]
    public void CreatedIsKeptInWholeSeconds()
    {
        var marker = Marker.Create("x", 0, 1, created: At(1000.75));
        Assert.AreEqual(At(1000), marker.Created);
    }
}
