using System.Text.Json;
using System.Text.Json.Serialization;
using Readme.Core.Layout;
using Readme.Core.Storage;

namespace Readme.Core.Reader;

public enum ThemeChoice { Auto, Paper, Sepia, Night }

public enum Theme { Paper, Sepia, Night }

/// <summary>
/// How the reader likes the book set (ReaderSettings.swift), kept in <c>settings.json</c> in the app's
/// data folder. Windows-only file: the Mac keeps these in UserDefaults, and its font list differs.
/// </summary>
public sealed record ReaderSettings
{
    public ThemeChoice Theme { get; init; } = ThemeChoice.Auto;
    public BookFont Font { get; init; } = BookFont.EbGaramond;
    public double FontSize { get; init; } = 18;
    public LineWidth LineWidth { get; init; } = LineWidth.Regular;

    static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
        WriteIndented = true,
    };

    /// <summary>What was saved, or the defaults if nothing was or it can't be read.</summary>
    public static ReaderSettings Load(string path) => Files.ReadJson<ReaderSettings>(path, Options) ?? new();

    public void Save(string path) => Files.WriteJson(path, this, Options);

    public Theme ResolvedTheme(bool systemIsDark) => Theme switch
    {
        ThemeChoice.Auto => systemIsDark ? Reader.Theme.Night : Reader.Theme.Paper,
        ThemeChoice.Paper => Reader.Theme.Paper,
        ThemeChoice.Sepia => Reader.Theme.Sepia,
        ThemeChoice.Night => Reader.Theme.Night,
        _ => Reader.Theme.Paper,
    };
}
