# Shelf search — design

## Why
Once the library holds hundreds of books, scrolling the shelves to find one stops working. The reader
needs to type a few letters and see the book.

## What it is
- A small magnifier icon, always visible in the shelf's top-right corner (the traffic lights hold the
  top-left, the reader toolbar the top-centre).
- Clicking it, or ⌘F while the shelf is showing, expands it into a text field with a ✕.
- As you type, the shelves filter in place: only matching books stay, in their usual order (pinned
  first, then most recent), re-flowed into rows with `ShelfLayout.rows`. Covers, context menus,
  selection, open-on-click and drag-and-drop work as they do now.
- Esc (or ✕) clears the text and folds the field back to the icon. If the field is already empty, Esc
  falls through to what it does today (putting the selection down).

## Decisions (agreed)
- Expanding icon, not an always-open field: the shelf stays quiet until you want it.
- Filter the shelf in place, not a separate results list.

## Calls I made (correct me)
- **Matches** title and author, case- and accent-insensitive, anywhere in the text ("gar" finds
  "Garamond", "tolstoy" finds "Leo Tolstoy"). Every word typed must match somewhere ("dune herbert").
- **Current-book shelf:** shown when the current book matches, hidden when it doesn't, so the results
  start at the top.
- **No matches:** the shelves stay, empty, with a quiet italic line, "No books match "xyz"", in the
  shelf's own type.
- **Not remembered:** the search is cleared when you open a book, so the shelf is whole when you come
  back.
- **Shortcuts:** ⌘F (and Esc) on the shelf go in the ? shortcuts panel.
- **Return** in the field opens the book when exactly one matches.

## Non-goals
- Searching inside book text, tags, collections or sort options.
- Fuzzy or typo-tolerant matching.
- The Windows port (comes later through its own checklist).

## Approaches considered
- **Results placement:** filter in place (picked: reuses the shelf as is); a Spotlight-style list
  (keyboard-fast, but a new kind of view that doesn't look like the shelf); both (more work, little
  gain for now).
- **Entry point:** expanding top-right icon (picked); always-open field (always visible, but
  clutters the shelf).

## Left to the builder
- Filtering lives beside `LibraryStore.others` (a pure function of books + query, unit-tested).
- Routing ⌘F to the shelf when the library is showing (the reader already maps ⌘F to `.find`), and
  Esc ahead of `onLibraryEscape`.
- Field styling to match `ShelfStyle` (dark, the shelf's serif); animation respects Reduce Motion.
