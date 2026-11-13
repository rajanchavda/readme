using System.Xml;

namespace Readme.Core.Zip;

public enum ImportError
{
    /// <summary>Not an EPUB at all.</summary>
    NotAnEpub,
    /// <summary>Locked with DRM, which the app can't open.</summary>
    CopyProtected,
    /// <summary>An EPUB that couldn't be copied or opened.</summary>
    Unreadable,
}

public sealed class ImportException(ImportError error) : Exception(error.ToString())
{
    public ImportError Error { get; } = error;
}

/// <summary>
/// Looks inside an EPUB's zip before any web view does (EPUBInspector.swift), to tell a book from junk,
/// and a book that can be read from one that's copy-protected.
/// </summary>
public static class EpubInspector
{
    /// <summary>
    /// Font obfuscation, which a reading system undoes with the book's own identifier. Everything else
    /// in <c>encryption.xml</c> is real encryption, and needs a licence the app doesn't have.
    /// </summary>
    public static readonly IReadOnlySet<string> ObfuscationAlgorithms = new HashSet<string>
    {
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    };

    /// <summary>Files that only protected books carry: Adobe ADEPT, Readium LCP and Apple FairPlay.</summary>
    public static readonly IReadOnlyList<string> ProtectionFiles =
        ["META-INF/rights.xml", "META-INF/license.lcpl", "META-INF/sinf.xml"];

    /// <summary>The most that's read of any entry here. A real encryption.xml is a few kilobytes.</summary>
    public const int ReadLimit = 1 << 20;

    /// <summary>
    /// Throws <see cref="ImportError.NotAnEpub"/> for a file that isn't a zip with a mimetype or a
    /// container.xml, and <see cref="ImportError.CopyProtected"/> for one with a protection file, or one
    /// that encrypts anything but fonts' obfuscation. An <c>encryption.xml</c> that can't be read or
    /// parsed counts as protection too: there's no telling what it hides. A file that can't be read at
    /// all is <see cref="ImportError.Unreadable"/>.
    /// </summary>
    public static void Check(string path)
    {
        if (!IsReadable(path)) throw new ImportException(ImportError.Unreadable);
        var archive = ZipReader.Open(path) ?? throw new ImportException(ImportError.NotAnEpub);
        if (!archive.Contains("mimetype") && !archive.Contains("META-INF/container.xml"))
            throw new ImportException(ImportError.NotAnEpub);
        if (ProtectionFiles.Any(archive.Contains)) throw new ImportException(ImportError.CopyProtected);
        if (archive.Contains("META-INF/encryption.xml"))
        {
            var data = archive.Data("META-INF/encryption.xml", ReadLimit);
            var methods = data == null ? null : EncryptionMethods(data);
            if (methods == null || !methods.IsSubsetOf(ObfuscationAlgorithms))
                throw new ImportException(ImportError.CopyProtected);
        }
    }

    /// <summary>The algorithm of each EncryptionMethod, or null if the file doesn't parse.</summary>
    public static HashSet<string>? EncryptionMethods(byte[] data)
    {
        var settings = new XmlReaderSettings
        {
            // As Swift's XMLParser: a DOCTYPE is passed over, and no entity is ever expanded.
            DtdProcessing = DtdProcessing.Ignore,
            XmlResolver = null,
        };
        var algorithms = new HashSet<string>();
        try
        {
            using var reader = XmlReader.Create(new MemoryStream(data), settings);
            while (reader.Read())
            {
                if (reader.NodeType == XmlNodeType.Element && reader.LocalName == "EncryptionMethod")
                    algorithms.Add(reader.GetAttribute("Algorithm") ?? "");
            }
            return algorithms;
        }
        catch (XmlException)
        {
            return null;
        }
    }

    static bool IsReadable(string path)
    {
        try
        {
            using var _ = File.OpenRead(path);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }
}
