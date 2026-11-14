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

    public static uint Checksum(ReadOnlySpan<byte> data) => Update(0, data);

    /// <summary>The checksum of what <paramref name="crc"/> covered followed by <paramref name="data"/>; 0 to start.</summary>
    public static uint Update(uint crc, ReadOnlySpan<byte> data)
    {
        crc ^= 0xFFFF_FFFF;
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

    /// <summary>
    /// Adds the file's contents, streamed rather than read whole, so a book of any size the zip can
    /// hold goes in: read once for its checksum, then again into the zip. The same entry the Mac writes.
    /// </summary>
    public void Add(string name, string file)
    {
        var nameBytes = Encoding.UTF8.GetBytes(name);
        try
        {
            using var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16);
            var size = input.Length;
            Reserve(nameBytes, size);
            var buffer = new byte[1 << 20];
            var crc = 0u;
            for (int read; (read = input.Read(buffer)) > 0;) crc = Crc32.Update(crc, buffer.AsSpan(0, read));
            if (input.Length != size) throw Fail(ZipWriterFailure.Unwritable);
            var entry = new Entry(nameBytes, crc, (uint)size, (uint)_offset);
            WriteHeader(entry);
            input.Seek(0, SeekOrigin.Begin);
            long copied = 0;
            for (int read; (read = input.Read(buffer)) > 0;)
            {
                copied += read;
                if (copied > size) throw Fail(ZipWriterFailure.Unwritable);
                Write(buffer.AsSpan(0, read));
            }
            if (copied != size) throw Fail(ZipWriterFailure.Unwritable);
            _entries.Add(entry);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw Fail(ZipWriterFailure.Unwritable);
        }
    }

    public void Add(string name, ReadOnlySpan<byte> data)
    {
        var nameBytes = Encoding.UTF8.GetBytes(name);
        Reserve(nameBytes, data.Length);
        var entry = new Entry(nameBytes, Crc32.Checksum(data), (uint)data.Length, (uint)_offset);
        WriteHeader(entry);
        Write(data);
        _entries.Add(entry);
    }

    /// <summary>Fails with <see cref="ZipWriterFailure.TooLarge"/> unless this entry, and the directory and end records after it, fit.</summary>
    void Reserve(byte[] nameBytes, long size)
    {
        var end = _offset + 30 + nameBytes.Length + size;
        var directory = _entries.Sum(e => 46L + e.Name.Length) + 46 + nameBytes.Length;
        if (_entries.Count + 1 >= 0xFFFF || nameBytes.Length > 0xFFFF || end + directory + 22 > _limit)
            throw Fail(ZipWriterFailure.TooLarge);
    }

    void WriteHeader(Entry entry)
    {
        var header = new Bytes();
        header.U32(0x0403_4B50).U16(20).U16(0x0800).U16(0).U16(0).U16(0)
            .U32(entry.Crc).U32(entry.Size).U32(entry.Size)
            .U16((ushort)entry.Name.Length).U16(0).Raw(entry.Name);
        Write(header.ToArray());
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
