using System.Text.Json;
using System.Text.Json.Nodes;
using Readme.Core.Model;
using Readme.Core.Storage;

namespace Readme.Core.Tests;

/// <summary>
/// The formats both apps share, in <c>ReadmeTests/Fixtures/Golden</c>, which GoldenFilesTests.swift
/// reads too. Each file is read and checked value by value, then written back and compared with the
/// golden JSON, so what Windows writes is what the Mac writes.
/// </summary>
[TestClass]
public sealed class GoldenFilesTests
{
    static DateTimeOffset Reference(double seconds) => ReferenceDateConverter.FromSeconds(seconds);

    static DateTimeOffset Iso(string text) => DateTimeOffset.Parse(text, System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>The same JSON, whatever the key order or the escaping of "/".</summary>
    static void AssertSameJson(string goldenFile, string written)
    {
        var expected = JsonNode.Parse(File.ReadAllText(Fixtures.Golden(goldenFile)));
        var actual = JsonNode.Parse(written);
        Assert.IsTrue(JsonNode.DeepEquals(expected, actual), $"{goldenFile}\nexpected {expected!.ToJsonString()}\nwrote    {actual!.ToJsonString()}");
    }

    [TestMethod]
    public void LibraryFileLoads()
    {
        using var folder = new TempFolder();
        File.Copy(Fixtures.Golden("library.json"), folder["library.json"]);
        var books = new LibraryStore(folder.Path).Books;
        Assert.AreEqual(2, books.Count);
        var longBook = books[0];
        Assert.AreEqual("94d86ef4fdd170a2f2714779a4ad0ae759f882d0edba9ded1579cc64691b10cb", longBook.Id);
        Assert.AreEqual("Long Book", longBook.Title);
        Assert.AreEqual("A. Writer", longBook.Author);
        Assert.IsTrue(longBook.HasCover);
        Assert.AreEqual(Reference(784_000_000), longBook.AddedAt);
        Assert.AreEqual(Reference(784_500_000.5), longBook.LastReadAt);
        Assert.AreEqual(new DateTimeOffset(2025, 11, 10, 20, 40, 0, 500, TimeSpan.Zero), longBook.LastReadAt);
        Assert.AreEqual("Chapter 3", longBook.ChapterTitle);
        Assert.AreEqual(7.25, longBook.ChapterMinutesLeft);
        Assert.IsNull(longBook.PinnedAt);
        var pinned = books[1];
        Assert.AreEqual("Les Misérables", pinned.Title);
        Assert.IsNull(pinned.Author);
        Assert.IsNull(pinned.LastReadAt);
        Assert.AreEqual(Reference(784_600_000), pinned.PinnedAt);
    }

    [TestMethod]
    public void LibraryFileIsWrittenAsTheMacWritesIt()
    {
        var books = JsonSerializer.Deserialize<List<Book>>(File.ReadAllBytes(Fixtures.Golden("library.json")), Json.Library);
        AssertSameJson("library.json", JsonSerializer.Serialize(books, Json.Library));
    }

    [TestMethod]
    public void HighlightsLoadAndWriteBack()
    {
        using var folder = new TempFolder();
        File.Copy(Fixtures.Golden("highlights.json"), folder["book.json"]);
        var highlights = new HighlightStore(folder.Path).Highlights("book");
        CollectionAssert.AreEqual(
            new[] { "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", "0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9" },
            highlights.Select(h => h.Id.ToString().ToUpperInvariant()).ToArray());
        Assert.AreEqual("epubcfi(/6/4!/4/2,/1:0,/1:12)", highlights[0].Cfi);
        Assert.AreEqual(Iso("2026-11-13T09:30:00Z"), highlights[0].Created);
        Assert.AreEqual("Ünïcödé — and “quotes”", highlights[1].Text);
        Assert.IsNull(highlights[1].ChapterTitle);
        AssertSameJson("highlights.json", JsonSerializer.Serialize(highlights, Json.Iso));
    }

    [TestMethod]
    public void MarkerLoadsAndWritesBack()
    {
        using var folder = new TempFolder();
        File.Copy(Fixtures.Golden("marker.json"), folder["book.json"]);
        var marker = new MarkerStore(folder.Path).Marker("book");
        Assert.AreEqual(Marker.Create("epubcfi(/6/8!/4/2/1:0)", 0.4, 120, "Chapter 4", Iso("2026-11-13T10:00:00Z")), marker);
        AssertSameJson("marker.json", JsonSerializer.Serialize(marker, Json.Iso));
    }

    [TestMethod]
    public void PositionLoadsAndWritesBack()
    {
        using var folder = new TempFolder();
        File.Copy(Fixtures.Golden("position.json"), folder["book.json"]);
        var location = new PositionStore(folder.Path).Location("book");
        Assert.AreEqual(new ReaderLocation
        {
            Cfi = "epubcfi(/6/14!/4/2/10,/1:12,/3:40)", Fraction = 0.42, ChapterTitle = "Chapter 7",
            ChapterMinutesLeft = 6.5, IsAtStart = false, IsAtEnd = false, Page = 210, PageCount = 500, IsMarked = true,
        }, location);
        AssertSameJson("position.json", JsonSerializer.Serialize(location, Json.Library));
    }

    [TestMethod]
    public async Task BookIdsMatchTheMac()
    {
        var ids = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(Fixtures.Golden("ids.json")))!;
        Assert.AreEqual(3, ids.Count);
        foreach (var (name, id) in ids) Assert.AreEqual(id, await BookId.OfAsync(Fixtures.Of(name)), name);
    }

    [TestMethod]
    public void LibraryDatesSurviveTheFileExactly()
    {
        var random = new Random(7);
        for (var i = 0; i < 100_000; i++)
        {
            var moment = ReferenceDateConverter.Normalize(
                new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero).AddTicks(random.NextInt64(0, 100L * 365 * TimeSpan.TicksPerDay)));
            var json = JsonSerializer.Serialize(moment, Json.Library);
            Assert.AreEqual(moment, JsonSerializer.Deserialize<DateTimeOffset>(json, Json.Library), json);
        }
    }

    [TestMethod]
    public void IsoDatesHaveNoFractionalSeconds()
    {
        // The Mac's .iso8601 decoder rejects "…:00.123Z", so a highlight made a moment into a second
        // must still be written in whole seconds.
        var highlight = Highlight.Create("x", "t", 0, created: new DateTimeOffset(2026, 11, 13, 9, 30, 0, 123, TimeSpan.FromHours(5.5)));
        var json = JsonSerializer.Serialize(highlight, Json.Iso);
        StringAssert.Contains(json, "\"created\":\"2026-11-13T04:00:00Z\"");
        StringAssert.Contains(json, highlight.Id.ToString().ToUpperInvariant());
    }
}
