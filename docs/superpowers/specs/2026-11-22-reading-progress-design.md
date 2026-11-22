# Reading progress and finished books — design

Show on the shelf how far through each book you are, mark books as finished (automatically, or by hand), and let the shelf filter to what you're reading and what you've finished.

Status: spec, not built yet. Builds on the Collections spec (`2026-11-22-collections-design.md`), which adds the chip row.

## Why

The shelf shows where you are only for the current book: its chapter and time left on the ledge (`CurrentBookShelf`). For every other book you can't tell whether it's untouched, half read or done. There's also no record of what you've finished.

## What's already there

- Each book's reading place (`ReaderLocation`) already has `fraction` (0 to 1 through the book) and `isAtEnd`.
- `LibraryStore.markRead(id:location:)` runs whenever the place changes, and already copies `chapterTitle` and `chapterMinutesLeft` onto `Book` for the shelf. That's the hook for everything below.

## Progress on the shelf

- A thin bar under the cover, not on it, the cover's width, showing how far through the book you are. Covers stay clean.
- Books you haven't opened have no bar. The missing bar is how you tell a new book.
- Finished books show no bar. They get the check badge instead (see below).
- No number under the covers. A percentage under every book is noisy. Hovering a cover shows a tooltip: "42% · Chapter 7".
- On the ledge, the current book's line gains the percentage: "42% · Chapter 7 · 12 min left in chapter".
- Bar colour: the same colour as the reader's place marker and the pin ribbon, at low contrast, so it reads as a detail, not a warning.

## When a book counts as finished

Automatic, with a manual override.

- **Automatic.** A book becomes finished when its place goes from below 95% to 95% or more, or reaches `isAtEnd`, **by turning pages**. Most books end with notes, acknowledgements or an index that nobody reads, so waiting for the last page would leave most books unfinished.
- **Jumps don't count.** Going to the end through the contents, Go to Page, the End key or a link doesn't finish a book. Only turning pages does. The reader knows why the place moved, so it passes that along to `markRead`.
- **Crossing, not being past.** It finishes on the turn that crosses 95%, not on every turn above it. So after Mark as Not Finished, reading on from 97% doesn't finish the book again straight away.
- **By hand.** Right-click → **Mark as Finished** or **Mark as Not Finished**, acting on the multi-selection as Pin does. A mixed selection gets Mark as Finished, which finishes the ones that aren't finished and leaves the existing dates alone.
- Marking by hand never moves the reading place. Mark as Not Finished clears the finished date and nothing else.
- Reopening a finished book, or reading it again from the start, doesn't unmark it. A reread is still a finished book.

## How finished books look

- A small check badge in the bottom-right corner of the cover: a filled circle with a check, in the marker colour. The pin ribbon is at the top, so a pinned, finished book shows both without overlap.
- Finished covers are not faded. Faded covers look disabled, and finished books are often the ones people are proudest of.
- The badge lifts with the cover on hover, as the ribbon does.

## Order on the shelf

- No change to the order. The ledge, then pins, then recency, as today. A book you just finished is your most recently read, so it sits near the front, then drifts back as you read other books.
- Under the Finished chip, books are ordered by when they were finished, newest first.

## Reading and Finished chips

This brings in the "smart collections" the Collections spec left out of scope.

- The chip row gains two built-in chips after **All**: **Reading** (started, not finished) and **Finished**. User collections follow, then **+**.
- Built-in chips can't be renamed, deleted or added to. Their context menu is empty, and they don't appear in Add to Collection.
- The row now appears once there's at least one started book or one collection. So it shows up for most people after their first book, without them having to make a collection.
- A built-in chip with no books is hidden. Someone who has never finished a book doesn't see a Finished chip.
- Search and Esc work as with any other chip.

## Data

- `Book` gets `progress: Double?` (0 to 1, copied from the place in `markRead`) and `finishedAt: Date?`. Both are optional, so `library.json` files from before still load. Nothing is finished and the bars fill in as each book is next opened.
- On first launch after this ships, fill `progress` for every book from its saved place in `PositionStore`, once, so the bars show up straight away instead of only after each book is opened. Don't auto-finish during this backfill: a book left at 98% a year ago might not have been finished.
- `markRead` takes the reason the place moved (page turn or jump) and sets `finishedAt` when the rule above is met and the book isn't finished already.
- `LibraryStore.setFinished(ids:finished:)` for the menu: sets `finishedAt` to now on books that aren't finished, or clears it.
- Removing a book takes its finished date with it, as with pins.

## Export and import

- `book.json` gets `finishedAt` (optional date). An older Readme ignores the key, so `formatVersion` stays 1. Add it to `docs/readmelibrary-format.md`.
- `progress` isn't exported. The bundle's `position.json` already has the place, and import sets `progress` from it, as it already does for the chapter.
- **A new book** keeps the bundle's `finishedAt`.
- **A book already here**: if it's finished here, it stays finished with its own date. If it isn't, it takes the bundle's date. Import never unfinishes a book, which matches the union rule in Collections.

## Accessibility

- A book's VoiceOver label ends with ", 42% read", or ", finished". It joins ", pinned" when both apply.
- Books get a Mark as Finished or Mark as Not Finished action, as they have Pin to Front.
- The progress bar and badge are hidden from VoiceOver, as the label already says it.
- With Reduce Motion, the badge doesn't animate when a book is finished.

## Out of scope

- Reading stats: books per year, time spent, streaks or goals. Possible later, now that `finishedAt` exists.
- Counting rereads or keeping a history of finish dates. One date per book.
- Sorting the shelf by progress.
- A "finished!" moment in the reader on the last page. Worth a look later, but separate from the shelf.

## Tests

- Finish rule: crossing 95% by page turns finishes; a jump past 95% doesn't; reaching `isAtEnd` by page turns finishes; turning pages above 95% after Mark as Not Finished doesn't re-finish; an already-finished book keeps its date.
- `setFinished` on one book, several, and a mixed selection (existing dates unchanged).
- Decoding: a `library.json` without `progress` or `finishedAt`.
- Backfill fills `progress` from saved places and finishes nothing.
- Chips: Reading and Finished contents, ordering under Finished, hidden when empty, combined with search.
- `ShelfSelection` menu titles: one book, several, all finished, mixed.
- Bundle round-trip: a new book keeps `finishedAt`; an existing book gets it only if it isn't finished here; `progress` follows from `position.json`.

## Windows port

- `Readme.Core` first: the fields in `Book.cs`, the finish rule and `setFinished` in `LibraryStore.cs`, the bundle key, and the same tests. The finish rule should live in Core so both apps decide it the same way.
- Then the app: the bar and badge in `BookCoverView.cs`, the menu items, and the built-in chips in `LibraryView.cs`.
- Ship it after Collections, or together with it, since the chips depend on the chip row.

## Open questions

- Is 95% the right threshold? It could be checked against a few real books: where does the main text end in a typical non-fiction EPUB with notes and an index?
