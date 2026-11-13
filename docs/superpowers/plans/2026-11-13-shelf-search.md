# Shelf Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A magnifier icon in the shelf's top-right corner that expands into a search field and filters the shelves in place by title and author.

**Architecture:** A small `ShelfSearch` observable object holds the query and whether the field is open, plus a pure matching function. `LibraryView` draws the icon/field overlay and filters `library.current` / `library.others` through it before laying out rows. `AppCoordinator` owns the one `ShelfSearch`, routes ⌘F and Esc to it while the library shows, and clears it when a book opens.

**Tech Stack:** Swift, SwiftUI hosted in AppKit, Swift Testing (`@Test`, `#expect`), XcodeGen; tests via `scripts/test.sh [Suite]`.

**Spec:** `docs/superpowers/specs/2026-11-13-shelf-search-design.md`

## Global Constraints

- Matching: title and author, case- and accent-insensitive, substring; every whitespace-separated word must match somewhere.
- Current-book shelf shown only when the current book matches (or the query is empty).
- No matches: one quiet italic line `No books match "<query>"` in `ShelfStyle.body(16, italic: true)`, `ShelfStyle.text`.
- Search clears (text emptied, field folded) when a book opens.
- ⌘F opens/focuses the field over the library; Esc clears and folds it; Esc on an already-closed field does what it does today (`selection.clear()`).
- Return in the field opens the book when exactly one matches.
- ⌘F and Esc for the shelf are listed in the `?` shortcuts panel.
- Animations respect Reduce Motion (the view already has `reduceMotion`).
- No `gh` CLI; plain `git` only. Work on branch `feat/shelf-search`.

## Review Focus

1. **Query of only spaces** — treated as empty: every book shows, no "No books match" line. Test in Task 1.
2. **Book with no author** (`author == nil`) — matches on title alone and never crashes. Test in Task 1.
3. **A book added or removed while a query is active** — the filtered shelf updates (it's derived from `library.books`, not cached). Test in Task 1 (`filter` is pure over its input).
4. **Typing in the field while the reader's key monitor is active** — letters like `f`, `?`, Space must type, not trigger full screen/shortcuts. The monitor already bails out when `isShowingLibrary`; verify by hand in Task 3.
5. **Esc while the field has focus** — the window's key monitor sees Esc before the text field, so it must reach `ShelfSearch.close()` via `onLibraryEscape`. Test in Task 3.

---

### Task 0: Branch and spec

- [ ] **Step 1:** `git switch -c feat/shelf-search`
- [ ] **Step 2:** `git add docs/superpowers/specs/2026-11-13-shelf-search-design.md docs/superpowers/plans/2026-11-13-shelf-search.md && git commit -m "docs: shelf search design and plan"`

### Task 1: Matching and search state

**Files:**
- Create: `Readme/Library/ShelfSearch.swift`
- Test: `ReadmeTests/ShelfSearchTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor final class ShelfSearch: ObservableObject`
    - `@Published var query: String = ""`
    - `@Published var isOpen: Bool = false`
    - `@Published var focusRequest: Int = 0` (bumped to ask the field to take focus)
    - `var isActive: Bool` — true when `query` has any non-whitespace character
    - `func open()` — sets `isOpen = true`, bumps `focusRequest`
    - `func close()` — `query = ""`, `isOpen = false`
    - `nonisolated static func matches(_ book: Book, query: String) -> Bool`
    - `nonisolated static func filter(_ books: [Book], query: String) -> [Book]` (keeps order)

- [ ] **Step 1: Write the failing tests** in `ReadmeTests/ShelfSearchTests.swift` (`@Suite struct ShelfSearchTests`), building `Book`s like `LibraryStoreTests.book(...)` but with title/author:
  - `matchesTitleIgnoringCaseAndAccents`: title "Les Misérables" matches "miserables", "MISÉR", "les mis".
  - `matchesAuthor`: title "Anna Karenina", author "Leo Tolstoy" matches "tolstoy".
  - `everyWordMustMatch`: "Dune" by "Frank Herbert" matches "dune herbert"; not "dune asimov".
  - `noAuthorMatchesOnTitle`: author nil, title "Emma" matches "emm", not "austen".
  - `blankQueryMatchesEverything`: `filter(books, query: "   ")` returns all books, same order.
  - `filterKeepsOrder`: books [c "Dune", a "Dune Messiah", b "Emma"], query "dune" → ids ["c", "a"].
  - `@MainActor closeClearsAndFolds`: after `open()`, query "x", `close()` → `query == ""`, `isOpen == false`; `open()` increments `focusRequest`.
  - `isActiveIgnoresWhitespace`: query "  " → false; " a " → true.

- [ ] **Step 2:** Run `scripts/test.sh ShelfSearchTests` — expected: build failure, `ShelfSearch` not found.

- [ ] **Step 3: Implement `ShelfSearch`** in `Readme/Library/ShelfSearch.swift`. Fold with `folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)` on both the haystack (`title + " " + (author ?? "")`) and each query word; split the query on `.whitespaces`, dropping empties. Doc comments in the project's voice (plain sentences, what not how).

- [ ] **Step 4:** Run `scripts/test.sh ShelfSearchTests` — expected: all pass.

- [ ] **Step 5:** `git add Readme/Library/ShelfSearch.swift ReadmeTests/ShelfSearchTests.swift && git commit -m "feat: match books on the shelf by title and author"`

### Task 2: Filtered shelves and the search field

**Files:**
- Create: `Readme/Library/ShelfSearchField.swift`
- Modify: `Readme/Library/LibraryView.swift` (inits ~19–49, `body` overlays, `Shelves`)

**Interfaces:**
- Consumes: `ShelfSearch` (Task 1).
- Produces:
  - `LibraryView` gains `@ObservedObject var search: ShelfSearch`, passed through the `drops:` init as `search: ShelfSearch = ShelfSearch()` (default keeps existing callers/previews compiling). The other two inits create their own.
  - `struct ShelfSearchField: View { @ObservedObject var search: ShelfSearch; let onSubmit: () -> Void }`

- [ ] **Step 1: `ShelfSearchField`.** Closed: a `magnifyingglass` button (plain style, `ShelfStyle.soft`, ~15pt, `.help("Search the library")`, accessibility label "Search"). Open: an HStack of the glyph, a `TextField("Title or author", text: $search.query)` (`.textFieldStyle(.plain)`, `ShelfStyle.body(15)`, `ShelfStyle.text`), and an `xmark.circle.fill` button calling `search.close()` when the query isn't empty; ~220pt wide, padded, on a capsule of the `NoticeView` brown (`0x24 1F 1A`) with the same 0.1 `ShelfStyle.text` stroke. `@FocusState` is set true whenever `focusRequest` changes and on appear-when-open. `.onSubmit(onSubmit)`. When focus is lost and the query is blank, fold (`isOpen = false`). The width change animates with `ShelfStyle.lift`, or not at all under Reduce Motion.

- [ ] **Step 2: Place it** in `LibraryView.body` as `.overlay(alignment: .topTrailing)` with `.padding(.top, 14).padding(.trailing, 20)`, above the drop-target border overlay so it stays clickable.

- [ ] **Step 3: Filter `Shelves`.** Give `Shelves` a `query: String`. Use `ShelfSearch.filter(library.others, query:)` for `rows`; show `CurrentBookShelf` only when `library.current` is nil-safe and `query` is blank or `ShelfSearch.matches(current, query:)`. When the query is blank, pass `library.current` exactly as today (an empty current shelf still shows as it does now). Include the filtered ids in the existing `.animation(..., value:)` key so books glide out and in.

- [ ] **Step 4: No matches line.** When `search.isActive` and both the filtered current and others are empty, show `No books match "\(trimmed query)"` centred under the field (`.padding(.top, 80)` overlay, `.allowsHitTesting(false)`), using the constraint's font and colour.

- [ ] **Step 5: Return opens.** `onSubmit`: compute the matched list (current if matching, then filtered others); if exactly one, call `onOpen(book)`.

- [ ] **Step 6:** Build and run the whole suite: `scripts/test.sh` — expected: `exit status 0`.

- [ ] **Step 7:** `git add Readme/Library/ShelfSearchField.swift Readme/Library/LibraryView.swift && git commit -m "feat: search box that filters the shelf"`

### Task 3: Keys, clearing on open, and the shortcuts panel

**Files:**
- Modify: `Readme/App/AppCoordinator.swift` (around 116–136)
- Modify: `Readme/Reader/ReaderWindowController.swift` (`onLibraryEscape` at 37; the key monitor's library branch at ~1030)
- Modify: `Readme/Reader/ShortcutsHelp.swift` (columns)
- Test: `ReadmeTests/ShortcutsHelpTests.swift`, `ReadmeTests/ShelfSearchTests.swift`

**Interfaces:**
- Consumes: `ShelfSearch.open()`, `close()`, `isOpen` (Task 1); `LibraryView(search:)` (Task 2).
- Produces:
  - `ReaderWindowController.onLibraryFind: (() -> Void)?`
  - `@MainActor static func ShelfSearch.escape(_ search: ShelfSearch, else fallback: () -> Void)` — closes the search if `isOpen || isActive`, otherwise calls `fallback`.

- [ ] **Step 1: Failing tests.**
  - In `ShelfSearchTests`: `@MainActor escapeClosesOpenSearchFirst` — open search with query "a": `escape` closes it and does not call the fallback; a second `escape` calls the fallback once.
  - In `ShortcutsHelpTests`: `libraryKeysAreListed` — the sections contain a section titled `"Library"` whose rows are exactly `Row(keys: ["⌘F"], description: "Search the library")` and `Row(keys: ["Esc"], description: "Clear the search")`. (`everyCommandIsListedOnce` still passes because these are plain rows, not `row(.find)`.)

- [ ] **Step 2:** Run `scripts/test.sh ShelfSearchTests` and `scripts/test.sh ShortcutsHelpTests` — expected: fail (missing `escape`, missing section).

- [ ] **Step 3: `ShelfSearch.escape`** in `ShelfSearch.swift`.

- [ ] **Step 4: Shortcuts panel.** Add `Section(title: "Library", rows: [...])` with the two rows above as the last section of the right column in `ShortcutsHelp.columns`. If `ShortcutsPanel`'s fixed height no longer fits, raise its height constant just enough (check `panelShowsEveryRowsKeys` and by eye).

- [ ] **Step 5: Key routing.**
  - `ReaderWindowController`: add `var onLibraryFind: (() -> Void)?`. In the key monitor's `else` branch, beside the existing library-Esc case, handle ⌘F over the library (`charactersIgnoringModifiers == "f"`, modifiers ∩ `KeyShortcut.relevantModifiers == [.command]`, `event.window === window`, no sheet): call `onLibraryFind` and return true.
  - `AppCoordinator`: own `let search = ShelfSearch()`; pass it to `LibraryView(..., search: search)`; `reader.onLibraryFind = { [weak self] in self?.search.open() }`; change `onLibraryEscape` to `ShelfSearch.escape(search) { selection.clear() }`; in the `onOpen` closure call `search.close()` before opening.

- [ ] **Step 6:** Run `scripts/test.sh` — expected: `exit status 0`.

- [ ] **Step 7: Check by hand** (`/run` or build and launch): with a few books, ⌘F opens the field focused; typing `f`, `?` and Space types into it (no full screen, no panel); Esc with text clears and folds; Esc again puts down a selection; Return with one match opens it; returning to the library (⌘L) shows the whole shelf; the menu's Find stays disabled over the library and ⌘F still works.

- [ ] **Step 8:** `git add -A Readme ReadmeTests && git commit -m "feat: ⌘F and Esc for shelf search, listed in shortcuts"`

### Task 4: README

- [ ] **Step 1:** In `README.md` Features, extend the **Library shelf** bullet with one sentence: search the shelf by title or author from the magnifier in the corner, or ⌘F.
- [ ] **Step 2:** `git commit -am "docs: mention shelf search"`
