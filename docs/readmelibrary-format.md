# The `.readmelibrary` format

A `.readmelibrary` file carries books from one Readme to another, Mac or Windows, with what the
reader did in them: highlights, the marker and the reading place. Both apps write and read it, so
this page is the contract between them. Change it only in both apps together, and bump
`formatVersion` when an older Readme could no longer read what a newer one writes.

Written by `LibraryBundle.swift` on Mac and `LibraryBundle.cs` on Windows.

## The file

A zip, with every entry **stored** (method 0, uncompressed): the books are zips already. No ZIP64,
so a whole bundle stays under 4 GB and 65,535 entries. Names are UTF-8 (general purpose flag
`0x0800`). Laid out as:

```
manifest.json
books/<id>/book.json
books/<id>/highlights.json
books/<id>/marker.json      (only if the book has a marker)
books/<id>/position.json    (only if the book has a reading place)
books/<id>/book.epub
```

`<id>` is the book's ID: the SHA-256 of the EPUB file, as 64 lower-case hex digits. It's the same
on both platforms, which is how a book is known to be "already here".

## The JSON

Keys are named exactly as below. Optional fields that have no value are left out, never written as
`null`. Dates are ISO 8601 in whole seconds, UTC, with `Z`: `2026-11-13T09:30:00Z`. The Mac's
decoder refuses fractional seconds, so none are written. A UUID is written in upper case.

**`manifest.json`**

| Key | Type | |
| --- | --- | --- |
| `formatVersion` | integer | `1` |
| `exportedAt` | date | |
| `bookIDs` | array of strings | In the order the books were exported. Note the capital `ID`. |

**`book.json`**: the book as the shelf showed it.

| Key | Type | |
| --- | --- | --- |
| `title` | string | The title the shelf showed, which may not be the file's own |
| `author` | string, optional | |
| `addedAt` | date | |
| `lastReadAt` | date, optional | |
| `pinnedAt` | date, optional | When it was pinned to the front of the shelf. Absent in bundles from before pins |

**`highlights.json`**: an array of highlights, as each app keeps them: `id` (UUID), `cfi`, `text`,
`chapterTitle` (optional), `fraction` (0 to 1), `created` (date). Possibly empty.

**`marker.json`**: `cfi`, `fraction`, `page`, `chapterTitle` (optional), `created` (date).

**`position.json`**: `cfi`, `fraction`, `chapterTitle` (optional), `chapterMinutesLeft`,
`isAtStart`, `isAtEnd`, `page`, `pageCount`, and `isMarked` (optional, false if absent).

The page numbers in a marker or position come from the reading engine's pagination, which differs
between WebKit and Chromium. Treat them as a cache: the CFI is what counts, and the page is right
again once the book is next opened.

## Reading a bundle

A bundle is refused whole, never half read, when:

- it isn't a zip, or has no `manifest.json` that decodes (*"This file isn't a Readme library."*);
- `formatVersion` is newer than the app knows (*"This library was made by a newer Readme. Update
  Readme to import it."*);
- any listed ID isn't 64 lower-case hex digits, or its `book.json` or `book.epub` is missing. IDs are
  checked before one is ever used as a path, so `../` can't escape.

Limits on what's read: 64 MB for each JSON entry, 2 GB for each `book.epub`. A notes file that
can't be read counts as none: no highlights, no marker, no place. A `book.json` that can't be read
fails that book alone.

## Importing

A book already in the library is **never replaced**. When a bundle holds books already here, the app
asks, once for the bundle:

- **Keep Mine** leaves them exactly as they are.
- **Combine** adds the highlights not here yet (a highlight is here if its `id` or its `cfi` is),
  keeps whichever reading place is further along (by `fraction`), keeps this machine's marker if it
  has one and takes the bundle's otherwise, and takes the later of the two last-read dates.
- **Cancel** imports nothing from the bundle.

Each book new here goes through the usual book import, so a book that won't open, or whose file
doesn't hash to its ID, is skipped and counted as failed. It then takes the bundle's title, author,
added and last-read dates, highlights, marker, place and pin. A book already here keeps its own pin
state either way: how a shelf is arranged belongs to that machine.

Importing the same bundle twice changes nothing.

## Exporting

From the shelf, the books chosen (a right-click on one book, or on a selection) or the whole library.
A book whose file has gone is left out and counted. Nothing to export writes no file. A failed
export leaves no partial file behind.

## Golden files

`ReadmeTests/Fixtures/Golden/` holds a bundle written by each app, which both test suites read:
`windows.readmelibrary` (written by Windows) and, still to add, one written by the Mac. If either
app changes the format, the other app's tests fail.
