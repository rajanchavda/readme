# Golden files

The shared contract between the Mac and Windows apps, in files both test suites read:
`ReadmeTests/GoldenFilesTests.swift` on Mac and `windows/Readme.Core.Tests/GoldenFilesTests.cs` on
Windows. If either app changes one of these formats, the other app's tests fail.

| File | Written by the Mac app as | Dates |
| --- | --- | --- |
| `library.json` | `LibraryStore`, `[Book]` | Seconds since 2001-01-01 UTC, a number (`JSONEncoder` default) |
| `highlights.json` | `HighlightStore`, `[Highlight]` | ISO 8601, whole seconds, `Z` |
| `marker.json` | `MarkerStore`, `Marker` | ISO 8601, whole seconds, `Z` |
| `position.json` | `PositionStore`, `ReaderLocation` | none |
| `ids.json` | `BookID.of` for three fixtures | none |

Other details both sides keep: nil optionals are left out rather than written as `null`; a UUID is
written in upper case; Swift writes `/` as `\/`, and both sides read either form.

Still to add: one `.readmelibrary` exported by the Mac app (phase 5).
