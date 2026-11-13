using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Readme.App.Library;

/// <summary>Covers as the library keeps and shows them (CoverImage and CoverImages in the Mac app).</summary>
static class CoverImages
{
    /// <summary>The longest side kept, in pixels: room for a large display, and a small library.</summary>
    public const int MaxSide = 1200;

    /// <summary>The image as PNG, scaled down to <see cref="MaxSide"/> if larger. Null if it isn't an image.</summary>
    public static async Task<byte[]?> PngAsync(byte[] data)
    {
        try
        {
            using var input = new InMemoryRandomAccessStream();
            await input.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(data));
            input.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(input);
            var (width, height) = (decoder.OrientedPixelWidth, decoder.OrientedPixelHeight);
            var scale = Math.Min(1, (double)MaxSide / Math.Max(width, height));
            var transform = new BitmapTransform
            {
                ScaledWidth = (uint)Math.Max(1, Math.Round(width * scale)),
                ScaledHeight = (uint)Math.Max(1, Math.Round(height * scale)),
                InterpolationMode = BitmapInterpolationMode.Fant,
            };
            var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform,
                ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
            using var output = new InMemoryRandomAccessStream();
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform.ScaledWidth, transform.ScaledHeight, 96, 96, pixels.DetachPixelData());
            await encoder.FlushAsync();
            var bytes = new byte[output.Size];
            output.Seek(0);
            using var reader = new DataReader(output);
            await reader.LoadAsync((uint)output.Size);
            reader.ReadBytes(bytes);
            return bytes;
        }
        catch (Exception error) when (error is System.Runtime.InteropServices.COMException or ArgumentException or InvalidOperationException or OverflowException)
        {
            return null;
        }
    }

    static readonly Dictionary<string, ImageSource> Cache = [];

    /// <summary>
    /// A book's cover file, decoded at the width it's shown, and kept so a shelf rebuilt or scrolled
    /// doesn't decode it again. Null if the file is missing or isn't an image.
    /// </summary>
    public static async Task<ImageSource?> LoadAsync(string path, int pixelWidth)
    {
        var key = $"{path}|{pixelWidth}|{(File.Exists(path) ? File.GetLastWriteTimeUtc(path).Ticks : 0)}";
        if (Cache.TryGetValue(key, out var cached)) return cached;
        if (!File.Exists(path)) return null;
        try
        {
            var image = new BitmapImage { DecodePixelWidth = pixelWidth, DecodePixelType = DecodePixelType.Physical };
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read).AsRandomAccessStream();
            await image.SetSourceAsync(stream);
            if (image.PixelWidth == 0) return null;
            Cache[key] = image;
            return image;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            return null;
        }
    }
}
