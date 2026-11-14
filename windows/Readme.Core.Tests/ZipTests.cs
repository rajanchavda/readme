using System.Text;
using Readme.Core.Zip;

namespace Readme.Core.Tests;

/// <summary>Ported from EPUBInspectorTests.swift, plus every fixture's verdict.</summary>
[TestClass]
public sealed class EpubInspectorTests
{
    [TestMethod]
    [DataRow("drm-bad-xml.epub")]   // encryption.xml that does not parse
    [DataRow("drm-bad-size.epub")]  // declares a size it does not inflate to
    [DataRow("drm-bomb.epub")]      // declares nearly 4 GB
    [DataRow("drm-past-end.epub")]  // declares bytes beyond the end of the file
    [DataRow("drm-rights.epub")]    // Adobe ADEPT
    [DataRow("drm-lcp.epub")]       // Readium LCP
    [DataRow("drm-sinf.epub")]      // Apple FairPlay
    [DataRow("drm.epub")]           // real encryption in encryption.xml
    public void ProtectedInTheseWays(string name) =>
        Assert.AreEqual(ImportError.CopyProtected, Verdict(name));

    [TestMethod]
    [DataRow("not-an-epub.epub")]
    [DataRow("plain-zip.epub")]
    public void NotAnEpub(string name) => Assert.AreEqual(ImportError.NotAnEpub, Verdict(name));

    [TestMethod]
    public void ACommentThatLooksLikeAnEndRecordIsNotOne() => Assert.IsNull(Verdict("pk-comment.epub"));

    [TestMethod]
    public void FontObfuscationAndPlainBooksPass()
    {
        Assert.IsNull(Verdict("obfuscated.epub"));
        Assert.IsNull(Verdict("long.epub"));
    }

    /// <summary>Every fixture is either an EPUB or refused, never an exception of another kind.</summary>
    [TestMethod]
    public void EveryFixtureGetsAVerdict()
    {
        var protectedOrJunk = new[]
        {
            "drm-bad-xml.epub", "drm-bad-size.epub", "drm-bomb.epub", "drm-past-end.epub", "drm-rights.epub",
            "drm-lcp.epub", "drm-sinf.epub", "drm.epub", "not-an-epub.epub", "plain-zip.epub",
        };
        var all = Directory.GetFiles(Fixtures.Root, "*.epub").Select(Path.GetFileName).ToList();
        Assert.AreEqual(24, all.Count);
        foreach (var name in all)
            Assert.AreEqual(protectedOrJunk.Contains(name), Verdict(name!) != null, name);
    }

    [TestMethod]
    public void AMissingFileIsUnreadable() =>
        Assert.AreEqual(ImportError.Unreadable, Verdict("no-such-file.epub"));

    [TestMethod]
    public void EncryptionWithADoctypeIsReadWithoutExpandingEntities()
    {
        var xml = """
            <?xml version="1.0"?>
            <!DOCTYPE encryption [<!ENTITY big "x">]>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/></enc:EncryptedData>
            </encryption>
            """;
        CollectionAssert.AreEquivalent(new[] { "http://www.idpf.org/2008/embedding" },
            EpubInspector.EncryptionMethods(Encoding.UTF8.GetBytes(xml))!.ToArray());
        Assert.IsNull(EpubInspector.EncryptionMethods(Encoding.UTF8.GetBytes("<encryption><unclosed")));
    }

    static ImportError? Verdict(string name)
    {
        try
        {
            EpubInspector.Check(Fixtures.Of(name));
            return null;
        }
        catch (ImportException error)
        {
            return error.Error;
        }
    }
}

/// <summary>Ported from ZipWriterTests.swift.</summary>
[TestClass]
public sealed class ZipWriterTests
{
    [TestMethod]
    public void CrcOfTheStandardCheckString()
    {
        Assert.AreEqual(0xCBF4_3926u, Crc32.Checksum("123456789"u8));
        Assert.AreEqual(0u, Crc32.Checksum([]));
    }

    [TestMethod]
    public void RoundTripsThroughZipReader()
    {
        using var folder = new TempFolder();
        var path = folder["out.zip"];
        var book = Fixtures.Of("long.epub");
        using (var writer = new ZipWriter(path))
        {
            writer.Add("a.json", """{"k":1}"""u8);
            writer.Add("books/x/book.epub", book);
            writer.Finish();
        }
        var archive = ZipReader.Open(path);
        Assert.IsNotNull(archive);
        CollectionAssert.AreEquivalent(new[] { "a.json", "books/x/book.epub" }, archive.Names.ToArray());
        CollectionAssert.AreEqual("""{"k":1}"""u8.ToArray(), archive.Data("a.json", 1 << 20));
        CollectionAssert.AreEqual(File.ReadAllBytes(book), archive.Data("books/x/book.epub", 1 << 30));
    }

    [TestMethod]
    public void SystemZipReadsWhatItWrites()
    {
        // A second opinion that the layout is a valid zip, from .NET's own reader.
        using var folder = new TempFolder();
        var path = folder["out.zip"];
        using (var writer = new ZipWriter(path))
        {
            writer.Add("manifest.json", "{}"u8);
            writer.Finish();
        }
        using var zip = System.IO.Compression.ZipFile.OpenRead(path);
        Assert.AreEqual("manifest.json", zip.Entries.Single().FullName);
    }

    [TestMethod]
    public void OverwritesAnExistingFile()
    {
        using var folder = new TempFolder();
        var path = folder["out.zip"];
        File.WriteAllBytes(path, Enumerable.Repeat((byte)0xFF, 1 << 20).ToArray());
        using (var writer = new ZipWriter(path))
        {
            writer.Add("a.json", "{}"u8);
            writer.Finish();
        }
        Assert.IsTrue(new FileInfo(path).Length < 1024);
        Assert.IsNotNull(ZipReader.Open(path));
    }

    [TestMethod]
    public void TooLargeFailsAndLeavesNoFile()
    {
        using var folder = new TempFolder();
        var path = folder["out.zip"];
        var writer = new ZipWriter(path, limit: 100);
        var error = Assert.ThrowsExactly<ZipWriterException>(() => writer.Add("big", new byte[200]));
        Assert.AreEqual(ZipWriterFailure.TooLarge, error.Failure);
        Assert.IsFalse(File.Exists(path));
    }

    [TestMethod]
    public void AbandonedWriterLeavesNoFile()
    {
        using var folder = new TempFolder();
        var path = folder["out.zip"];
        using (var writer = new ZipWriter(path)) writer.Add("a.json", "{}"u8);
        Assert.IsFalse(File.Exists(path));
    }
}
