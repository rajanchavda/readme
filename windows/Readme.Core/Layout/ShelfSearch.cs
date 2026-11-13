using System.Globalization;
using System.Text;
using Readme.Core.Model;

namespace Readme.Core.Layout;

/// <summary>
/// What's typed into the shelf's search field, whether the field is open, and which books it finds
/// (ShelfSearch.swift). The UI binds to it; the matching is static and pure.
/// </summary>
public sealed class ShelfSearch
{
    public string Query { get; set; } = "";
    public bool IsOpen { get; private set; }
    /// <summary>Goes up each time the field is asked to take the keyboard.</summary>
    public int FocusRequest { get; private set; }

    /// <summary>Whether anything is being looked for: spaces alone aren't.</summary>
    public bool IsActive => Words(Query).Count > 0;

    /// <summary>Opens the field and puts the keyboard in it.</summary>
    public void Open()
    {
        IsOpen = true;
        FocusRequest++;
    }

    /// <summary>Empties the field and folds it back to its icon.</summary>
    public void Close()
    {
        Query = "";
        IsOpen = false;
    }

    /// <summary>Esc over the shelf: clears and folds a search that's open, and otherwise does <paramref name="fallback"/>.</summary>
    public static void Escape(ShelfSearch search, Action fallback)
    {
        if (search.IsOpen || search.IsActive) search.Close();
        else fallback();
    }

    /// <summary>Whether every word typed is somewhere in the title or author, whatever the case and accents.</summary>
    public static bool Matches(Book book, string query)
    {
        var words = Words(query);
        if (words.Count == 0) return true;
        var text = Fold(book.Title + " " + (book.Author ?? ""));
        return words.All(word => text.Contains(word, StringComparison.Ordinal));
    }

    /// <summary>The books that match, in the order they came.</summary>
    public static IReadOnlyList<Book> Filter(IEnumerable<Book> books, string query) =>
        Words(query).Count == 0 ? books.ToList() : books.Where(b => Matches(b, query)).ToList();

    static List<string> Words(string query) =>
        query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Select(Fold).ToList();

    /// <summary>
    /// Case and diacritics folded, as Foundation's <c>folding(options: [.caseInsensitive,
    /// .diacriticInsensitive])</c>: decomposed, combining marks dropped, lower-cased. Letters with no
    /// decomposition, such as ø or ß, are left as they are; the Mac may fold some of those further.
    /// </summary>
    static string Fold(string text)
    {
        var decomposed = text.Normalize(NormalizationForm.FormD);
        var folded = new StringBuilder(decomposed.Length);
        foreach (var c in decomposed)
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) folded.Append(c);
        return folded.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant();
    }
}
