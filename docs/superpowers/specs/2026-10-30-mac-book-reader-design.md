# Minimal Mac Book Reader: Design

Date: 2026-10-30
Working name: Readme (the project folder's name, not a final decision)

## Intent

A Mac reader for EPUB books that feels like reading a real book and asks nothing of the reader.

The owner's experience of existing readers: they look boring, carry too many features, and invite distraction. So two things have to be true at once. The app has to get out of the way, and it has to be a pleasure to look at. Calm on its own is not enough, because a plain minimal app is just another boring app.

**Who it's for:** genuine book readers and aspiring readers. Aspiring readers are the audience to design for (builder's note: this emphasis is the designer's call), because they give up soonest when an app feels like work.

**The test for every v1 decision:** does this make reading itself better, or getting back into reading faster? If neither, it waits.

**Who builds it:** the owner is handing the build over entirely, will not read or write Swift, and judges progress by using the app. Every milestone must therefore end in something they can open and try, explained in plain language.

## Goals

The app is designed around four moments.

1. **First open.** No onboarding, account or settings. Empty shelves and "Drop a book here". They drag in an EPUB, it settles on the shelf with a soft animation, they click it, and they're reading within five seconds.
2. **While reading.** Interface fades away. Two facing pages on a desk. Moving the mouse shows a thin quiet toolbar; keeping still hides it.
3. **Leaving.** Nothing to save and no prompts. Closing the window mid-sentence is fine.
4. **Coming back.** The app opens to the exact place they left, same page and same paragraph, with no spinner.

## Non-goals for v1

Highlights and notes, sync, a store, collections and tags, dictionary, reading stats, MOBI and PDF, cloud accounts, search. Each adds interface, and interface is what makes a reader feel cluttered.

## Anti-goals

Any of these would make v1 a failure even if every feature works:

- It feels boring or generic, like a plain document viewer.
- It feels like software while reading: visible controls, prompts, settings screens.
- The page curl stutters or feels like a gimmick.
- The reader loses their place.
- A messy EPUB crashes the app.

## What the owner decided

These are decisions, shown to the owner in working mockups. Don't reopen them without asking.

**Platform.** Native Mac app, SwiftUI with WKWebView for book rendering. foliate-js is the proposed renderer (from the owner's original write-up).

**Reading view: "Open Book".** Two facing pages with a soft shadow at the spine, in a classic book serif, resting on a darker desk surface. Pages, not scrolling. The owner chose this because it "looks natural book reading".

**Page turn: a natural page curl.** This replaces the "no page curl" line in the original write-up. The owner tried the prototype and said it feels natural. In it, the page lifts from its outer edge, bends over the spine and settles, casting a soft shadow, over about 520 ms. It uses a strip-based bend (28 strips, peak bend of 34 degrees), and the page straightens as it passes vertical. Reproduce this feel.

**Fullscreen, with a shortcut.** The toolbar and cursor hide when the mouse is still, and the text gets larger.

**Library: a real-looking bookshelf.** Covers stand on shelves in the same warm tone as the reader's desk. The owner chose this because "it looks like a real bookshelf".

**The current book gets its own top shelf.** It stands larger, with "Continue reading", title, author, chapter and time left beside it. The other books fill the shelves below.

**Getting around the book.** After trying the curl, the owner asked for shortcuts to the last page, the index and a specific page number. ⌘T opens the contents, ⌘↑ goes to the start of the book and ⌘↓ to the last page (Home and End do the same), and ⌘G opens a small field to type a page number into. None of these jumps plays a curl. Builder's call: a flowing book has no fixed pages, so a "page" here is a fixed run of text, as in Kindle and Apple Books. The number stays the same when the font or window changes, and the field shows the current page and total, such as "214 of 1,240". It isn't the page number printed in a paper edition.

**Holding an arrow key.** Pages stop when the key is released. A held key only asks for another page once the last one has landed, so nothing queues up. Separate quick presses all count.

**Distribution.** Eventually the Mac App Store. Money is tight, so it starts as a free download from the owner's website.

## Carried over from the original write-up

The owner wrote these and has not changed them.

- EPUB only.
- Three themes: Paper (off-white, around #F8F5EE), Sepia, and Night (soft charcoal with slightly dimmed text). Themes transition smoothly and never flash.
- Two to three curated fonts, with controls for font size and line width and nothing more.
- Line height around 1.5 to 1.6, with proper hyphenation.
- Table of contents as a slide-in sidebar with vibrancy blur, opened with ⌘T. Chapter titles show reading progress subtly.
- A hairline progress bar at the bottom of the page, plus "time left in chapter".
- Navigation by arrow keys, space and two-finger swipe.
- Hidden title bar with traffic lights only on hover. Standard shortcuts, including ⌘+ and ⌘−.
- Motion around 200 ms ease-out for everything except the page curl. Covers lift slightly on hover.
- Covers have consistent aspect ratios and soft shadows. Books without a good cover get a generated typographic cover from title and author, never a gray placeholder.
- Night mode can follow the system automatically.
- Opens instantly. Remembers window size and position.
- Dragging a book onto the Dock icon opens it.
- Badly formatted EPUBs never crash the app.

## Designer's calls

The designer chose these, and the owner saw most of them played back without objecting. The builder can change them if there's a good reason, but should say so.

**Reading**
- Default font is EB Garamond, as in the prototype. Others offered: Literata and New York.
- Two pages fit about 50 to 55 characters per line at the default size. That's under the write-up's 60 to 70 target, accepted for the sake of the two-page look.
- When the window is too narrow for two readable pages, it shows one page rather than shrinking the text.
- The desk surface changes with each theme, so Night still feels like a book.
- Clicking the outer page edges also turns pages.
- Fullscreen uses both ⌃⌘F (the Mac standard) and plain F.
- Exact position is saved on every page turn, so there is never anything to save on exit. It must survive changes to font size, line width and window size.

**Library**
- The current book is always the most recently read one, and one click opens it at the exact place.
- Other books are ordered by most recently read. Shelves are added as needed, and the library scrolls.
- The shelf stays dark and warm in all themes. Paper, Sepia and Night only change the book's pages.
- First open shows a dashed book outline on the top shelf with "Drop a book here".
- Remove a book by right-clicking and choosing Remove.

**App launch**
- Launching opens straight into the last book, per the write-up. The library is reached from the toolbar or a shortcut.
- If no book has been opened, launch shows the library.

**Supported Macs**
- Apple silicon only, macOS 14 or later. The owner's Mac (Apple silicon, macOS 26) is the machine the curl is judged on, and it must also be smooth on the oldest Apple silicon Mac available for testing.

**Supported books**
- v1 is built to read reflowable, left-to-right EPUBs well.
- Fixed-layout, right-to-left and vertical books should open without crashing where possible, but they don't have to look good and don't shape the curl or pagination design.
- Books protected by DRM can't be opened. Trying one shows a short, kind message explaining that, with no prompts or dialogs to work through, and the book isn't added to the shelf.

**Distribution plan**
- Early builds are free downloads from the website, not signed with a paid Apple certificate. macOS will block these on first open, and each person must allow it in System Settings, so include clear instructions.
- The owner pays Apple's developer fee (about $99 a year) when real demand appears. That removes the warning, and it opens the path to the Mac App Store.
- Build to App Store rules from day one (sandboxed, no private APIs), so that step doesn't mean rework.

## Constraints

- Mac only.
- No backend, accounts or network dependency. The app works fully offline.
- Costs must stay at zero until the owner chooses to pay Apple's fee.
- Fonts and libraries must have licences that allow shipping in a commercial app. The proposed web fonts and foliate-js are believed to allow this, but confirm it.

## Known risk: the page curl

This is the hardest part technically, and it's central to the product. foliate-js handles pagination and position, but as far as the designer knows it has no curl animation. The curl needs both faces of the turning page, and the page beneath it, ready before the turn starts, and it must stay smooth on long books.

Prove the curl working on real paginated EPUB content first, before building the surrounding app, and let the owner try it. The prototype only works with hand-placed pages, so it doesn't settle how this is done. If foliate-js can't support the curl, finding that out early is the point.

**If the curl can't be made smooth (owner's decision):** first try a simpler curl that looks a little less detailed, and show it to the owner before building anything else. If that still isn't good enough, stop and let the owner decide. Swapping the rendering engine or falling back to a plain fade are both possible next steps, but neither happens without asking.

**Two-finger swipe (owner's decision):** the page follows the fingers, and it can stop partway and fall back, like holding a real page. Build this in the first curl trial, because the owner hasn't tried it yet and it's the harder version of the riskiest work. If it can't be made smooth, fall back to a swipe that simply plays the curl. Keys and clicks always play the full timed curl.

## Left to the builder

- How to implement the curl: inside the web view, or natively over it.
- How to store the library and reading positions.
- How to estimate time left in the chapter.
- Exact shortcuts not named above, theme colours for Sepia and Night, and the look of the toolbar's font and size controls.
- How to generate cover colours, as long as they are tasteful and stable for a given book.

## Reference

The approved mockups are in `.superpowers/brainstorm/90351-1793380429/content/`. That folder is ignored by git, so copy these into `docs/` if they need to be kept:

- `open-book-v2.html`: working reading view with curl, themes, toolbar, fullscreen and narrow window.
- `library-v1.html`: full library and first-open state.
- `shelf-current.html`: option C is the chosen current-book treatment.
