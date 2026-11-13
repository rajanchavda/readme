using Readme.Core.Library;
using Readme.Core.Model;
using Readme.Core.Reader;
using Readme.Core.Storage;
using Readme.Core.Zip;
using static Readme.Core.Tests.Samples;

namespace Readme.Core.Tests;

/// <summary>Ported from ShelfSelectionTests.swift.</summary>
[TestClass]
public sealed class ShelfSelectionTests
{
    static readonly string[] Order = ["a", "b", "c", "d"];

    static string[] Sorted(ShelfSelection s) => s.Ids.OrderBy(x => x).ToArray();

    [TestMethod]
    public void PlainClickOpensAndClears()
    {
        var selection = new ShelfSelection();
        selection.Click("a", Modifiers.Ctrl, Order);
        Assert.AreEqual(ShelfSelection.Outcome.Open, selection.Click("b", Modifiers.None, Order));
        Assert.AreEqual(0, selection.Ids.Count);
    }

    [TestMethod]
    public void CtrlClickToggles()
    {
        var selection = new ShelfSelection();
        Assert.AreEqual(ShelfSelection.Outcome.Changed, selection.Click("a", Modifiers.Ctrl, Order));
        selection.Click("c", Modifiers.Ctrl, Order);
        CollectionAssert.AreEqual(new[] { "a", "c" }, Sorted(selection));
        selection.Click("a", Modifiers.Ctrl, Order);
        CollectionAssert.AreEqual(new[] { "c" }, Sorted(selection));
    }

    [TestMethod]
    public void ShiftClickSelectsTheRun()
    {
        var selection = new ShelfSelection();
        selection.Click("b", Modifiers.Ctrl, Order);
        Assert.AreEqual(ShelfSelection.Outcome.Changed, selection.Click("d", Modifiers.Shift, Order));
        CollectionAssert.AreEqual(new[] { "b", "c", "d" }, Sorted(selection));
        selection.Click("a", Modifiers.Shift, Order);
        CollectionAssert.AreEqual(new[] { "a", "b" }, Sorted(selection));
    }

    [TestMethod]
    public void ShiftClickWithoutAnchorSelectsOne()
    {
        var selection = new ShelfSelection();
        selection.Click("c", Modifiers.Shift, Order);
        CollectionAssert.AreEqual(new[] { "c" }, Sorted(selection));
    }

    [TestMethod]
    public void TargetsFollowTheSelection()
    {
        var selection = new ShelfSelection();
        selection.Click("c", Modifiers.Ctrl, Order);
        selection.Click("a", Modifiers.Ctrl, Order);
        CollectionAssert.AreEqual(new[] { "a", "c" }, selection.Targets("a", Order).ToArray());
        CollectionAssert.AreEqual(new[] { "b" }, selection.Targets("b", Order).ToArray());
        Assert.AreEqual("Export 2 Books…", selection.ExportTitle("a"));
        Assert.AreEqual("Export…", selection.ExportTitle("b"));
    }

    [TestMethod]
    public void PinMenuTitles()
    {
        Assert.AreEqual("Pin to Front", ShelfSelection.PinMenuTitle(1, false));
        Assert.AreEqual("Pin 3 Books to Front", ShelfSelection.PinMenuTitle(3, false));
        Assert.AreEqual("Unpin", ShelfSelection.PinMenuTitle(1, true));
        Assert.AreEqual("Unpin 3 Books", ShelfSelection.PinMenuTitle(3, true));
    }

    [TestMethod]
    public void ClearEmptiesItAndForgetsTheAnchor()
    {
        var selection = new ShelfSelection();
        selection.Click("c", Modifiers.Ctrl, Order);
        selection.Clear();
        Assert.AreEqual(0, selection.Ids.Count);
        selection.Click("a", Modifiers.Shift, Order);
        CollectionAssert.AreEqual(new[] { "a" }, Sorted(selection));
    }
}

/// <summary>Ported from ShelfLayoutTests.swift (the words) and ShelfDrops.</summary>
[TestClass]
public sealed class ShelfTextTests
{
    static Book Reading(string? chapter, double? minutes) => Book("a", 0) with { ChapterTitle = chapter, ChapterMinutesLeft = minutes };

    [TestMethod]
    public void ProgressLine()
    {
        Assert.AreEqual("Chapter 1, Loomings · 23 min left", ShelfText.ProgressLine(Reading("Chapter 1, Loomings", 23)));
        Assert.AreEqual("Loomings", ShelfText.ProgressLine(Reading("Loomings", null)));
        Assert.AreEqual("5 min left", ShelfText.ProgressLine(Reading(null, 4.2)));
        Assert.IsNull(ShelfText.ProgressLine(Reading(null, null)));
        Assert.IsNull(ShelfText.ProgressLine(Reading("", null)));
    }

    [TestMethod]
    public void TimeLeft()
    {
        Assert.AreEqual("1 min left", ShelfText.TimeLeft(0));
        Assert.AreEqual("1 hr 5 min left", ShelfText.TimeLeft(65));
        Assert.AreEqual("2 hr left", ShelfText.TimeLeft(120));
    }

    [TestMethod]
    public void ImportMessages()
    {
        CollectionAssert.AreEqual(
            new[] { "This file isn't an EPUB book.", "This book is copy-protected, so it can't be opened here." },
            ShelfText.Messages([ImportError.NotAnEpub, ImportError.CopyProtected, ImportError.NotAnEpub]).ToArray());
        Assert.AreEqual("This book couldn't be read.", ShelfText.Message(ImportError.Unreadable));
        Assert.AreEqual("Adding a book…", ShelfText.Adding(1));
        Assert.AreEqual("Adding 3 books…", ShelfText.Adding(3));
        Assert.AreEqual("No books match “dune”", ShelfText.NoMatch("  dune "));
    }

    [TestMethod]
    public void NarratorLabelSaysPinned()
    {
        var book = Book("a", 0, title: "Emma", author: "Jane Austen");
        Assert.AreEqual("Emma, Jane Austen", ShelfText.Label(book));
        Assert.AreEqual("Emma, Jane Austen, pinned", ShelfText.Label(book with { PinnedAt = At(1) }));
        Assert.AreEqual("Emma", ShelfText.Label(book with { Author = null }));
    }
}

/// <summary>Ported from GeneratedCoverTests.swift and CoverLayoutTests, with a fixed-width stand-in font.</summary>
[TestClass]
public sealed class GeneratedCoverTests
{
    const double Width = 150;
    /// <summary>Every character 0.55 em wide: enough to test the layout without the real fonts.</summary>
    static readonly GeneratedCover.Measure Mono = (text, size) => new System.Globalization.StringInfo(text).LengthInTextElements * size * 0.55;

    static GeneratedCover.Layout Lay(string title, string? author) => GeneratedCover.LayoutFor(title, author, Width, Mono, Mono);

    static double Luminance(Rgba c)
    {
        static double Channel(byte v)
        {
            var x = v / 255.0;
            return x <= 0.03928 ? x / 12.92 : Math.Pow((x + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * Channel(c.R) + 0.7152 * Channel(c.G) + 0.0722 * Channel(c.B);
    }

    [TestMethod]
    public void StableAndTheSameAsTheMac()
    {
        // The Mac's test pins this id to palette 7, so a book's cover is the same colour on both.
        const string id = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";
        Assert.AreEqual(GeneratedCover.Palettes[7], GeneratedCover.PaletteFor(id));
    }

    [TestMethod]
    public void TwelveDistinctReadablePalettesSpreadAcrossBooks()
    {
        Assert.AreEqual(12, GeneratedCover.Palettes.Distinct().Count());
        foreach (var p in GeneratedCover.Palettes)
        {
            var (x, y) = (Luminance(p.Ink), Luminance(p.Background));
            Assert.IsTrue((Math.Max(x, y) + 0.05) / (Math.Min(x, y) + 0.05) >= 4.5);
        }
        var used = Enumerable.Range(0, 20).Select(i => GeneratedCover.PaletteFor($"book-{i}")).Distinct().Count();
        Assert.IsTrue(used >= 5);
    }

    static void Check(string title, string? author)
    {
        var layout = Lay(title, author);
        var inner = Width * 0.82;
        foreach (var lines in new[] { layout.Title, layout.Author }.OfType<GeneratedCover.Lines>())
            foreach (var line in lines.Text) Assert.IsTrue(Mono(line, lines.Size) <= inner + 0.5, $"{line} too wide");
        var used = layout.Title.Text.Count * layout.Title.Size * GeneratedCover.LineHeight
            + (layout.Author is { } a ? a.Text.Count * a.Size * GeneratedCover.LineHeight : 0);
        Assert.IsTrue(used <= Width * 1.5 - Width * 0.18);
    }

    [TestMethod]
    public void ShortTitleKeepsFullSize()
    {
        var layout = Lay("Walden", "Henry David Thoreau");
        Assert.AreEqual(Width * 0.135, layout.Title.Size);
        CollectionAssert.AreEqual(new[] { "Walden" }, layout.Title.Text.ToArray());
    }

    [TestMethod]
    public void LongTitleShrinksAndWrapsOnWords()
    {
        const string title = "The Extraordinary and Surprising Adventures of a Rather Long-Winded Gentleman";
        Check(title, "A Very Prolific and Widely Travelled Author of Many Books");
        var layout = Lay(title, null);
        Assert.IsTrue(layout.Title.Size < Width * 0.135);
        Assert.AreEqual(title, string.Join(" ", layout.Title.Text));
    }

    [TestMethod]
    public void LongSingleWordIsNeverCut()
    {
        Check("Internationalization", "Someone");
        CollectionAssert.AreEqual(new[] { "Internationalization" }, Lay("Internationalization", null).Title.Text.ToArray());
    }

    [TestMethod]
    public void AbsurdWordIsBrokenNotClipped()
    {
        var word = string.Concat(Enumerable.Repeat("Supercali", 20));
        Check(word, "Someone");
        StringAssert.StartsWith(string.Concat(Lay(word, null).Title.Text), "Supercali");
    }

    [TestMethod]
    public void AbsurdlyLongTitleEndsInEllipsis()
    {
        var title = string.Join(" ", Enumerable.Repeat("words", 300));
        Check(title, "Someone");
        StringAssert.EndsWith(Lay(title, null).Title.Text[^1], "…");
    }

    [TestMethod]
    public void EmptyTitlesAndCjk()
    {
        Check("", "Only An Author");
        Check("   ", null);
        Assert.AreEqual("Untitled", Lay("  ", null).Title.Text[0]);
        Check("吾輩は猫である吾輩は猫である吾輩は猫である", "夏目漱石");
        Assert.IsTrue(Lay("吾輩は猫である吾輩は猫である吾輩は猫である", null).Title.Text.Count > 1);
    }
}

/// <summary>Ported from BookImporterTests.swift, with a stand-in for the hidden view.</summary>
[TestClass]
public sealed class BookImporterTests
{
    static readonly byte[] Png = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3];

    static (LibraryStore Store, BookImporter Importer, List<string> Opened) Make(TempFolder folder,
        Func<string, Task<BookDetails>>? details = null)
    {
        var store = new LibraryStore(folder.Path);
        var opened = new List<string>();
        var importer = new BookImporter(store, details ?? (path =>
        {
            lock (opened) opened.Add(path);
            return Task.FromResult(new BookDetails("Long Fixture Book", "Fixture Author", Png));
        }));
        return (store, importer, opened);
    }

    [TestMethod]
    public async Task ImportsAndCopies()
    {
        using var folder = new TempFolder();
        var (store, importer, _) = Make(folder);
        var original = Fixtures.Of("long.epub");
        var before = File.ReadAllBytes(original);
        var book = await importer.ImportAsync(original);
        CollectionAssert.AreEqual(new[] { book }, store.Books.ToArray());
        Assert.AreEqual(await BookId.OfAsync(original), book.Id);
        CollectionAssert.AreEqual(before, File.ReadAllBytes(store.FilePath(book)));
        StringAssert.StartsWith(store.FilePath(book), folder.Path);
        CollectionAssert.AreEqual(before, File.ReadAllBytes(original));
        Assert.AreEqual("Long Fixture Book", book.Title);
        Assert.AreEqual("Fixture Author", book.Author);
        Assert.IsTrue(book.HasCover);
        CollectionAssert.AreEqual(Png, File.ReadAllBytes(store.CoverPath(book)));
        // Nothing staged is left behind.
        CollectionAssert.AreEqual(new[] { book.FileName }, Directory.GetFiles(store.BooksDirectory).Select(Path.GetFileName).ToArray());
    }

    [TestMethod]
    public async Task SameBookTwiceIsOneBookAndNotOpenedTwice()
    {
        using var folder = new TempFolder();
        var (store, importer, opened) = Make(folder);
        var first = await importer.ImportAsync(Fixtures.Of("long.epub"));
        var copy = folder["renamed.epub"];
        File.Copy(Fixtures.Of("long.epub"), copy);
        Assert.AreEqual(first, await importer.ImportAsync(copy));
        Assert.AreEqual(1, store.Books.Count);
        Assert.AreEqual(1, opened.Count);
    }

    [TestMethod]
    public async Task ImportsOfTheSameBookAtOnceShareOneResult()
    {
        using var folder = new TempFolder();
        var gate = new TaskCompletionSource();
        var opens = 0;
        var (store, importer, _) = Make(folder, async _ =>
        {
            Interlocked.Increment(ref opens);
            await gate.Task;
            return new BookDetails("T", null, null);
        });
        var a = importer.ImportAsync(Fixtures.Of("long.epub"));
        var b = importer.ImportAsync(Fixtures.Of("long.epub"));
        await Task.Delay(300);
        gate.SetResult();
        var books = await Task.WhenAll(a, b);
        Assert.AreEqual(books[0], books[1]);
        Assert.AreEqual(1, opens);
        Assert.AreEqual(1, store.Books.Count);
    }

    [TestMethod]
    public async Task ALeftoverCopyDoesNotBlockImport()
    {
        using var folder = new TempFolder();
        var (store, importer, _) = Make(folder);
        var id = await BookId.OfAsync(Fixtures.Of("long.epub"));
        Directory.CreateDirectory(store.BooksDirectory);
        File.WriteAllText(Path.Combine(store.BooksDirectory, id + ".epub"), "half a book");
        var book = await importer.ImportAsync(Fixtures.Of("long.epub"));
        CollectionAssert.AreEqual(File.ReadAllBytes(Fixtures.Of("long.epub")), File.ReadAllBytes(store.FilePath(book)));
    }

    [TestMethod]
    [DataRow("drm.epub", ImportError.CopyProtected)]
    [DataRow("drm-lcp.epub", ImportError.CopyProtected)]
    [DataRow("not-an-epub.epub", ImportError.NotAnEpub)]
    [DataRow("plain-zip.epub", ImportError.NotAnEpub)]
    [DataRow("no-such-file.epub", ImportError.Unreadable)]
    public async Task RefusedBeforeAnythingIsCopied(string name, ImportError expected)
    {
        using var folder = new TempFolder();
        var (store, importer, opened) = Make(folder);
        var error = await Assert.ThrowsExactlyAsync<ImportException>(() => importer.ImportAsync(Fixtures.Of(name)));
        Assert.AreEqual(expected, error.Error);
        Assert.AreEqual(0, store.Books.Count);
        Assert.AreEqual(0, opened.Count);
        Assert.IsFalse(Directory.Exists(store.BooksDirectory) && Directory.GetFiles(store.BooksDirectory).Length > 0);
    }

    [TestMethod]
    public async Task ABookThatWontOpenIsUnreadableAndLeavesNothing()
    {
        using var folder = new TempFolder();
        var (store, importer, _) = Make(folder, _ => throw new InvalidOperationException("won't open"));
        var error = await Assert.ThrowsExactlyAsync<ImportException>(() => importer.ImportAsync(Fixtures.Of("long.epub")));
        Assert.AreEqual(ImportError.Unreadable, error.Error);
        Assert.AreEqual(0, store.Books.Count);
        Assert.AreEqual(0, Directory.GetFiles(store.BooksDirectory).Length);
    }

    [TestMethod]
    public async Task NoTitleFallsBackToTheFileNameAndNoCoverIsFine()
    {
        using var folder = new TempFolder();
        var (store, importer, _) = Make(folder, _ => Task.FromResult(new BookDetails(" ", null, null)));
        var book = await importer.ImportAsync(Fixtures.Of("no-cover.epub"));
        Assert.AreEqual("no-cover", book.Title);
        Assert.IsFalse(book.HasCover);
        Assert.IsFalse(File.Exists(store.CoverPath(book)));
    }

    [TestMethod]
    public async Task ADropOfManyKeepsGoing()
    {
        using var folder = new TempFolder();
        var (store, importer, _) = Make(folder);
        var results = await importer.ImportAllAsync([Fixtures.Of("long.epub"), Fixtures.Of("drm.epub"), Fixtures.Of("search.epub")]);
        CollectionAssert.AreEqual(new ImportError?[] { null, ImportError.CopyProtected, null }, results.Select(r => r.Error).ToArray());
        Assert.AreEqual(2, store.Books.Count);
    }
}

[TestClass]
public sealed class LastSpreadCacheTests
{
    [TestMethod]
    public void GivenBackOnlyForTheSameLook()
    {
        using var folder = new TempFolder();
        var cache = new LastSpreadCache(folder.Path);
        var look = LastSpreadCache.Signature(980, 552, 1.25, 2, 341.6, "css");
        cache.Save([1, 2, 3], look, "book");
        CollectionAssert.AreEqual(new byte[] { 1, 2, 3 }, cache.Image("book", look));
        Assert.IsNull(cache.Image("book", LastSpreadCache.Signature(980, 552, 1.25, 2, 341.6, "other css")));
        Assert.IsNull(cache.Image("book", LastSpreadCache.Signature(981, 552, 1.25, 2, 341.6, "css")));
        Assert.IsNull(cache.Image("other", look));
        cache.Remove("book");
        Assert.IsNull(cache.Image("book", look));
    }

    [TestMethod]
    public void RemovingABookFromTheLibraryCanDropItsSpread()
    {
        using var folder = new TempFolder();
        var store = new LibraryStore(folder.Path);
        var cache = new LastSpreadCache(folder["LastSpreads"]);
        store.Removing += cache.Remove;
        store.Add(Book("a", 1));
        var look = LastSpreadCache.Signature(1, 1, 1, 1, null, "");
        cache.Save([9], look, "a");
        store.Remove("a");
        Assert.IsNull(cache.Image("a", look));
    }
}
