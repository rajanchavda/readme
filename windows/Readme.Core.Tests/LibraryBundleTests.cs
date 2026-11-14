using System.Text;
using Readme.Core.Library;
using Readme.Core.Model;
using Readme.Core.Storage;
using Readme.Core.Zip;

namespace Readme.Core.Tests;

static class Bundles
{
    /// <summary>A place <paramref name="fraction"/> of the way through a book (bundlePlace in the Swift tests).</summary>
    public static ReaderLocation Place(double fraction, string? chapter = "Chapter 1") => new()
    {
        Cfi = "epubcfi(/6/4!/4/2/1:0)",
        Fraction = fraction,
        ChapterTitle = chapter,
        ChapterMinutesLeft = 3,
        IsAtStart = false,
        IsAtEnd = false,
        Page = 12,
        PageCount = 40,
    };

    static readonly byte[] Png = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3];

    /// <summary>An importer with a stand-in for the hidden view, as in BookImporterTests.</summary>
    public static BookImporter Importer(LibraryStore store) =>
        new(store, _ => Task.FromResult(new BookDetails("Long Fixture Book", "Fixture Author", Png)));

    public static Highlight Highlight(string cfi, string text, double fraction, double created, string? chapter = null) => new()
    {
        Id = Guid.NewGuid(),
        Cfi = cfi,
        Text = text,
        ChapterTitle = chapter,
        Fraction = fraction,
        Created = Samples.At(created),
    };
}

/// <summary>Ported from LibraryBundleTests.swift, with the streamed zip entries it now relies on.</summary>
[TestClass]
public sealed class LibraryBundleTests
{
    static BundleItem Item(string id, string epub, IReadOnlyList<Highlight>? highlights = null, Marker? marker = null,
        ReaderLocation? position = null) => new(
        id,
        new BundledBook { Title = "Long", Author = "Someone", AddedAt = Samples.At(1000), LastReadAt = Samples.At(2000) },
        epub, highlights ?? [], marker, position);

    /// <summary>A zip with just this manifest in it, and any other entries given.</summary>
    static void WriteManifest(string path, string json, Dictionary<string, byte[]>? extra = null)
    {
        using var writer = new ZipWriter(path);
        writer.Add("manifest.json", Encoding.UTF8.GetBytes(json));
        foreach (var (name, data) in extra ?? []) writer.Add(name, data);
        writer.Finish();
    }

    static BundleError ErrorOf(Action action)
    {
        try { action(); }
        catch (BundleException error) { return error.Error; }
        Assert.Fail("No BundleException");
        return default;
    }

    [TestMethod]
    public async Task RoundTripsEveryPart()
    {
        using var folder = new TempFolder();
        var epub = Fixtures.Of("long.epub");
        var id = await BookId.OfAsync(epub);
        Highlight[] two =
        [
            Bundles.Highlight("epubcfi(/6/2!/4,/1:0,/1:4)", "one", 0.1, 10, "1"),
            Bundles.Highlight("epubcfi(/6/4!/4,/1:0,/1:4)", "two", 0.3, 20),
        ];
        var marker = Marker.Create("epubcfi(/6/6!/4/2/1:0)", 0.4, 9, "2", Samples.At(30));
        var place = Bundles.Place(0.5);
        var item = Item(id, epub, two, marker, place);
        var path = folder["out.readmelibrary"];
        LibraryBundle.Write([item], path, Samples.At(5000));

        var opened = LibraryBundle.Open(path);
        Assert.AreEqual(new BundleManifest { FormatVersion = 1, ExportedAt = Samples.At(5000), BookIds = [id] }, opened.Manifest);
        Assert.AreEqual(new BundleContents(item.Info, two, marker, place), opened.Contents(id));
        var output = folder["book.epub"];
        opened.ExtractEpub(id, output);
        CollectionAssert.AreEqual(File.ReadAllBytes(epub), File.ReadAllBytes(output));
    }

    [TestMethod]
    public async Task NoMarkerOrPositionReadsAsNull()
    {
        using var folder = new TempFolder();
        var epub = Fixtures.Of("long.epub");
        var id = await BookId.OfAsync(epub);
        LibraryBundle.Write([Item(id, epub)], folder["out.readmelibrary"], Samples.At(1));
        var contents = LibraryBundle.Open(folder["out.readmelibrary"]).Contents(id);
        Assert.IsNull(contents.Marker);
        Assert.IsNull(contents.Position);
        Assert.AreEqual(0, contents.Highlights.Count);
    }

    [TestMethod]
    public void RefusesANewerVersion()
    {
        using var folder = new TempFolder();
        WriteManifest(folder["out.readmelibrary"], """{"formatVersion":2,"exportedAt":"2026-01-01T00:00:00Z","bookIDs":[]}""");
        Assert.AreEqual(BundleError.NewerVersion, ErrorOf(() => LibraryBundle.Open(folder["out.readmelibrary"])));
    }

    [TestMethod]
    public void AnEpubIsNotABundle() =>
        Assert.AreEqual(BundleError.NotABundle, ErrorOf(() => LibraryBundle.Open(Fixtures.Of("long.epub"))));

    [TestMethod]
    public void RejectsIdsThatArentHashes()
    {
        using var folder = new TempFolder();
        WriteManifest(folder["out.readmelibrary"], """{"formatVersion":1,"exportedAt":"2026-01-01T00:00:00Z","bookIDs":["../../x"]}""",
            new() { ["books/../../x/book.json"] = "{}"u8.ToArray(), ["books/../../x/book.epub"] = [] });
        Assert.AreEqual(BundleError.NotABundle, ErrorOf(() => LibraryBundle.Open(folder["out.readmelibrary"])));
    }

    [TestMethod]
    public void AListedBookWithoutItsFileIsNotABundle()
    {
        using var folder = new TempFolder();
        var id = new string('a', 64);
        WriteManifest(folder["out.readmelibrary"], $$"""{"formatVersion":1,"exportedAt":"2026-01-01T00:00:00Z","bookIDs":["{{id}}"]}""",
            new() { [$"books/{id}/book.json"] = """{"title":"T","addedAt":"2026-01-01T00:00:00Z"}"""u8.ToArray() });
        Assert.AreEqual(BundleError.NotABundle, ErrorOf(() => LibraryBundle.Open(folder["out.readmelibrary"])));
    }

    [TestMethod]
    public void AManifestMissingAKeyIsNotABundle()
    {
        using var folder = new TempFolder();
        WriteManifest(folder["out.readmelibrary"], """{"formatVersion":1,"bookIDs":[]}""");
        Assert.AreEqual(BundleError.NotABundle, ErrorOf(() => LibraryBundle.Open(folder["out.readmelibrary"])));
    }

    [TestMethod]
    public void WritesTheKeysTheMacReads()
    {
        using var folder = new TempFolder();
        var path = folder["out.readmelibrary"];
        LibraryBundle.Write([], path, Samples.At(0));
        var manifest = Encoding.UTF8.GetString(ZipReader.Open(path)!.Data("manifest.json", 1000)!);
        Assert.AreEqual("""{"formatVersion":1,"exportedAt":"1970-01-01T00:00:00Z","bookIDs":[]}""", manifest);
    }

    [TestMethod]
    public void AFailedWriteLeavesNoFile()
    {
        using var folder = new TempFolder();
        var path = folder["out.readmelibrary"];
        var item = Item(new string('a', 64), folder["gone.epub"]);
        Assert.AreEqual(BundleError.Unwritable, ErrorOf(() => LibraryBundle.Write([item], path, Samples.At(1))));
        Assert.IsFalse(File.Exists(path));
    }

    [TestMethod]
    public void Messages()
    {
        Assert.AreEqual("This file isn't a Readme library.", BundleErrors.Message(BundleError.NotABundle));
        Assert.AreEqual("This library was made by a newer Readme. Update Readme to import it.", BundleErrors.Message(BundleError.NewerVersion));
        Assert.AreEqual("That's more than 4 GB, too much for one file. Export fewer books at a time.", BundleErrors.Message(BundleError.TooLarge));
        Assert.AreEqual("The export couldn't be saved.", BundleErrors.Message(BundleError.Unwritable));
    }

    /// <summary>A file added from disk is streamed, and is the same entry as the same bytes added whole.</summary>
    [TestMethod]
    public void AFileStreamsInAsTheSameEntry()
    {
        using var folder = new TempFolder();
        var data = new byte[3 << 20];
        new Random(7).NextBytes(data);
        File.WriteAllBytes(folder["data.bin"], data);
        using (var writer = new ZipWriter(folder["a.zip"]))
        {
            writer.Add("x", folder["data.bin"]);
            writer.Finish();
        }
        using (var writer = new ZipWriter(folder["b.zip"]))
        {
            writer.Add("x", data);
            writer.Finish();
        }
        CollectionAssert.AreEqual(File.ReadAllBytes(folder["b.zip"]), File.ReadAllBytes(folder["a.zip"]));
        Assert.IsTrue(ZipReader.Open(folder["a.zip"])!.CopyTo("x", folder["out.bin"], data.Length));
        CollectionAssert.AreEqual(data, File.ReadAllBytes(folder["out.bin"]));
    }

    [TestMethod]
    public void CopyToKeepsToItsLimitAndInflates()
    {
        using var folder = new TempFolder();
        var reader = ZipReader.Open(Fixtures.Of("long.epub"))!;
        var name = reader.Names.First(n => n.EndsWith(".xhtml", StringComparison.Ordinal));
        var whole = reader.Data(name, 1 << 24)!;
        Assert.IsTrue(reader.CopyTo(name, folder["out"], 1 << 24));
        CollectionAssert.AreEqual(whole, File.ReadAllBytes(folder["out"]));
        Assert.IsFalse(reader.CopyTo(name, folder["small"], whole.Length - 1));
        Assert.IsFalse(File.Exists(folder["small"]));
        Assert.IsFalse(reader.CopyTo("nothing", folder["none"], 1 << 24));
    }

    [TestMethod]
    [DataRow("drm-bad-size.epub")]
    [DataRow("drm-past-end.epub")]
    public void CopyToRefusesWhatDataRefuses(string fixture)
    {
        using var folder = new TempFolder();
        var reader = ZipReader.Open(Fixtures.Of(fixture));
        if (reader == null) return;
        var refused = 0;
        foreach (var (name, index) in reader.Names.Select((n, i) => (n, i)))
        {
            var output = folder[$"out{index}"];
            var copied = reader.CopyTo(name, output, 1 << 24);
            Assert.AreEqual(reader.Data(name, 1 << 24) != null, copied, name);
            if (!copied)
            {
                refused++;
                Assert.IsFalse(File.Exists(output), name);
            }
        }
        Assert.IsTrue(refused > 0);
    }
}

/// <summary>Ported from LibraryExporterTests.swift.</summary>
[TestClass]
public sealed class LibraryExporterTests
{
    [TestMethod]
    public async Task ExportsBooksWithTheirNotes()
    {
        using var folder = new TempFolder();
        var store = new LibraryStore(folder["Library"]);
        var book = await Bundles.Importer(store).ImportAsync(Fixtures.Of("long.epub"));
        store.Highlights.Add(Highlight.Create("epubcfi(/6/2!/4,/1:0,/1:4)", "w", 0.1), book.Id);
        store.Markers.Set(Marker.Create("epubcfi(/6/4!/4/2/1:0)", 0.2, 4), book.Id);
        store.Positions.Save(Bundles.Place(0.5), book.Id);

        var path = folder["out.readmelibrary"];
        var summary = await new LibraryExporter(store).ExportAsync(store.Books, path);
        Assert.AreEqual(new ExportSummary(1, 0), summary);
        var opened = LibraryBundle.Open(path);
        CollectionAssert.AreEqual(new[] { book.Id }, opened.Manifest.BookIds.ToArray());
        var contents = opened.Contents(book.Id);
        Assert.AreEqual(1, contents.Highlights.Count);
        Assert.IsNotNull(contents.Marker);
        Assert.AreEqual(Bundles.Place(0.5), contents.Position);
        Assert.AreEqual("Long Fixture Book", contents.Info.Title);
        Assert.AreEqual(Iso8601SecondsConverter.Truncate(book.AddedAt), contents.Info.AddedAt);
    }

    [TestMethod]
    public async Task AMissingFileIsLeftOutAndCounted()
    {
        using var folder = new TempFolder();
        var store = new LibraryStore(folder["Library"]);
        var importer = Bundles.Importer(store);
        var longBook = await importer.ImportAsync(Fixtures.Of("long.epub"));
        var search = await importer.ImportAsync(Fixtures.Of("search.epub"));
        File.Delete(store.FilePath(search));

        var path = folder["out.readmelibrary"];
        Assert.AreEqual(new ExportSummary(1, 1), await new LibraryExporter(store).ExportAsync(store.Books, path));
        CollectionAssert.AreEqual(new[] { longBook.Id }, LibraryBundle.Open(path).Manifest.BookIds.ToArray());
    }

    [TestMethod]
    public async Task NothingToExportFails()
    {
        using var folder = new TempFolder();
        var store = new LibraryStore(folder["Library"]);
        var path = folder["out.readmelibrary"];
        var error = await Assert.ThrowsExactlyAsync<BundleException>(() => new LibraryExporter(store).ExportAsync([], path));
        Assert.AreEqual(BundleError.Unwritable, error.Error);
        Assert.IsFalse(File.Exists(path));
    }

    [TestMethod]
    public void SummaryLines()
    {
        Assert.AreEqual("Exported 1 book", new ExportSummary(1, 0).Line);
        Assert.AreEqual("Exported 12 books, 2 were missing and left out", new ExportSummary(12, 2).Line);
        Assert.AreEqual("Exported 3 books, 1 was missing and left out", new ExportSummary(3, 1).Line);
    }
}

/// <summary>Ported from LibraryImporterTests.swift: machine A exports, machine B imports.</summary>
[TestClass]
public sealed class LibraryImporterTests
{
    static readonly Highlight H = Bundles.Highlight("epubcfi(/6/4!/4,/1:0,/1:4)", "from A", 0.3, 100);
    static readonly Highlight H2 = Bundles.Highlight("epubcfi(/6/2!/4,/1:0,/1:4)", "from B", 0.1, 200);
    static readonly Marker M = Marker.Create("epubcfi(/6/6!/4/2/1:0)", 0.4, 9, created: Samples.At(300));
    static readonly Marker M2 = Marker.Create("epubcfi(/6/8!/4/2/1:0)", 0.6, 20, created: Samples.At(400));

    sealed class Machines : IDisposable
    {
        public readonly TempFolder Folder = new();
        public readonly LibraryStore A, B;
        public readonly LibraryImporter ImporterB;
        public string Url => Folder["out.readmelibrary"];

        public Machines()
        {
            A = new LibraryStore(Folder["A"]);
            B = new LibraryStore(Folder["B"]);
            ImporterB = new LibraryImporter(B, Bundles.Importer(B));
        }

        /// <summary>long.epub on A with H, M and a place halfway, added at 1000 and read at 2000, exported.</summary>
        public async Task<string> ExportFromA(DateTimeOffset? pinnedAt = null)
        {
            var book = await Bundles.Importer(A).ImportAsync(Fixtures.Of("long.epub"));
            A.ApplyImported(book.Id, Samples.At(1000), Samples.At(2000), null);
            if (pinnedAt is { } pin) A.RestorePin(book.Id, pin);
            A.Highlights.Add(H, book.Id);
            A.Markers.Set(M, book.Id);
            A.Positions.Save(Bundles.Place(0.5), book.Id);
            await new LibraryExporter(A).ExportAsync(A.Books, Url);
            return book.Id;
        }

        /// <summary>long.epub already on B, with H2, M2 and a place <paramref name="fraction"/> of the way through.</summary>
        public async Task<string> HaveOnB(double fraction)
        {
            var book = await Bundles.Importer(B).ImportAsync(Fixtures.Of("long.epub"));
            B.Highlights.Add(H2, book.Id);
            B.Markers.Set(M2, book.Id);
            B.Positions.Save(Bundles.Place(fraction), book.Id);
            return book.Id;
        }

        public async Task<ImportSummary> Import(ImportChoice choice) => await ImporterB.RunAsync(await ImporterB.PrepareAsync(Url), choice);

        public void Dispose() => Folder.Dispose();
    }

    [TestMethod]
    public async Task NewBooksComeInWithEverything()
    {
        using var m = new Machines();
        var id = await m.ExportFromA();
        var prepared = await m.ImporterB.PrepareAsync(m.Url);
        CollectionAssert.AreEqual(new[] { id }, prepared.NewIds.ToArray());
        Assert.AreEqual(0, prepared.ExistingIds.Count);
        Assert.AreEqual(new ImportSummary(Added: 1), await m.ImporterB.RunAsync(prepared, ImportChoice.KeepMine));
        var book = m.B.Book(id)!;
        Assert.AreEqual(Samples.At(1000), book.AddedAt);
        Assert.AreEqual(Samples.At(2000), book.LastReadAt);
        Assert.AreEqual("Chapter 1", book.ChapterTitle);
        CollectionAssert.AreEqual(new[] { H }, m.B.Highlights.Highlights(id).ToArray());
        Assert.AreEqual(M, m.B.Markers.Marker(id));
        Assert.AreEqual(Bundles.Place(0.5), m.B.Positions.Location(id));
        Assert.IsTrue(File.Exists(m.B.CoverPath(book)));
    }

    /// <summary>The title and author the shelf showed on the other machine, not the file's own or its staged name.</summary>
    [TestMethod]
    public async Task NewBooksKeepTheirShelfTitle()
    {
        using var m = new Machines();
        var epub = Fixtures.Of("no-cover.epub");
        var id = await BookId.OfAsync(epub);
        LibraryBundle.Write([new BundleItem(id, new BundledBook { Title = "Shelf Title", Author = "Shelf Author", AddedAt = Samples.At(1) }, epub, [], null, null)],
            m.Url, Samples.At(1));
        await m.Import(ImportChoice.KeepMine);
        Assert.AreEqual("Shelf Title", m.B.Book(id)?.Title);
        Assert.AreEqual("Shelf Author", m.B.Book(id)?.Author);
    }

    [TestMethod]
    public async Task NewBooksKeepTheirPin()
    {
        using var m = new Machines();
        var id = await m.ExportFromA(Samples.At(3000));
        await m.Import(ImportChoice.KeepMine);
        Assert.AreEqual(Samples.At(3000), m.B.Book(id)?.PinnedAt);
    }

    [TestMethod]
    [DataRow(ImportChoice.KeepMine)]
    [DataRow(ImportChoice.Combine)]
    public async Task ExistingBooksKeepTheirOwnPin(ImportChoice choice)
    {
        using var m = new Machines();
        // Pinned there, not here: stays unpinned.
        var id = await m.ExportFromA(Samples.At(3000));
        await m.HaveOnB(0.2);
        await m.Import(choice);
        Assert.IsNull(m.B.Book(id)?.PinnedAt);
        // Pinned here, not there: stays pinned, with its own date.
        m.B.RestorePin(id, Samples.At(4000));
        m.A.SetPinned([id], false);
        await new LibraryExporter(m.A).ExportAsync(m.A.Books, m.Url);
        await m.Import(choice);
        Assert.AreEqual(Samples.At(4000), m.B.Book(id)?.PinnedAt);
    }

    [TestMethod]
    public async Task KeepMineLeavesExistingBooksAlone()
    {
        using var m = new Machines();
        var id = await m.ExportFromA();
        await m.HaveOnB(0.2);
        var before = m.B.Books;
        var prepared = await m.ImporterB.PrepareAsync(m.Url);
        CollectionAssert.AreEqual(new[] { id }, prepared.ExistingIds.ToArray());
        Assert.AreEqual(new ImportSummary(Kept: 1), await m.ImporterB.RunAsync(prepared, ImportChoice.KeepMine));
        CollectionAssert.AreEqual(before.ToArray(), m.B.Books.ToArray());
        CollectionAssert.AreEqual(new[] { H2 }, m.B.Highlights.Highlights(id).ToArray());
        Assert.AreEqual(M2, m.B.Markers.Marker(id));
        Assert.AreEqual(Bundles.Place(0.2), m.B.Positions.Location(id));
    }

    [TestMethod]
    public async Task CombineAddsHighlightsAndTheFurtherPlace()
    {
        using var m = new Machines();
        var id = await m.ExportFromA();
        await m.HaveOnB(0.2);
        Assert.AreEqual(new ImportSummary(Combined: 1), await m.Import(ImportChoice.Combine));
        CollectionAssert.AreEqual(new[] { H2, H }, m.B.Highlights.Highlights(id).ToArray());
        Assert.AreEqual(M2, m.B.Markers.Marker(id));
        Assert.AreEqual(Bundles.Place(0.5), m.B.Positions.Location(id));
        Assert.AreEqual(Samples.At(2000), m.B.Book(id)?.LastReadAt);
    }

    [TestMethod]
    public async Task CombineKeepsTheFurtherPlaceHere()
    {
        using var m = new Machines();
        var id = await m.ExportFromA();
        await m.HaveOnB(0.9);
        await m.Import(ImportChoice.Combine);
        Assert.AreEqual(Bundles.Place(0.9), m.B.Positions.Location(id));
    }

    [TestMethod]
    public async Task CombineTakesTheMarkerWhenThereIsNoneHere()
    {
        using var m = new Machines();
        var id = await m.ExportFromA();
        await m.HaveOnB(0.2);
        m.B.Markers.Remove(id);
        await m.Import(ImportChoice.Combine);
        Assert.AreEqual(M, m.B.Markers.Marker(id));
    }

    [TestMethod]
    public async Task CombineDropsThePictureOnlyWhenThePlaceMoves()
    {
        using var m = new Machines();
        var spreads = new LastSpreadCache(m.Folder["Spreads"]);
        var importer = new LibraryImporter(m.B, Bundles.Importer(m.B), spreads);
        var id = await m.ExportFromA();
        await m.HaveOnB(0.9);
        spreads.Save([1, 2, 3], "look", id);
        await importer.RunAsync(await importer.PrepareAsync(m.Url), ImportChoice.Combine);
        Assert.IsNotNull(spreads.Image(id, "look"));
        m.B.Positions.Save(Bundles.Place(0.1), id);
        await importer.RunAsync(await importer.PrepareAsync(m.Url), ImportChoice.Combine);
        Assert.IsNull(spreads.Image(id, "look"));
    }

    [TestMethod]
    public async Task ImportingTwiceChangesNothing()
    {
        using var m = new Machines();
        var id = await m.ExportFromA();
        await m.Import(ImportChoice.Combine);
        var books = m.B.Books;
        Assert.AreEqual(new ImportSummary(Combined: 1), await m.Import(ImportChoice.Combine));
        CollectionAssert.AreEqual(books.ToArray(), m.B.Books.ToArray());
        CollectionAssert.AreEqual(new[] { H }, m.B.Highlights.Highlights(id).ToArray());
    }

    [TestMethod]
    public async Task ABadBookInTheBundleIsSkipped()
    {
        using var m = new Machines();
        var drm = Fixtures.Of("drm.epub");
        var longBook = Fixtures.Of("long.epub");
        var info = new BundledBook { Title = "T", AddedAt = Samples.At(1) };
        LibraryBundle.Write([
            new BundleItem(await BookId.OfAsync(drm), info, drm, [], null, null),
            new BundleItem(await BookId.OfAsync(longBook), info, longBook, [], null, null),
        ], m.Url, Samples.At(1));
        Assert.AreEqual(new ImportSummary(Added: 1, Failed: 1), await m.Import(ImportChoice.KeepMine));
        CollectionAssert.AreEqual(new[] { await BookId.OfAsync(longBook) }, m.B.Books.Select(b => b.Id).ToArray());
    }

    [TestMethod]
    public async Task ABookWhoseFileDoesntMatchItsIdIsSkipped()
    {
        using var m = new Machines();
        var info = new BundledBook { Title = "T", AddedAt = Samples.At(1) };
        LibraryBundle.Write([new BundleItem(new string('a', 64), info, Fixtures.Of("long.epub"), [H], null, null)], m.Url, Samples.At(1));
        Assert.AreEqual(new ImportSummary(Failed: 1), await m.Import(ImportChoice.KeepMine));
        Assert.AreEqual(0, m.B.Books.Count);
    }

    [TestMethod]
    public async Task NoLeftoverStagingFiles()
    {
        using var m = new Machines();
        await m.ExportFromA();
        await m.Import(ImportChoice.KeepMine);
        var left = Directory.GetFiles(m.B.BooksDirectory).Select(Path.GetFileName).ToList();
        Assert.IsFalse(left.Any(n => n!.StartsWith(".bundle-") || n.StartsWith(".importing-")), string.Join(", ", left));
    }

    [TestMethod]
    public void SummaryLines()
    {
        Assert.AreEqual("Added 4 books, combined 2, 1 couldn't be read", new ImportSummary(Added: 4, Combined: 2, Failed: 1).Line);
        Assert.AreEqual("Added 1 book", new ImportSummary(Added: 1).Line);
        Assert.AreEqual("Left 2 as they were", new ImportSummary(Kept: 2).Line);
        Assert.AreEqual("Combined 1, left 1 as they were", new ImportSummary(Combined: 1, Kept: 1).Line);
        Assert.AreEqual("3 couldn't be read", new ImportSummary(Failed: 3).Line);
        Assert.AreEqual("Nothing to import", new ImportSummary().Line);
    }

    [TestMethod]
    public void Question()
    {
        Assert.AreEqual("This book is already in your library.", ImportQuestion.Message(1, 1));
        Assert.AreEqual("1 of these books is already in your library.", ImportQuestion.Message(1, 3));
        Assert.AreEqual("2 of these books are already in your library.", ImportQuestion.Message(2, 3));
        CollectionAssert.AreEqual(new[] { "Keep Mine", "Combine", "Cancel" }, ImportQuestion.Buttons.ToArray());
    }
}
