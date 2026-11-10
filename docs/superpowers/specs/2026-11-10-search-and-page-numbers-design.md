# Search and Page Numbers: Design

Date: 2026-11-10

Two independent additions to the reader. Search is the larger one. The page number in the corner is small and can be built first.

## Intent

**Search.** The owner uses search to find something they've already read: a line, a name, or a passage they half-remember. They type a few words, see the matches with the words around them, pick one, and land on it. Then they usually stay there and keep reading. Search exists to get them to that passage. It doesn't try to take them back afterwards.

**Page number.** Today the only way to see where you are is ⌘G, which shows "142 of 380" in its empty field. A dim number in the corner of the page, like a printed book's, gives that answer at a glance without adding anything that needs attention.

Both follow the app's test from the main design: interface is what makes a reader feel cluttered. So search is a box that appears when asked for and disappears once used, and the page number is barely there.

## Goals

### Search

- ⌘F opens a small floating box near the top of the book, like Spotlight. The book dims slightly behind it. Add a menu item for it next to Go to Page, following the pattern in `ReaderCommand`.
- Matches appear as the reader types, after a short pause. There's no Search button.
- The whole book is searched, not just the current chapter.
- Matching ignores case and accents, so "cafe" finds "Café".
- Each match shows on one row: the words around it with the match itself picked out, and the page and chapter it's in ("142 · The Letter"). Rows are in book order. A count shows the number of matches ("84 matches").
- A click on a row, or the arrow keys and then Return, closes the box and turns to the spread that holds the match. The matched words get a soft highlight there for about two seconds and then fade, so the eye finds them. That highlight is never saved and never becomes one of the reader's highlights.
- Esc closes the box without moving.
- Pressing ⌘F again opens the box with the last search and its list still there, with the row last picked selected. The reader can then go to the next match without retyping.
- Jumping to a match is an ordinary move, like a jump from the table of contents. The book's saved place follows the reader there.

### Page number

- One dim number per spread, in the bottom outer corner of the right-hand page, at roughly the opacity in the approved mockup (about a third of the text colour).
- The number is the page the spread starts on, the same `ReaderLocation.page` that ⌘G shows and goes to.
- It's always shown while reading. It isn't part of the toolbar, so it doesn't fade with it.
- It belongs to the page. When a page curls over, the number goes with that page and the next page's number comes in with it. It never sits frozen on top of the turning page.

## Decided by the owner

- **No "back to where I was" control.** If the reader wants their current page back later, they mark it with ⌘D before searching and come back with ⇧⌘D. If they forget, the page they were on is gone, and that's accepted. Search never sets, moves or reads the marker.
- **Floating box, not a sidebar.** The approved mockup is `docs/mockups/search-layout.html`, option B.
- **The page number may repeat or skip.** A page is a fixed run of about 1,500 characters of text, not one screen. With large text, one page can last two or three turns. With small text across two columns, a spread can go from 142 to 145. The owner is fine with this.

## Non-goals

- Search options: whole words, match case, regular expressions, or searching only the current chapter.
- Search history across launches. The last search is forgotten when the book closes.
- Searching across the whole library.
- Next and previous match keys that work while the box is closed.
- Changes to the reading marker.
- A page number on the left-hand page, a "of 380" total, or a percentage.

## Anti-goals

- Leaving search marks all over the pages after the box closes. Only the one match the reader picked is marked, and only briefly.
- Search that makes typing feel slow, or that freezes the page while it works through a long book.
- A page number bright or large enough to be read as part of the text.

## Constraints

- Search uses foliate-js's own search (`view.search()` in `Readme/Web/foliate/view.js`). That calls `search.js`, which isn't vendored yet. Bring it in from the same foliate-js commit already recorded in `THIRD_PARTY_NOTICES.md` (78914aef…), so the vendored files stay one consistent version.
- foliate's `view.search()` draws every match on the page as it goes. That clashes with the anti-goal above, so either suppress that drawing or clear it when the box closes. The brief highlight on the picked match is separate from it.
- A row's page number is the page the match itself is on: the same fixed-run-of-text count as `ReaderLocation.page`, worked out from the match's section and its position in it. It doesn't depend on font, window size or columns, so a remembered list never needs recounting. Typing that number into ⌘G lands on or just before the match.
- Everything still has to work with the page curl, all three themes (including sepia), fullscreen, and two-column and one-column layouts.

## My calls (the owner can override)

- **A row shows the match's own page, not the spread's.** After the jump, the corner number shows the page the spread starts on, so it can read a page or two lower than the row did (row says 143, corner says 141). Matching them exactly would mean laying out every chapter at the current settings, which makes search slow. The owner has already accepted that page numbers are approximate.
- **Only the readable flow of the book is searched.** Sections foliate marks as non-linear, such as endnote files, footnote files, the cover, and empty sections, are left out. They have no page number of their own, and page turns skip them, so a jump there would land somewhere the reader can't turn through. A name that appears only in the endnotes won't be found.
- At least 2 characters before searching starts, since one letter matches nearly every page.
- The list stops at 500 matches and says "500+ matches, type more to narrow it down".
- A search typed while an earlier one is still running cancels the earlier one.
- Search stays on the same 2-character minimum and case/accent matching in every language. foliate's matcher uses the book's language for this.
- If nothing matches, the box says "No matches" and stays open.

## Left to the builder

- How the excerpt is cut and how much context it shows, as long as the match is visible in one row.
- How the page for each match is worked out (for example from the match's section and its position in that section, the same way foliate works out locations).
- The exact pause before searching, the box's size and position, the fade timing, and how the box and page number take their colours from each theme.
- Whether the page number is drawn inside the page's web content or in the native page frame, as long as it turns with the curl.
