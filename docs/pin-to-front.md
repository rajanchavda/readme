# Pin to front

A way to keep chosen books at the front of the shelf, so they don't slide down as other books are read.

Status: built on `feat/pin-to-front` (Nov 13, 2026).

## Why

The shelf is ordered only by recency. The current book sits on the top ledge, and every other book follows, last read (or last added) first (`LibraryStore.others`). A book you care about but haven't opened lately drifts towards the bottom, and in a big library it ends up below the fold.

## What it does

- Right-click a book on the shelf and choose **Pin to Front**. It moves to the front of the shelf rows, under the ledge, and gets a small ribbon on its cover.
- Right-click a pinned book and choose **Unpin**. It goes back to its place by recency.
- It works on a multi-selection, as Export does: with several books picked, the item reads **Pin 3 Books to Front**, or **Unpin 3 Books** when every picked book is already pinned. A mixed selection gets the Pin item, which pins the ones that aren't pinned yet.

## Shelf order

1. The top ledge is unchanged. It shows the current book, whether or not that book is pinned. A pinned current book isn't shown a second time in the rows.
2. Then the pinned books, newest pin first, so pinning a book always puts it at the very front. Reading a pinned book doesn't reorder the pins.
3. Then everything else, by recency, as today.

There's no limit on pins. If every book is pinned, the shelf is simply in pin order.

## The ribbon

A narrow cloth tab hanging from the top edge of the cover, near the right corner, in the same colour as the reader's place marker (`MarkerRibbon`). It's drawn over the cover, so it works on real and generated covers alike, and it lifts with the cover on hover.

VoiceOver: a pinned book's label ends with ", pinned", and the book has a Pin to Front or Unpin action.

## Data

- `Book` gets `var pinnedAt: Date?`. It's optional, so `library.json` files written before this change still load, with nothing pinned.
- `LibraryStore` gets `setPinned(ids: [String], pinned: Bool)`. It sets `pinnedAt` to now, or clears it, and saves. Pinning a book that is already pinned leaves its date alone, so a mixed selection doesn't reshuffle the existing pins.
- `others` sorts pinned books first (by `pinnedAt`, newest first), then the rest by `recency`.
- Removing a book takes its pin with it. Nothing extra is needed for that, since the pin lives on the `Book`.

## Export and import

- `BundledBook` gets `var pinnedAt: Date?`. Bundles from older versions load with nothing pinned, and older versions ignore the new key.
- A book the import **adds** keeps the pin it had in the bundle.
- A book **already in the library** keeps its own pin state. Import never pins or unpins it. How the shelf is arranged belongs to this Mac, and a bundle shouldn't rearrange it.

## Out of scope

- Stars or favourites as a separate label. A label only pays off with a filter or collections view, which the app doesn't have.
- Manual drag-to-reorder of the shelf.
- A keyboard shortcut. The shelf has no keyboard focus or shortcuts today, and the shortcuts panel only lists reader commands. If shelf shortcuts come later, add one then, and list it in the panel.

## Tests

- `LibraryStore`: order with no pins, with pins, with the current book pinned, after unpinning, and with a mixed selection pinned (existing pin dates unchanged).
- `Book` decoding: a `library.json` without `pinnedAt` loads with nothing pinned.
- Bundle round-trip: the pin survives export and import for a new book. For a book that's already there, local pin state wins in both directions.
- `ShelfSelection` menu titles: one book, several books, all pinned, mixed.

## Windows port

`Book.cs` and the bundle format need the same field. If this lands before the port's phase 1, port it with `Book.swift` as usual. If it lands after, add it to the checklist as a follow-up.
