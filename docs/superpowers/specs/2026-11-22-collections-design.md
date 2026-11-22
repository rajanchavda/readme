# Collections — design

Group books into collections, such as Self-Help or Investing, and filter the shelf by them with a row of chips. A book can be in any number of collections, and people make their own.

Status: spec, not built yet.

## Why

The shelf is one list: the current book on the ledge, then pins, then everything by recency (`LibraryStore.others`). Search finds a book you already remember. It doesn't help you browse, as in "what investing books do I have?". As the library grows, it needs grouping.

## Naming

Use **Collections**, not Shelves or Labels.

- The app already calls the whole library "the shelf": `ShelfRow`, `ShelfSearch`, `ShelfSelection`, and pinning moves a book to "the front of the shelf". A shelf called Self-Help would clash with that, in the UI and in the code.
- "Labels" sounds like email. Apple Books calls them Collections, so people already know the word.
- In code the type is `BookCollection`, since Swift's `Collection` is taken.

## Adding books to a collection

- Right-click a book and choose **Add to Collection**. The submenu lists every collection alphabetically, then a separator, then **New Collection…**.
- It acts on the multi-selection, as Pin and Export do (`selection.targets(rightClicked:)`).
- A collection has a checkmark when every targeted book is in it. A mixed selection shows no checkmark.
- Choosing a collection adds all the targeted books when at least one isn't in it yet, and removes all of them when every one already is. This is the same rule Pin uses.
- **New Collection…** opens a small sheet with a name field and suggestions (see Names). **Create** makes the collection and adds the targeted books to it.
- While a collection's chip is active, the context menu also shows **Remove from Self-Help** at the top level, so you don't have to open the submenu.

## The chip row

- A single row above the shelf: **All**, then each collection alphabetically, then **+**.
- The row appears once at least one collection exists. Until then the shelf looks exactly as it does today, and the only way in is right-click → New Collection….
- One chip is active at a time. **All** is the default, and the app always opens on All. A filtered shelf at launch would look like books had gone missing.
- When there are too many chips to fit, the row scrolls sideways. It doesn't wrap.
- Chips show the name only. No counts in v1.
- **+** opens the New Collection sheet with no books, which makes an empty collection.
- Right-click a chip for **Rename…** and **Delete Collection**. Deleting a collection with books asks first: "Delete Self-Help? The 12 books in it stay in your library." Deleting an empty one doesn't ask.
- If the active collection is deleted, the shelf goes back to All.

## Filtering

- With a collection active, the shelf shows only its books, in the usual order. The ledge shows the current book only when it's in the collection; otherwise the ledge is hidden. Then pinned books, then the rest by recency.
- Search works inside the active collection: a book has to be in the collection and match the words.
- Esc first clears the search, as today. With nothing else to clear, it goes back to All (the fallback in `ShelfSearch.escape`).
- An empty collection shows a quiet line in place of books: "No books in Self-Help yet. Right-click a book and choose Add to Collection."
- Books imported or dropped onto the shelf while a collection is active go into that collection too. Otherwise they would vanish from view the moment they were added.

## Names and suggestions

- Leading and trailing spaces are trimmed. An empty name is refused. Names can be up to 40 characters.
- Names are unique, ignoring case and accents, using the same folding as `ShelfSearch`. Typing a name that already exists in New Collection… uses that collection rather than showing an error.
- Under the name field, the sheet offers a few suggestions, leaving out any that already exist: Fiction, Self-Help, Business, Investing, Biography, History, Philosophy, Spirituality, Science. Clicking one fills in the field. Nothing is created until the user presses Create, so a new library never starts with empty collections.

## Data

- A new `collections.json` next to `library.json`: an array of `{ id: UUID, name, createdAt }`. Chips are alphabetical, so there's no order field.
- `Book` gets `collectionIDs: [UUID]`. It decodes as optional, so a missing key means none, and `library.json` files from before this change still load. Keeping membership on the book means removing a book takes its memberships with it, just as with `pinnedAt`.
- Store methods: `createCollection(name:)`, `renameCollection(id:to:)`, `deleteCollection(id:)` (which also strips the ID from every book), and `setCollection(_:member:ids:)` for adding or removing a selection.
- A book that points at a collection ID that no longer exists ignores it, and drops it on the next save.
- `collections.json` is written the same way as `library.json`: whole, atomically, off the main thread.

## Export and import

- `book.json` in a bundle gets `collections: ["Self-Help", "Investing"]`. These are **names**, not IDs, because IDs only mean something in one library. The key is left out when the book is in no collections.
- An older Readme ignores the unknown key, as it did with `pinnedAt`, so `formatVersion` stays 1. Add the key to `docs/readmelibrary-format.md`, since it's the contract for both apps.
- **A new book** joins its collections by name, matched ignoring case and accents. A name with no match creates the collection.
- **A book already here** gains the bundle's collections and never loses its own. This differs from pins, where local state wins. Adding a book to a collection doesn't rearrange the shelf, and a union can't remove anything the user set up.

## Accessibility

- Chips are buttons. The active one has the selected trait, and VoiceOver reads "Self-Help, collection, selected".
- Add to Collection, Rename and Delete live in context menus, which VoiceOver reaches with VO-Shift-M. No extra custom actions in v1.

## Out of scope for v1

- Dragging a book onto a chip.
- Smart collections that fill themselves. The built-in Reading and Finished chips come with the Reading progress spec (`2026-11-22-reading-progress-design.md`).
- Suggesting names from the book's own subjects (`dc:subject`).
- Counts on chips, reordering chips, nested collections and colours.
- Keyboard shortcuts. As with pins, the shelf has no shortcuts yet.
- Showing a book's collections on or under its cover.

## Tests

- Store: create, rename and delete. Deleting strips memberships. A duplicate name (different case or accents) resolves to the existing collection. Name trimming and length.
- Membership on a mixed selection: adds to all; on a selection that's all in, removes from all.
- Decoding: a `library.json` without `collectionIDs`, and a book pointing at an unknown ID.
- Filtering: shelf order with a collection active, with the current book in and out of it, and combined with search.
- A book imported while a collection is active joins it.
- `ShelfSelection` menu titles and checkmark states: one book, several, all in, mixed.
- Bundle round-trip: a new book keeps its collections; an existing book gets the union; names match across case; a bundle without the key imports with no collections.

## Windows port

- `Readme.Core` first: the field in `Book.cs`, the store methods in `LibraryStore.cs`, the bundle key in `LibraryBundle.cs`, and name folding shared with `ShelfSearch.cs`, all with the same tests in `Readme.Core.Tests`.
- Then the app: the chip row in `LibraryView.cs`, the submenu as a flyout with toggle items, and New Collection as a `ContentDialog`.
- The bundle format is shared, so either land both apps in one PR, or add the Windows side to the checklist as a follow-up before the next release.

## Open questions

- Does the chip row share a line with the search field, or sit on its own line beneath it? A quick mockup of both would settle it.
