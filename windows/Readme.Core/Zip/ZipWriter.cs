using System.Buffers.Binary;
using System.Text;

namespace Readme.Core.Zip;

/// <summary>The zip format's CRC-32 (IEEE, reflected, polynomial 0xEDB88320).</summary>
public static class Crc32
{
    static readonly uint[] Table = Enumerable.Range(0, 256).Select(index =>
    {
        var value = (uint)index;
        for (var i = 0; i < 8; i++) value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1;
        return value;
    }).ToArray();

    public static uint Checksum(ReadOnlySpan<byte> data)
    {
        var crc = 0xFFFF_FFFFu;
        foreach (var b in data) crc = Table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFF_FFFF;
    }
}

public enum ZipWriterFailure { TooLarge, Unwritable }

public sealed class ZipWriterException(ZipWriterFailure failure)
    : Exception(failure == ZipWriterFailure.TooLarge ? "The zip would be too large" : "The zip couldn't be written")
{
    public ZipWriterFailure Failure { get; } = failure;
}

/// <summary>
/// Writes a zip whose entries are stored uncompressed (ZipWriter.swift), which is all a library bundle
/// needs: its books are zips already. There's no ZIP64, so a file that would pass
/// <c>limit</c> bytes or hold 65535 entries fails with <see cref="ZipWriterFailure.TooLarge"/>. Any
/// failure deletes what was written, so there's never a broken file left behind. Byte for byte the
/// same layout as the Mac's, which reads only stored or deflated entries and no ZIP64.
/// </summary>
public sealed class ZipWriter : IDisposable
{
    readonly record struct Entry(byte[] Name, uint Crc, uint Size, uint Offset);

    readonly string _path;
    readonly long _limit;
    FileStream? _file;
    long _offset;
    readonly List<Entry> _entries = [];

    /// <summary>Creates the file, or empties the one that's there.</summary>
    public ZipWriter(string path, long limit = 0xFFFF_FFFE)
    {
        _path = path;
        _limit = limit;
        try
        {
            _file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new ZipWriterException(ZipWriterFailure.Unwritable);
        }
    }

    public void Add(string name, string file)
    {
        byte[] data;
        try { data = File.ReadAllBytes(file); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or OutOfMemoryException)
        {
            throw Fail(ZipWriterFailure.Unwritable);
        }
        Add(name, data);
    }

    public void Add(string name, ReadOnlySpan<byte> data)
    {
        var nameBytes = Encoding.UTF8.GetBytes(name);
        // This entry, and the directory record and end record that will follow it, must fit.
        var end = _offset + 30 + nameBytes.Length + data.Length;
        var directory = _entries.Sum(e => 46L + e.Name.Length) + 46 + nameBytes.Length;
        if (_entries.Count + 1 >= 0xFFFF || nameBytes.Length > 0xFFFF || end + directory + 22 > _limit)
            throw Fail(ZipWriterFailure.TooLarge);
        var entry = new Entry(nameBytes, Crc32.Checksum(data), (uint)data.Length, (uint)_offset);
        var header = new Bytes();
        header.U32(0x0403_4B50).U16(20).U16(0x0800).U16(0).U16(0).U16(0)
            .U32(entry.Crc).U32(entry.Size).U32(entry.Size)
            .U16((ushort)nameBytes.Length).U16(0).Raw(nameBytes);
        Write(header.ToArray());
        Write(data);
        _entries.Add(entry);
    }

    /// <summary>Writes the directory, closes the file, and leaves it complete.</summary>
    public void Finish()
    {
        var start = _offset;
        var directory = new Bytes();
        foreach (var entry in _entries)
        {
            directory.U32(0x0201_4B50).U16(20).U16(20).U16(0x0800).U16(0).U16(0).U16(0)
                .U32(entry.Crc).U32(entry.Size).U32(entry.Size)
                .U16((ushort)entry.Name.Length).U16(0).U16(0).U16(0).U16(0).U32(0).U32(entry.Offset)
                .Raw(entry.Name);
        }
        var directoryBytes = directory.ToArray();
        var end = new Bytes();
        end.U32(0x0605_4B50).U16(0).U16(0).U16((ushort)_entries.Count).U16((ushort)_entries.Count)
            .U32((uint)directoryBytes.Length).U32((uint)start).U16(0);
        Write(directoryBytes);
        Write(end.ToArray());
        try
        {
            _file?.Dispose();
        }
        catch (IOException)
        {
            throw Fail(ZipWriterFailure.Unwritable);
        }
        _file = null;
    }

    void Write(ReadOnlySpan<byte> data)
    {
        if (_file == null) throw new ZipWriterException(ZipWriterFailure.Unwritable);
        try { _file.Write(data); }
        catch (IOException) { throw Fail(ZipWriterFailure.Unwritable); }
        _offset += data.Length;
    }

    /// <summary>Closes and deletes the file, and hands back the exception to throw.</summary>
    ZipWriterException Fail(ZipWriterFailure failure)
    {
        try { _file?.Dispose(); } catch (IOException) { }
        _file = null;
        try { File.Delete(_path); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return new ZipWriterException(failure);
    }

    /// <summary>Abandons an unfinished zip, deleting it.</summary>
    public void Dispose()
    {
        if (_file != null) Fail(ZipWriterFailure.Unwritable);
    }

    sealed class Bytes
    {
        readonly MemoryStream _stream = new();

        public Bytes U16(ushort value)
        {
            Span<byte> buffer = stackalloc byte[2];
            BinaryPrimitives.WriteUInt16LittleEndian(buffer, value);
            _stream.Write(buffer);
            return this;
        }

        public Bytes U32(uint value)
        {
            Span<byte> buffer = stackalloc byte[4];
            BinaryPrimitives.WriteUInt32LittleEndian(buffer, value);
            _stream.Write(buffer);
            return this;
        }

        public Bytes Raw(byte[] bytes)
        {
            _stream.Write(bytes);
            return this;
        }

        public byte[] ToArray() => _stream.ToArray();
    }
}
