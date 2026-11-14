using System.Text;
using System.Text.Json;

namespace Readme.Core.Storage;

/// <summary>File helpers shared by the stores.</summary>
public static class Files
{
    /// <summary>
    /// Writes the whole file at once: to a temporary file beside it, then moved over it, so a reader
    /// (the app, OneDrive, a backup tool) sees the old file or the new one, never half of one.
    /// </summary>
    public static void WriteAtomically(string path, ReadOnlySpan<byte> bytes)
    {
        var folder = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(folder);
        var temporary = Path.Combine(folder, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    public static void WriteJson<T>(string path, T value, JsonSerializerOptions options) =>
        WriteAtomically(path, JsonSerializer.SerializeToUtf8Bytes(value, options));

    /// <summary>The value in the file, or the default for one that's missing or can't be read.</summary>
    public static T? ReadJson<T>(string path, JsonSerializerOptions options)
    {
        try
        {
            if (!File.Exists(path)) return default;
            return JsonSerializer.Deserialize<T>(File.ReadAllBytes(path), options);
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException or NotSupportedException)
        {
            return default;
        }
    }

    /// <summary>
    /// A book ID as a file name: anything but ASCII letters, digits, <c>-</c> and <c>_</c> is
    /// percent-encoded (UTF-8, upper-case hex), as Swift's <c>addingPercentEncoding</c> does, so every
    /// ID gets a file of its own and none can leave the folder. Windows file names ignore case, so two
    /// IDs differing only in case would share a file; real IDs are lower-case hex.
    /// </summary>
    public static string SafeName(string id)
    {
        var name = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(id))
        {
            var c = (char)b;
            if (c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-' or '_') name.Append(c);
            else name.Append('%').Append(b.ToString("X2"));
        }
        return name.ToString();
    }

    public static void DeleteIfPresent(string path)
    {
        try { File.Delete(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
