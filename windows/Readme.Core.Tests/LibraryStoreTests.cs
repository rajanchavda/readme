using Readme.Core.Storage;
using static Readme.Core.Tests.Samples;

namespace Readme.Core.Tests;

/// <summary>Ported from LibraryStoreTests.swift.</summary>
[TestClass]
public sealed class LibraryStoreTests
{
    [TestMethod]
    public void CurrentIsMostRecentlyRead()
    {
        using var folder = new TempFolder();
        var store = new LibraryStore(folder.Path);
        store.Add(Book("a", 1, 50));
        store.Add(Book("b", 2, 70));
        store.Add(Book("c", 3));
        Assert.AreEqual("b", store.Current?.Id);
    }

    [TestMethod]
    public void OthersSortedByRecency()
    {
        using var folder = new TempFolder();
        var store = new LibraryStore(folder.Path);
        store.Add(Book("read-early", 1, 10));
        store.Add(Book("read-late", 2, 90));
        store.Add(Book("new", 60));
        store.Add(Book("old", 5));
        store.Add(Book("current", 3, 100));
        Assert.AreEqual("current", store.Current?.Id);
        // A book never read counts from when it was added.
        CollectionAssert.AreEqual(new[] { "read-late", "new", "read-early", "old" }, Ids(store.Others));
    }

    [TestMethod]
    public void NoReadBooksMeansNewestIsCurrent()
    {
        using var folder = new TempFolder();
        var store = new LibraryStore(folder.Path);
        Assert.IsNull(store.Current);
        store.Add(Book("a", 1));
        store.Add(Book("c", 3));
        store.Add(Book("b", 2));
        Assert.AreEqual("c", store.Current?.Id);
        CollectionAssert.AreEqual(new[] { "b", "a" }, Ids(store.Others));
    }

    [TestMethod]
    public void MarkReadRecordsWhereTheReaderIs()
    {
        using var folder = new TempFolder();
        var moment = At(500);
        var store = new LibraryStore(folder.Path, now: () => moment);
        store.Add(Book("a", 1));
        store.MarkRead("a", Place);
        var book = store.Books[0];
        Assert.AreEqual(moment, book.LastReadAt);
        Assert.AreEqual("Chapter 7", book.ChapterTitle);
        Assert.AreEqual(6.5, book.ChapterMinutesLeft);
    }

    [TestMethod]
    public void SurvivesRestart()
    {
        using var folder = new TempFolder();
        var store = new LibraryStore(folder.Path);
        store.Add(Book("a", 1));
        store.MarkRead("a", Place);
        CollectionAssert.AreEqual(store.Books.ToList(), new LibraryStore(folder.Path).Books.ToList());
    }

    [TestMethod]
    public void RemoveDeletesCopyCoverPlaceHighlightsAndMarker()
    {
        using var folder = new TempFolder();
        var store = new LibraryStore(folder.Path);
        var gone = Book("gone", 1);
        var kept = Book("kept", 2);
        foreach (var each in new[] { gone, kept })
        {
            store.Add(each);
            Directory.CreateDirectory(store.BooksDirectory);
            Directory.CreateDirectory(store.CoversDirectory);
            File.WriteAllText(store.FilePath(each), "book");
            File.WriteAllText(store.CoverPath(each), "cover");
            store.Positions.Save(Place, each.Id);
            store.Highlights.Add(Model.Highlight.Create("epubcfi(/6/2!/4,/1:0,/1:4)", "words", 0.1), each.Id);
            store.Markers.Set(Model.Marker.Create("epubcfi(/6/8!/4/2/1:0)", 0.2, 12), each.Id);
        }
        string? heard = null;
        store.Removing += id => heard = id;
        store.Remove("gone");
        Assert.AreEqual("gone", heard);
        CollectionAssert.AreEqual(new[] { "kept" }, Ids(store.Books));
        Assert.IsFalse(File.Exists(store.FilePath(gone)));
        Assert.IsFalse(File.Exists(store.CoverPath(gone)));
        Assert.IsNull(store.Positions.Location("gone"));
        Assert.AreEqual(0, store.Highlights.Highlights("gone").Count);
        Assert.IsNull(store.Markers.Marker("gone"));
        Assert.IsTrue(File.Exists(store.FilePath(kept)));
        Assert.AreEqual(Place, store.Positions.Location("kept"));
        CollectionAssert.AreEqual(new[] { "kept" }, Ids(new LibraryStore(folder.Path).Books));
    }

    [TestMethod]
    public void RemoveMissingTakesOutBooksWhoseCopyHasGone()
    {
        using var folder = new TempFolder();
        var store = new LibraryStore(folder.Path);
        store.Add(Book("here", 1));
        store.Add(Book("lost", 2));
        Directory.CreateDirectory(store.BooksDirectory);
        File.WriteAllText(store.FilePath(store.Book("here")!), "book");
        var missing = store.RemoveMissing(File.Exists);
        CollectionAssert.AreEqual(new[] { "lost" }, Ids(missing));
        CollectionAssert.AreEqual(new[] { "here" }, Ids(store.Books));
    }

    [TestMethod]
    public void CorruptLibraryFileStartsEmpty()
    {
        using var folder = new TempFolder();
        File.WriteAllText(folder["library.json"], "{ not json");
        var store = new LibraryStore(folder.Path);
        Assert.AreEqual(0, store.Books.Count);
        store.Add(Book("a", 1));
        CollectionAssert.AreEqual(new[] { "a" }, Ids(new LibraryStore(folder.Path).Books));
    }

    [TestMethod]
    public void ABookMissingARequiredFieldMakesTheFileUnreadable()
    {
        // As on Mac, where Codable fails the whole array.
        using var folder = new TempFolder();
        File.WriteAllText(folder["library.json"], """[{"id":"a","title":"A","fileName":"a.epub","addedAt":10}]""");
        Assert.AreEqual(0, new LibraryStore(folder.Path).Books.Count);
    }

    [TestMethod]
    public void AddingTheSameBookTwiceKeepsOne()
    {
        using var folder = new TempFolder();
        var store = new LibraryStore(folder.Path);
        store.Add(Book("a", 1, title: "First"));
        store.Add(Book("a", 2, title: "Second"));
        Assert.AreEqual(1, store.Books.Count);
        Assert.AreEqual("First", store.Books[0].Title);
    }

    [TestMethod]
    public void ApplyImportedKeepsTheLaterReadDate()
    {
        using var folder = new TempFolder();
        var store = new LibraryStore(folder.Path);
        store.Add(Book("a", 1, 100));
        store.ApplyImported("a", At(5), At(50), null);
        Assert.AreEqual(At(100), store.Book("a")!.LastReadAt);
        Assert.AreEqual(At(5), store.Book("a")!.AddedAt);
        store.ApplyImported("a", null, At(200), Place);
        Assert.AreEqual(At(200), store.Book("a")!.LastReadAt);
        Assert.AreEqual("Chapter 7", store.Book("a")!.ChapterTitle);
    }

    // Pins

    sealed class Clock
    {
        public double Time = 1000;
    }

    static LibraryStore PinStore(TempFolder folder, Clock clock)
    {
        var store = new LibraryStore(folder.Path, now: () => At(clock.Time));
        store.Add(Book("current", 1, 500));
        store.Add(Book("a", 2, 100));
        store.Add(Book("b", 3, 200));
        store.Add(Book("c", 4, 300));
        store.Add(Book("d", 5, 400));
        return store;
    }

    [TestMethod]
    public void PinnedComeFirstNewestPinFirst()
    {
        using var folder = new TempFolder();
        var clock = new Clock();
        var store = PinStore(folder, clock);
        CollectionAssert.AreEqual(new[] { "d", "c", "b", "a" }, Ids(store.Others));
        store.SetPinned(["a"], true);
        clock.Time = 1001;
        store.SetPinned(["b"], true);
        CollectionAssert.AreEqual(new[] { "b", "a", "d", "c" }, Ids(store.Others));
        Assert.AreEqual(At(1001), store.Book("b")!.PinnedAt);
        // Reading a pinned book doesn't reorder the pins.
        clock.Time = 1002;
        store.MarkRead("a", Place);
        clock.Time = 1003;
        store.MarkRead("current", Place);
        CollectionAssert.AreEqual(new[] { "b", "a", "d", "c" }, Ids(store.Others));
    }

    [TestMethod]
    public void UnpinnedGoBackByRecency()
    {
        using var folder = new TempFolder();
        var store = PinStore(folder, new Clock());
        store.SetPinned(["a", "b"], true);
        store.SetPinned(["a", "b"], false);
        CollectionAssert.AreEqual(new[] { "d", "c", "b", "a" }, Ids(store.Others));
        Assert.IsTrue(store.Books.All(b => b.PinnedAt == null));
    }

    [TestMethod]
    public void PinningAgainKeepsTheDate()
    {
        using var folder = new TempFolder();
        var clock = new Clock();
        var store = PinStore(folder, clock);
        store.SetPinned(["a"], true);
        clock.Time = 1001;
        store.SetPinned(["b"], true);
        clock.Time = 1002;
        // A mixed selection: "a" is pinned already and keeps its place behind "b".
        store.SetPinned(["a", "c"], true);
        Assert.AreEqual(At(1000), store.Book("a")!.PinnedAt);
        CollectionAssert.AreEqual(new[] { "c", "b", "a", "d" }, Ids(store.Others));
    }

    [TestMethod]
    public void CurrentBookPinnedIsOnlyOnTheLedge()
    {
        using var folder = new TempFolder();
        var store = PinStore(folder, new Clock());
        store.SetPinned(["current", "a"], true);
        Assert.AreEqual("current", store.Current?.Id);
        CollectionAssert.AreEqual(new[] { "a", "d", "c", "b" }, Ids(store.Others));
    }

    [TestMethod]
    public void PinningAMissingBookDoesNothing()
    {
        using var folder = new TempFolder();
        var store = PinStore(folder, new Clock());
        var before = store.Books.ToList();
        store.SetPinned(["gone"], true);
        store.RestorePin("gone", At(1));
        CollectionAssert.AreEqual(before, store.Books.ToList());
    }

    [TestMethod]
    public void RestorePinKeepsTheGivenDate()
    {
        using var folder = new TempFolder();
        var store = PinStore(folder, new Clock());
        store.SetPinned(["a"], true);
        store.RestorePin("b", At(1));
        Assert.AreEqual(At(1), store.Book("b")!.PinnedAt);
        CollectionAssert.AreEqual(new[] { "a", "b", "d", "c" }, Ids(store.Others));
    }

    [TestMethod]
    public void PinsSurviveRestart()
    {
        using var folder = new TempFolder();
        var store = PinStore(folder, new Clock());
        store.SetPinned(["a"], true);
        var reopened = new LibraryStore(folder.Path);
        Assert.AreEqual(At(1000), reopened.Book("a")!.PinnedAt);
        CollectionAssert.AreEqual(new[] { "a", "d", "c", "b" }, Ids(reopened.Others));
    }

    [TestMethod]
    public void OldLibraryFileLoadsUnpinned()
    {
        using var folder = new TempFolder();
        // As written before books could be pinned.
        File.WriteAllText(folder["library.json"], """[{"id":"a","title":"A","fileName":"a.epub","hasCover":false,"addedAt":10}]""");
        var store = new LibraryStore(folder.Path);
        CollectionAssert.AreEqual(new[] { "a" }, Ids(store.Books));
        Assert.IsNull(store.Book("a")!.PinnedAt);
    }

    [TestMethod]
    public void NoTemporaryFilesAreLeftBehind()
    {
        using var folder = new TempFolder();
        var store = new LibraryStore(folder.Path);
        for (var i = 0; i < 20; i++) store.Add(Book("b" + i, i));
        CollectionAssert.AreEqual(new[] { "library.json" }, Directory.GetFiles(folder.Path).Select(Path.GetFileName).ToArray());
    }

    static string[] Ids(IEnumerable<Model.Book> books) => books.Select(b => b.Id).ToArray();
}
