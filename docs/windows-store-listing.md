# Microsoft Store listing (draft)

What to enter in Partner Center for Readme's first Windows submission. The packages come from
`scripts/windows-release.ps1 -Store` (see `docs/releasing.md`, "Windows").

## Before the first submission

1. Sign up for a Microsoft Store developer account in Partner Center, as an individual or a
   company (Partner Center shows any fee when signing up).
2. **Apps and games > New product > MSIX or PWA app**, and reserve the name **Readme**. If it's
   taken, reserve a variant such as **Readme – EPUB Reader** and change `DisplayName` in
   `windows/Readme.App/Package.appxmanifest` to match.
3. On the app's **Product identity** page, copy **Package/Identity/Name**,
   **Package/Identity/Publisher** and **Package/Properties/PublisherDisplayName** into
   `Package.appxmanifest`, replacing the placeholders, and commit.

## Properties

- **Category:** Books & reference. Subcategory: E-reader.
- **Privacy policy URL:** required, because the app has the `runFullTrust` capability. A page with
  the privacy text below is enough, for example a `PRIVACY.md` in the repo, linked by its GitHub URL.
- **Website:** https://github.com/rajanchavda/readme
- **Support contact:** the GitHub issues page, https://github.com/rajanchavda/readme/issues
- **Display mode, system requirements:** Windows 11, 4 GB of memory; keyboard or touchpad
  recommended.

## Age ratings

Answer the questionnaire as an app with no user-generated content shared between users, no
purchases, no location, and no communication between users. It reads books the user supplies
themselves, so it should rate for everyone.

## Restricted capability: runFullTrust

Partner Center asks why. Suggested answer:

> Readme is a desktop app built with WinUI 3 and the Windows App SDK, packaged as a full-trust
> MSIX. It needs full trust to open EPUB files wherever the user keeps them (through file
> association, drag and drop and the file picker), to keep its library in the user's Documents
> folder so it survives a reinstall, and to host WebView2, in which it lays out the books. It
> makes no network requests of its own and loads nothing from the web.

## Store listing (English)

**Description**

> A quiet EPUB reader. Books open as a two-page spread that turns with a page curl, set in a proper
> book typeface, with highlights, a page marker and search.
>
> - Two pages side by side, like an open book, or one page in a narrow window.
> - Turn pages with the arrow keys, the space bar, a click at the page's edge, or by swiping two
>   fingers across a touchpad, and watch the page curl over.
> - Three book typefaces, three line widths, and Paper, Sepia and Night themes, or let it follow
>   Windows' light or dark mode.
> - Highlight passages, mark your place, search the whole book, and jump to any chapter or page.
> - A bookshelf of everything you've added, with search and books pinned to the front.
> - Move your library, with highlights and reading places, to another PC or a Mac in one file.
> - No accounts, no tracking, nothing online. Books with copy protection (DRM) can't be opened.

**What's new in this version:** First release for Windows.

**Product features** (up to 20, one line each):

- Two-page spread with a page curl
- Swipe across a touchpad to turn the page
- Paper, Sepia and Night themes, or follow Windows
- Highlights, a page marker and full-book search
- Contents, go to page, and keyboard shortcuts for everything
- A bookshelf with search and pinning
- Move your library to another PC or a Mac
- Private: no accounts, no tracking

**Search terms:** EPUB, ebook reader, book reader, e-reader, reading

**Screenshots:** at least one, 1920 × 1080 or 1366 × 768. Suggested: a spread in Paper, the curl
mid-turn, Night with highlights, the shelf, the contents sidebar. Take them from the app in a
1366 × 768 or 1920 × 1080 window with sample books whose text may be shown (public domain, such as
Project Gutenberg editions).

**Store logos:** the package's own icons are used; a 300 × 300 Store logo can be uploaded from
`windows/Readme.App/Assets/Square44x44Logo.targetsize-256_altform-unplated.png` scaled up, or a new
one exported from the Mac's `AppIcon` at 1024.

## Privacy text

> Readme collects no personal data. It has no accounts, no analytics and no advertising, and it
> makes no network requests: books are shown with all web access blocked. The books you add, and
> your reading places, highlights, markers and settings, stay on your PC, in Documents\Readme and
> in the app's own settings folder. A library you export is a file you choose where to save.

## Packages

Upload both `windows/dist/Readme-<version>-x64.msix` and `-arm64.msix` to the submission's
**Packages** page. Under **Device family availability** tick Windows 10/11 Desktop only; the
packages themselves require Windows 11 (`MinVersion` 10.0.22000.0).

## Certification notes

> To try it: add any DRM-free EPUB (for example from Project Gutenberg) by dragging it onto the
> shelf or with Ctrl+O, click it to read, and press ? for the keyboard shortcuts.
