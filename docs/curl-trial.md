# Curl trial results

Trial of the page curl on real books, on 2026-11-02. This is the measurement record behind the owner's try. It doesn't replace that try, and nothing here says the curl feels right.

## Summary

- **The app:** `build/Readme.app`, built by `scripts/build_app.sh` (Release, arm64, ad-hoc signed, sandboxed). It has no measurement driver in it, only `CurlFrameMonitor`.
- **The app's own bar is met.** Across 100 key turns and 20 swipes in full Moby-Dick, the monitor counted 0 missed frames out of 7,871 at 120 Hz. The bar was under 1%.
- **That doesn't prove the screen got every frame.** The monitor can't see the render server. Instruments can, and it reports about 15 to 20% of the frames in a normal key turn arriving one refresh late. The same tool reports 2.3% for one small moving layer, so it can't confirm 1% for anything. The bar is met as written, and not shown at the screen.
- **The simpler curl was tried and didn't help.** Dropping shading updates and going to 14 strips left the Instruments number where it was, so nothing was simplified. The curl is unchanged.
- **Normal reading works.** Every press curled at 1 s and 0.4 s, at the start, middle and near the end of the book.
- **A held key stops when it's let go.** The last page lands within 60 to 175 ms of release, at about 5 pages a second while held, but almost none of those pages curl.

## What was tested

| | |
|---|---|
| Machine | Mac16,1 (Apple M4), macOS 26, built-in display at 120 Hz, 2x |
| Book view | 980 x 552 points, in the trial window |
| Main book | Moby-Dick, Gutenberg 2701, `epub3.images`, 795 KB, 1 image (the cover), about 520 spreads |
| Image-heavy book | Huckleberry Finn, Gutenberg 76, `epub3.images`, 15.3 MB, 178 images. Moby-Dick's images edition has too few images to test this |
| Key presses | Posted with `NSApp.postEvent`, so they go through the real key monitor, but aren't physical input |
| Swipes | Synthetic scroll events sent straight to `TrialDeskView.scrollWheel`, with natural scrolling set on the event |

**Measured with a separate driver build.** Screen Recording and Accessibility are denied here, so a temporary driver was compiled into a copy of the source under `scratchpad/`. It's the same Release code plus the driver, and it was never committed.

**The shipped build was checked too.** `build/Readme.app` opened Moby-Dick through `open -a`, and 5 arrow-key events sent to its process gave 5 curls and 5 monitor lines, each with 0 missed.

**The real trackpad path was not exercised.** Neither was the window's scroll monitor, which real swipes go through. Only one Mac was available: the spec also asks for smoothness on the oldest Apple silicon Mac, which is still untested.

## What the frame number means

`CurlFrameMonitor` runs its own display link while a turn is on screen, including while fingers hold a page. It logs one line per turn at debug level, which doesn't show in normal use. To see it (the full path matters, because `log` means something else in zsh):

```
/usr/bin/log stream --level debug --predicate 'subsystem == "com.rajanchavda.Readme" AND category == "CurlFrames"'
```

- **`missed`:** display refreshes that passed with no tick, from jumps in the link's timestamps. It proves the main thread kept up with the display. A deliberate 100 ms stall in each of 5 turns gave 59 missed, about 12 per turn, which is the right count.
- **`late`:** ticks or poses that happened after `targetTimestamp`. This is the comparison of target against actual tick, kept apart from `missed` because on its own it isn't a lost frame. Whole runs sat about 1 ms behind their targets with steady timing: one trace had 845 of 1,008 late and another had 128 of 1,008, with similar Instruments results (18.2% and 17.5%). Read it as a sign of pressure.
- **`start delay`:** from starting to set up a turn to its first frame. It isn't counted as missed, because the curl's clock starts on that frame.

**What it can't prove.** It only sees this process. A frame that left on time and was then dropped by the render server doesn't appear. This was tested: a stack of layers added to load the render server gave at least 12 Instruments hitches of about 190 ms each, roughly 23 frames apiece, while the monitor reported 15 missed out of 504 frames across the 8 turns. A low `missed` means the app did its part. It doesn't mean every frame reached the screen.

## The bar: 100 key turns and 20 swipes

Full Moby-Dick from the start, in the final code.

| Input | Turns | Frames | Missed | Late | Longest frame | Median start delay |
|---|---|---|---|---|---|---|
| Keys, one a second | 100 | 6,300 | 0 | 3 | 8.3 ms | 43 ms |
| Swipes | 20 | 1,571 | 0 | 0 | 8.3 ms | 44 ms |

- **Repeats:** earlier runs of the same scenario on the same curl gave 0.02% (1 of 6,300) and 0.06% (1 of 1,573). No run came near 1%.
- **Swipes:** 10 slow turns, 5 stops that fell back and 5 flicks, split between directions. All 20 did what was expected: the turns and flicks moved the page and the stops didn't.
- **Start delay:** about 40 to 50 ms from press to first frame. This isn't reduced here, and it's for the owner to judge.

## What Instruments shows at the screen

Instruments' Animation Hitches template, attached to the running app, 16 turns at a time. Curls were found from the app's own commits in the trace. A hitch is a frame shown later than it should have been.

| Run | Frames | Frames hitched | Commit gaps over 12 ms |
|---|---|---|---|
| One small layer moved every frame (the tool's floor) | 990 | 2.3% | 3.6% |
| The curl alone, no page move or refill | 884 | 4.5% | 6.2% |
| Key turns, Moby-Dick, 1 s (3 runs) | 901, 813, 835 | 15.4%, 18.2%, 17.5% | 10.2%, 16.9%, 14.4% |
| Key turns, Huckleberry Finn, 1 s | 893 | 13.1% | 8.8% |
| Key turns, Moby-Dick, 0.4 s | 1,242 | 3.5% | 3.5% |
| Swipes (9 gestures in a longer trace, approximate) | 1,308 | 10.7% | not meaningful |

- **Size of a hitch:** nearly always one refresh, 8.3 ms. The longest gap between commits in a normal key turn was about 42 ms.
- **When it happens:** in the first 50 ms of a curl, around 150 to 250 ms (probably the page landing underneath, at about 115 ms, though that wasn't tested), and around 400 ms (the refill finishing: delaying the refill moved this cluster away).
- **Why it's only an indication:** recording writes hundreds of megabytes of kernel trace a second, which may inflate everything, and the floor shows it can't resolve 1%. The comparison between rows means more than any absolute number.
- **Not explained:** the 0.4 s pace hitches far less than the 1 s pace. Neither the cause nor whether the difference is real on the screen is known.
- **Swipes:** commit gaps aren't meaningful for them, because a held page only commits when a synthetic event arrives.
- **Discarded data:** in long traces Instruments kept only the most recent seconds whole. Only short traces are used here, plus the tail of one longer trace for swipes.

## Simplifications tried (Step 3)

The monitor didn't force these, but Instruments might have, so they were measured in the driver build only. Each is 16 key turns at 1 s in Moby-Dick, against the 15.4 to 18.2% baseline above.

| Attempt, in order | Frames hitched | Result |
|---|---|---|
| 1. Drop shading updates | 19.6% | No better |
| 2. Also go to 14 strips | 15.0% | No better |
| Diagnostic, not in the spec: hold the refill until the curl ends | 13.3% | Moves the 400 ms cluster away, little change overall, and only 6 of 16 presses had the further spread ready |

**Nothing was shipped from this table.** Most of the hitching comes from what happens under the curl, not from drawing it. A simpler curl would cost the look and gain nothing measurable. Falling back to a swipe that plays the curl wasn't tried, because swipe tracking isn't the problem.

## Normal reading pace

A curl was counted when a press produced new strips.

| Where in Moby-Dick | Every 1 s | Every 0.4 s | Missed frames, 1 s | Missed frames, 0.4 s |
|---|---|---|---|---|
| Start | 40 of 40 | 40 of 40 | 0.16% | 0% |
| Middle, from 50% | 40 of 40 | 40 of 40 | 0.28% | 0.06% |
| Near the end, from 84% to 98% | 40 of 40 | 40 of 40 | 0.87% | 0.29% |
| Backward from 50% | not run | 20 of 20 | | 1.02% |

- **Thin margin at 0.4 s:** the next spread was ready on every press, but the one after it on only 1 of 40. A slower Mac could run out, and then that press changes the page with no curl.
- **Depth:** missed frames were higher near the end, in this one run. The largest single gap, 35 ms, is what puts the backward run just over 1%. That run has only 881 frames, so it's weak evidence either way, but it's the one figure in this document over the bar.
- **Huckleberry Finn:** 60 of 60 at 1 s and 40 of 40 at 0.4 s. Two runs gave 0% and 0.82% missed at 1 s. The 0.82% includes one 92 ms frame, in a run where the window wasn't key or visible as it began, so something else on the Mac may have got in the way.
- **Accounting:** these runs came before `missed` and `late` were separated. The figures above count timestamp gaps only, as the final monitor does.
- **Opening:** the first curl was ready about 1.6 s after launch, in both books.

## Held key

Key repeat is simulated at macOS's default settings (375 ms, then every 90 ms) and at the fastest setting (225 ms, then every 30 ms). This Mac uses the defaults. The repeats are real key events marked as repeats, through the window's key monitor.

The owner chose that pages stop when the key is released. A repeat is now dropped while the turn before it is still waiting for images or landing, and is never kept for later. Separate presses all count, as before. Measured again on 2026-11-02 in a driver build of that code, in Moby-Dick from 30%:

| Held for | Repeat | Presses | Pages turned | Curls | Page still turning after release |
|---|---|---|---|---|---|
| 3 s | 90 ms | 31 | 16 | 3 | 0.10 s |
| 10 s | 90 ms | 108 | 53 | 3 | 0.13 s |
| 3 s | 30 ms | 94 | 16 | 2 | 0.21 s |

- **Pages stop with the key.** The last page landed 60, 93 and 173 ms after release, in the table's order. The last column runs on until the turn has finished, a little after landing. Before this change it was 1.0 s, 3.2 s and 8.3 s, with every press turning a page.
- **A held key turns about 5 pages a second** at either rate. At 30 ms, a page lands, the next repeat comes, and then it waits its 50 ms for images that aren't there before the page changes. That's what puts the fastest rate's stop past 150 ms.
- **Almost none of them curl, still.** The read-ahead waits for a quiet period longer than the gap between held turns, so after the first two the buffer is empty and the page just changes. Nothing was changed there.
- **After a hold:** 5 of 5 presses at 1 s curled again.

## Landing mismatches and pops

After each turn, the preview used for the curl was compared with what the web view showed on landing and 400 ms later. A pixel counts as different beyond 4 of 255, and the threshold is 0.2% of pixels, as in the tests. As a check that the comparison can see a difference, the page being left differed from the landed page by about 18 to 25%.

| Book | Turns | Chapter changes | Over the threshold at landing or later |
|---|---|---|---|
| Moby-Dick, from 0, 25, 50, 75 and 93% | 125 | 27 | 0 (the worst difference was 0) |
| Huckleberry Finn, from 25, 50 and 75% | 75 | 11 | 0 (the worst difference was 0) |

The window as the window server shows it was also captured on uncovering and 400 ms later:

- **One real but small change in 75 Huckleberry Finn turns.** An illustration's pixels changed slightly on the first turn after a jump (2.0% of the book's pixels). Side by side the picture looks the same apart from slightly different fine texture. WebKit's snapshots didn't show it.
- **One capture discarded in 125 Moby-Dick turns.** The capture came back at the wrong size, showing the page at an offset, with the same text. This looks like a capture fault, not a pop. This has not been reproduced, so it isn't proven.
- **Limit:** two captures per turn can't catch a flash lasting a frame or two. That's on the list below.

## Memory

Measured with `top`'s memory column for each process, after the given number of turns. The web content processes were identified by the driver.

| | App | Visible web process | Offscreen web process |
|---|---|---|---|
| Moby-Dick, on opening | 28 MB | 43 MB | 65 MB |
| Moby-Dick, after 100 turns | 31 MB | 36 MB | 76 MB |
| Moby-Dick, after 120 turns | 31 MB | 35 MB | 76 MB |
| Huckleberry Finn, on opening | 28 MB | 49 MB | 76 MB |
| Huckleberry Finn, after 100 turns | 30 MB | 102 MB | 141 MB |
| Huckleberry Finn, after 175 turns and 3 jumps | 43 MB | 90 MB | 124 MB |

- **No steady growth** showed in the app over these runs, but they're short. A whole-book run hasn't been measured.
- **The buffer's images,** 41.8 MB at this window size, don't show in the app's footprint. Where they're counted is still unknown.
- **Fullscreen will cost more,** as the buffer scales with the window. An earlier task measured 119 MB of buffer at a 1512 x 982 window.

## Please check by hand

Only a person can judge these, on the real machine:

1. **The feel in motion.** Is it as natural as the prototype? Do the late frames Instruments reports show? Does the 40 to 50 ms before motion show?
2. **Two-finger swipe direction** under your natural-scrolling setting. It's written to follow the fingers, and it has never been observed with real fingers.
3. **Stopping halfway and falling back,** and whether the point of turning feels right.
4. **Flicks,** and whether a quick flick turns when you expect it to.
5. **Picking a file in the real ⌘O panel.** The panel has been seen to open, but no file has been chosen through it.
6. **A second display at 1x,** for blur and seams between strips.
7. **The faint title-bar smudge** at mid-turn, which hasn't been investigated.
8. **Gradient shading versus the prototype's flat shading.** The gradient, with no overlap between strips, is a departure from the mockup, made to avoid bands and lines.
9. **Holding an arrow key.** Pages now stop on release. Is about 5 pages a second while held the right speed, and is it acceptable that held turns don't curl?
10. **Illustrated pages.** Do you see any flash or change as a page lands? Huckleberry Finn is a good book for this.
