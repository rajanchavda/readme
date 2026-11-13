using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Readme.Core.Storage;

/// <summary>
/// The JSON the Mac app reads and writes, which these files must match. Swift's <c>JSONEncoder</c>
/// leaves out nil optionals rather than writing null, and names keys as the properties are named.
/// How dates are written differs from file to file: see each option set.
/// </summary>
public static class Json
{
    /// <summary>
    /// <c>library.json</c> and the saved places. Their dates use JSONEncoder's default strategy: a
    /// number of seconds since 1 January 2001 UTC, Apple's reference date.
    /// </summary>
    public static readonly JsonSerializerOptions Library = Make(new ReferenceDateConverter());

    /// <summary>
    /// Highlights, markers and library bundles, which the Mac writes with the <c>.iso8601</c> date
    /// strategy: whole seconds, UTC, "Z". Its decoder rejects fractional seconds, so none are written.
    /// </summary>
    public static readonly JsonSerializerOptions Iso = Make(new Iso8601SecondsConverter());

    static JsonSerializerOptions Make(JsonConverter dates)
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            // Swift writes non-ASCII text as it is, not as \u escapes.
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        };
        options.Converters.Add(dates);
        options.Converters.Add(new UppercaseGuidConverter());
        options.MakeReadOnly(populateMissingResolver: true);
        return options;
    }
}

/// <summary>Seconds since 2001-01-01T00:00:00Z, as a JSON number.</summary>
public sealed class ReferenceDateConverter : JsonConverter<DateTimeOffset>
{
    public static readonly DateTimeOffset ReferenceDate = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        FromSeconds(reader.GetDouble());

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(ToSeconds(value));

    /// <summary>
    /// Rounded to the microsecond. Swift's Date is itself a double, so it survives the file exactly;
    /// a .NET date has 100 ns ticks, which a double this far from 2001 can't hold. A microsecond it can,
    /// so a date kept at that precision (see <see cref="Normalize"/>) reads back as it was saved.
    /// </summary>
    public static DateTimeOffset FromSeconds(double seconds)
    {
        // Whole seconds and the fraction apart: seconds * 1e6 itself would be too large for a double
        // to hold to the microsecond.
        var whole = Math.Floor(seconds);
        var microseconds = (long)whole * 1_000_000 + (long)Math.Round((seconds - whole) * 1_000_000);
        return ReferenceDate.AddTicks(microseconds * (TimeSpan.TicksPerSecond / 1_000_000));
    }

    /// <summary>The date as it will read back from the file.</summary>
    public static DateTimeOffset Normalize(DateTimeOffset value) => FromSeconds(ToSeconds(value));

    public static double ToSeconds(DateTimeOffset value) =>
        (double)(value.UtcTicks - ReferenceDate.UtcTicks) / TimeSpan.TicksPerSecond;
}

/// <summary>ISO 8601 in whole seconds, UTC: <c>2026-11-13T09:30:00Z</c>.</summary>
public sealed class Iso8601SecondsConverter : JsonConverter<DateTimeOffset>
{
    static readonly string[] Formats = ["yyyy-MM-dd'T'HH:mm:ssK", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK"];

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var text = reader.GetString() ?? throw new JsonException("A date can't be null");
        if (!DateTimeOffset.TryParseExact(text, Formats, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var value))
            throw new JsonException($"Not an ISO 8601 date: {text}");
        return value;
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteStringValue(Truncate(value).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));

    /// <summary>The time in whole seconds, UTC, as the file keeps it.</summary>
    public static DateTimeOffset Truncate(DateTimeOffset value) =>
        new(value.UtcTicks - value.UtcTicks % TimeSpan.TicksPerSecond, TimeSpan.Zero);
}

/// <summary>Swift writes a UUID in upper case, where C# would write lower.</summary>
public sealed class UppercaseGuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        Guid.Parse(reader.GetString() ?? throw new JsonException("A UUID can't be null"));

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}
