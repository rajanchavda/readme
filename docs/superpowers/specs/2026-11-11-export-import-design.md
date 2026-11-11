# Export and Import: Design

Date: 2026-11-11

## Intent

The owner wants to take their books to another Mac and find everything they've done in them on arrival: the highlights, the page marker, and the place they stopped. Two cases come up. One is moving the whole library to a new Mac in one go. The other is sending one or two books, with their notes, to a second machine. Both have to work.

Readme has no accounts and no sync, and that stays true. This feature is a file you carry over yourself.

What matters most is that importing can never cost the owner anything. A book that's already on the receiving Mac is never replaced. When the import and the receiving Mac both have the same book, Readme asks the owner what to do instead of choosing for them.

## Goals

### The bundle

- An export is one file with its own extension, `.readmelibrary`. It survives AirDrop, email and a USB stick, and Finder shows it as a document, not a folder.
- Double-clicking it, or opening it with Readme, starts an import, the same way opening an EPUB adds a book now.
- For each book, the bundle holds:
  - the `.epub` (the library's own copy, byte for byte, so its SHA-256 and therefore its ID are unchanged)
  - the title and author shown on the shelf, and `addedAt`, from `Book`. A new imported book keeps its original `addedAt`, so the shelf order carries over. (*My call*, from the builder check.)
  - its highlights (`[Highlight]`)
  - its page marker (`Marker`), if it has one
  - its reading position (`ReaderLocation`), if it has one, and when it was last read (`lastReadAt`)
- The bundle records its own format version, so a later Readme can tell an older bundle from a newer one. A bundle from a newer, unknown version is refused with a plain message instead of being half read.

### Exporting

- **File > Export Library…** exports every book on the shelf.
- On the shelf, selecting one or more books and choosing **Export…** from the right-click menu exports just those. The shelf has no selection today: each book is a plain button that opens it (`ShelfRow.swift`). Adding selection is part of this work, as the owner decided:
  - A plain click still opens a book, as it always has.
  - ⌘-click toggles a book in or out of the selection. Shift-click extends it. The large "current" book can be selected too.
  - Selected books show a quiet selection ring (the accent color, like Finder). Clicking empty shelf space, pressing Esc or opening a book clears the selection.
  - Right-clicking a selected book offers **Export N Books…**. Right-clicking a book that isn't selected offers **Export…** for that book alone.
  - There's no selection mode and no extra controls.
- Both open a save panel. The suggested name is `Readme Library.readmelibrary` for the whole library, and the book's title for a single book.
- Exporting an empty library is impossible: the menu item is disabled when the shelf is empty.
- A book whose copy has gone missing from disk is left out, and the end message says so.
- When the export is done, a quiet notice confirms it ("Exported 12 books"). While a large export runs, the shelf shows progress the way it does for adding books.

### Importing

- **File > Import…** opens a file panel for `.readmelibrary` files. Dropping one on the shelf or the Dock icon does the same. Existing EPUB opening and dropping keep working unchanged.
- Each book in the bundle is checked the way a dropped EPUB is now (`EPUBInspector`). A bad book is skipped and counted as a failure. The rest still come in.
- **A book that isn't on this Mac** comes in with everything: the file, its cover (drawn or extracted the same way a normal import does), its highlights, its marker, its position and its last-read date.
- **A book already on this Mac** (same ID, meaning the same file) is never replaced. If the bundle holds any such books, Readme asks one question for the whole import, before changing anything, naming how many books are affected:
  - **Keep Mine:** those books stay exactly as they are. Nothing from the bundle touches them.
  - **Combine:** for each of those books:
    - highlights from the bundle that this Mac doesn't already have are added. Two highlights are the same if they have the same `id`, or failing that the same `cfi`. Nothing already here is removed or changed.
    - the reading position that's further into the book (higher `fraction`) is kept, and `lastReadAt` becomes the later of the two
    - this Mac's page marker is kept if it has one. If it doesn't, the bundle's marker is used.
  - **Cancel:** nothing is imported at all, not even the new books.
- If every book in the bundle is new, the question isn't asked.
- At the end, a short notice gives the counts, for example "Added 4 books, combined 2, 1 couldn't be read". Zero counts are left out.
- Importing the same bundle twice does nothing harmful. The second time every book already exists, and Combine adds nothing new.
- If the book that's open in the reader (it stays loaded behind the shelf) gets combined:
  - The open reader reloads that book's highlights and marker.
  - If the reading position moved further along, the reader moves to the new place.
  - The open reader must never write its old place, highlights or marker over what the import just saved. Today `PlaceWriter`, `markRead` and `prepareToQuit`'s `keepPlace()` all write the reader's in-memory place, so this needs handling. (*My call*, from the builder check.)
- Combine can bring back a highlight or marker the owner deleted on this Mac after the bundle was made, because nothing records deletions. **The owner accepted this.** No record of deletions is added.

## Non-goals

- Reader settings (typeface, text size, line width, theme) aren't exported. They belong to the Mac, not to the books.
- No syncing, no iCloud, no network. Nothing is uploaded.
- No export to other apps' formats (Apple Books, Kindle, Markdown notes). This bundle is for Readme to Readme.
- No choosing per book in the import question. It's one answer for the whole import.
- A different edition or a re-downloaded file of the same title counts as a different book, because a book is identified by the SHA-256 of its file. Matching books by title is out of scope.

## Anti-goals

These would make it a failure even if it worked:

- Losing or overwriting anything on the receiving Mac: a book, a highlight, a marker or a further-along position.
- An import that fails halfway and leaves the library in a state the owner can't explain, such as a book on the shelf with no file, or `library.json` disagreeing with the files.
- A bundle that holds anything beyond the books and what the owner did in them: no settings, no paths from the exporting Mac, nothing identifying the machine.
- Interface clutter. This is two menu items, one right-click item, one question and a quiet notice. It needs no new window or preferences pane.

## Constraints

- macOS 14+, Swift 6, sandboxed, SwiftUI with AppKit where the app already uses it. The project is generated with XcodeGen from `project.yml`.
- The app has only `com.apple.security.files.user-selected.read-only` today. Saving an export needs `com.apple.security.files.user-selected.read-write`.
- The new document type is declared in `project.yml` (`CFBundleDocumentTypes`, plus an exported `UTExportedTypeDeclarations` entry for the `.readmelibrary` type, conforming to `public.data` and `public.archive`, under the identifier `com.rajanchavda.Readme.library`).
- No third-party dependencies are added.
- Existing stores keep their files and formats: `library.json`, `Books/`, `Covers/`, `Highlights/`, `Markers/` and `Positions/`. Import goes through `LibraryStore`, `HighlightStore`, `MarkerStore` and `PositionStore`, not around them, so their write ordering and the open reader stay consistent.
- Tests follow the existing XCTest style in `ReadmeTests/`, with fixtures in `ReadmeTests/Fixtures/`.

## Decisions made in conversation

- Both whole-library and selected-book export are supported.
- When a book is already there, the owner is asked, with Keep Mine or Combine as the options.
- Importing never replaces a book file that's already in the library.
- Selecting books on the shelf: a plain click opens a book, ⌘-click or Shift-click selects, and right-clicking exports.
- It's acceptable for Combine to bring back highlights or a marker deleted since the bundle was made.

## Calls I made (the owner can overrule these)

- One file with its own extension, rather than a folder.
- One question per import, not one per book, plus a Cancel option.
- Combine keeps this Mac's marker when there is one.
- Settings are left out.
- **Container format:** a standard zip with *stored* (uncompressed) entries. EPUBs are already compressed, so compression gains little, and the app already has a zip reader (`ZipArchive` in `EPUBInspector.swift`) that handles stored entries. A small stored-only zip writer is all that's new. Layout:

  ```
  manifest.json                  format version, export date, list of book IDs
  books/<id>/book.epub
  books/<id>/book.json           title, author, addedAt, lastReadAt
  books/<id>/highlights.json     [Highlight]
  books/<id>/marker.json         Marker (absent if none)
  books/<id>/position.json       ReaderLocation (absent if none)
  ```

  Covers aren't exported. They're rebuilt on import exactly as for a dropped EPUB.

## Left to the builder

- Whether the zip writer and reader need ZIP64. Without it, a bundle is limited to 4 GB, which is roughly a thousand typical EPUBs. If the builder leaves ZIP64 out, an export over the limit must fail cleanly with a message, never produce a broken file.
- How import is staged so that a failure partway leaves no half-imported book. One example is extracting to a temporary folder inside the library directory, then adding books one at a time through the normal import path.
- Exact notice wording and how the question is presented (an `NSAlert` sheet on the library window is the obvious fit).
- How exports and imports are split into files and types, as long as it follows the existing layout (`Readme/Library/` for store-level code, `Readme/App/` for menu wiring).
