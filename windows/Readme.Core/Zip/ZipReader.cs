using System.Buffers.Binary;
using System.IO.Compression;

namespace Readme.Core.Zip;

/// <summary>
/// The entries of a zip file (ZipArchive in EPUBInspector.swift), read through its central directory,
/// so only the entries asked for are read. Handles stored and deflated entries, which are all an EPUB
/// has. A zip that needs ZIP64 isn't read, and counts as not being one. Ported rather than using
/// <see cref="System.IO.Compression.ZipArchive"/>, so the malformed fixtures behave as on Mac.
/// </summary>
public sealed class ZipReader
{
    readonly record struct Entry(ushort Method, long CompressedSize, long Size, long HeaderOffset);

    readonly string _path;
    readonly long _length;
    readonly Dictionary<string, Entry> _entries;

    ZipReader(string path, long length, Dictionary<string, Entry> entries)
    {
        _path = path;
        _length = length;
        _entries = entries;
    }

    /// <summary>The zip at <paramref name="path"/>, or null if it can't be read as one.</summary>
    public static ZipReader? Open(string path)
    {
        try
        {
            using var file = File.OpenRead(path);
            var length = file.Length;
            // The end record is 22 bytes plus a comment of up to 65535.
            var tail = (int)Math.Min(length, 22 + 65535);
            file.Seek(length - tail, SeekOrigin.Begin);
            var end = ReadExactly(file, tail);
            if (end == null || EndRecord(end) is not { } recordStart) return null;
            var record = end.AsSpan(recordStart);
            int count = U16(record, 10);
            long directorySize = U32(record, 12);
            long directoryOffset = U32(record, 16);
            if (count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF
                || directoryOffset + directorySize > length) return null;
            file.Seek(directoryOffset, SeekOrigin.Begin);
            var directory = ReadExactly(file, (int)directorySize);
            if (directory == null) return null;

            var entries = new Dictionary<string, Entry>(StringComparer.Ordinal);
            var position = 0;
            for (var i = 0; i < count; i++)
            {
                if (position + 46 > directory.Length || U32(directory, position) != 0x0201_4b50) return null;
                int nameLength = U16(directory, position + 28);
                int extraLength = U16(directory, position + 30);
                int commentLength = U16(directory, position + 32);
                var nameStart = position + 46;
                if (nameStart + nameLength > directory.Length) return null;
                // Swift's String(decoding:as:) replaces bad UTF-8 rather than failing; so does this.
                var name = System.Text.Encoding.UTF8.GetString(directory, nameStart, nameLength);
                entries[name] = new Entry(
                    U16(directory, position + 10),
                    U32(directory, position + 20),
                    U32(directory, position + 24),
                    U32(directory, position + 42));
                position = nameStart + nameLength + extraLength + commentLength;
            }
            return new ZipReader(path, length, entries);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public bool Contains(string name) => _entries.ContainsKey(name);

    /// <summary>Every entry's name, in no particular order.</summary>
    public IReadOnlyCollection<string> Names => _entries.Keys;

    /// <summary>
    /// The entry's bytes, or null if there's no such entry, it's larger than <paramref name="limit"/>
    /// (packed or unpacked), it reaches past the end of the file, or it doesn't inflate to the size it
    /// declares. Nothing larger than the limit is ever allocated.
    /// </summary>
    public byte[]? Data(string name, long limit)
    {
        if (!_entries.TryGetValue(name, out var entry) || entry.Size > limit || entry.CompressedSize > limit
            || entry.HeaderOffset + 30 + entry.CompressedSize > _length) return null;
        // A .NET array stops just short of 2 GB, where the Mac's Data doesn't; a book that size is
        // refused here. Bundles (phase 5) should stream book.epub instead of reading it whole.
        if (entry.Size > Array.MaxLength || entry.CompressedSize > Array.MaxLength) return null;
        try
        {
            using var file = File.OpenRead(_path);
            file.Seek(entry.HeaderOffset, SeekOrigin.Begin);
            var header = ReadExactly(file, 30);
            if (header == null || U32(header, 0) != 0x0403_4b50) return null;
            long skip = U16(header, 26) + U16(header, 28);
            if (entry.HeaderOffset + 30 + skip + entry.CompressedSize > _length) return null;
            file.Seek(entry.HeaderOffset + 30 + skip, SeekOrigin.Begin);
            var packed = ReadExactly(file, (int)entry.CompressedSize);
            if (packed == null) return null;
            switch (entry.Method)
            {
                case 0:
                    return packed.Length == entry.Size ? packed : null;
                case 8:
                    // As on Mac, inflate into a buffer of the declared size: it must fill it exactly.
                    var output = new byte[entry.Size];
                    using (var inflater = new DeflateStream(new MemoryStream(packed), CompressionMode.Decompress))
                    {
                        var written = 0;
                        while (written < output.Length)
                        {
                            var read = inflater.Read(output, written, output.Length - written);
                            if (read == 0) break;
                            written += read;
                        }
                        return written == entry.Size ? output : null;
                    }
                default:
                    return null;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            return null;
        }
    }

    /// <summary>
    /// Where the end record starts: the last place its signature is followed by a comment that runs
    /// exactly to the end of the file. A comment may hold the signature itself, so a match that doesn't
    /// fit isn't one.
    /// </summary>
    static int? EndRecord(byte[] tail)
    {
        for (var start = tail.Length - 4; start >= 0; start--)
        {
            if (U32(tail, start) != 0x0605_4b50) continue;
            var length = tail.Length - start;
            if (length >= 22 && 22 + U16(tail, start + 20) == length) return start;
        }
        return null;
    }

    static byte[]? ReadExactly(Stream stream, int count)
    {
        var buffer = new byte[count];
        var read = 0;
        while (read < count)
        {
            var n = stream.Read(buffer, read, count - read);
            if (n == 0) return null;
            read += n;
        }
        return buffer;
    }

    static ushort U16(ReadOnlySpan<byte> data, int offset) => BinaryPrimitives.ReadUInt16LittleEndian(data[offset..]);
    static uint U32(ReadOnlySpan<byte> data, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(data[offset..]);
}
