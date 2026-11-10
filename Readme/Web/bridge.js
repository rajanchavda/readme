// Drives <foliate-view> for BookWebView.swift. Every method on `readmeBridge` is called from
// Swift with callAsyncJavaScript and answers with plain JSON-safe values.
import { makeBook } from './foliate/view.js'
import { SectionProgress } from './foliate/progress.js'
import { Overlayer } from './foliate/overlayer.js'
import { collapse, compare } from './foliate/epubcfi.js'

const COMMAND_MS = 15000
const SECTION_MS = 10000
const SETTLE_MS = 100
const HIDDEN_SETTLE_MS = 40
const RELAYOUT_MS = 150
const RESOURCES_MS = 5000
const DEFAULT_INLINE_SIZE = 720
// The bytes of text in one of foliate's locations, which are the reader's pages. foliate's view
// uses the same for its own `location`.
const LOCATION_SIZE = 1500
// foliate's #container is the view less a 3.5% gutter on each side.
const CONTAINER_SHARE = 0.93

let view = null
let book = null
let progress = null
let latest = null // the last `relocate` detail from foliate
let relocations = 0
let busy = false // true during a command, so its in-between stops aren't reported
let lastPostedCFI = null
// What was last told to the app, so a location is told once, and again if its marking changes.
let lastPostedKey = null
// Where the reader is: the place they last went to, which a layout change shows again and leaves as
// it was. The spread it then lands on usually starts a little before it, so going back to that
// spread's start instead would creep back a page with each change.
let place = null
let columnCount = 2
// How wide each column should be, in points, or null to let foliate pick.
let columnWidth = null
let laidOutSize = null
let relayoutTimer = null
let queue = Promise.resolve()
// The highlights drawn on the book, by CFI, and the colour they're drawn in.
const highlights = new Set()
let highlightColor = '#f2c744'
// The reading marker: a point CFI at the start of the spread the reader marked, or null.
let marker = null

// Whether the visible spread holds the marker: it's at or after the spread's start, and before its
// end, which is where the next spread starts. A spread with nothing in it to span, such as a lone
// image, holds a marker at its start, and the last one holds any after it.
const holdsMarker = () => {
    if (!marker || !latest?.cfi) return false
    try {
        const start = collapse(latest.cfi)
        const end = collapse(latest.cfi, true)
        if (compare(marker, start) < 0) return false
        return compare(marker, end) < 0 || compare(start, end) === 0 || !!view?.renderer?.atEnd
    } catch (error) {
        console.warn(error)
        return false
    }
}

const withTimeout = (promise, ms, label) => {
    let timer
    const timeout = new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${label} timed out`)), ms)
    })
    return Promise.race([promise, timeout]).finally(() => clearTimeout(timer))
}

const finite = (value, fallback = 0) => Number.isFinite(value) ? value : fallback

const currentDocument = () => view?.renderer?.getContents?.()[0]?.doc ?? null

// Lets layout that follows a move land: fonts, then the resize observers, which run in a
// rendering update. A page that isn't visible gets no animation frames, hence the timer.
const settle = async (hiddenWait = SETTLE_MS) => {
    const fonts = currentDocument()?.fonts?.ready
    if (fonts) await withTimeout(fonts, SETTLE_MS, 'fonts').catch(() => {})
    await new Promise(resolve => {
        const timer = setTimeout(resolve, document.hidden ? hiddenWait : SETTLE_MS)
        requestAnimationFrame(() => requestAnimationFrame(() => {
            clearTimeout(timer)
            resolve()
        }))
    })
}

// Images count as loaded once fetched, but are painted blank until decoded. An SVG <image> has
// no decode() of its own, so an <img> decodes the same file for it.
const decodedImages = doc => [...doc.querySelectorAll('img, image')].map(element => {
    if (element.decode) return element.decode()
    const source = new Image()
    source.src = element.href?.baseVal ?? ''
    return source.decode()
})

const location = () => {
    if (!latest) return null
    const { renderer } = view
    // foliate's own `fraction` is where the visible spread ends, so it's above zero on the
    // first page. `time.total` tracks where the spread starts, which is what we report.
    const wholeBook = progress.getProgress(0, 0, 0).time.total
    const startOfSection = progress.sectionFractions[latest.section?.current] ?? 0
    const fraction = wholeBook > 0 ? 1 - finite(latest.time?.total, NaN) / wholeBook : NaN
    return {
        cfi: latest.cfi,
        fraction: Math.min(1, Math.max(0, finite(fraction, startOfSection))),
        chapterTitle: latest.tocItem?.label?.trim() || null,
        chapterMinutesLeft: Math.max(0, finite(latest.time?.section)),
        isAtStart: !!renderer.atStart,
        isAtEnd: !!renderer.atEnd,
        // foliate's locations: fixed runs of LOCATION_SIZE bytes of text, the same whatever the
        // font or window, which the reader sees as pages. `current` is the one the spread starts in.
        page: Math.max(1, Math.trunc(finite(latest.location?.current)) + 1),
        pageCount: Math.max(1, Math.trunc(finite(latest.location?.total))),
        isMarked: holdsMarker(),
    }
}

const postKey = current => `${current.cfi}|${current.isMarked}`

const post = () => {
    const current = location()
    if (!current || postKey(current) === lastPostedKey) return
    lastPostedCFI = current.cfi
    lastPostedKey = postKey(current)
    globalThis.webkit?.messageHandlers?.readme?.postMessage(
        JSON.stringify({ type: 'relocate', location: current }))
}

// foliate ignores a turn while the last one is finishing, so commands wait in line. A command
// that never finishes gives up its place, so a bad book can't block the ones behind it.
const enqueue = run => {
    const result = queue.then(async () => {
        busy = true
        try {
            return await withTimeout(run(), COMMAND_MS, 'command')
        } finally {
            busy = false
        }
    })
    queue = result.catch(() => {})
    return result
}

// Resolves to the new location, or null if nothing moved. The reader's place is then `target`, or
// the start of where they landed.
const navigate = (move, target) => enqueue(async () => {
    const before = relocations
    await move()
    await settle()
    if (relocations === before) return null
    place = target ?? latest?.cfi ?? place
    post()
    return location()
})

const placeholder = (() => {
    const html = '<!doctype html><html><head><title></title></head><body>'
        + '<p style="text-align:center;opacity:.6">This chapter could not be displayed.</p>'
        + '</body></html>'
    return URL.createObjectURL(new Blob([html], { type: 'text/html' }))
})()

const PARSEABLE = ['text/html', 'application/xhtml+xml', 'image/svg+xml', 'text/xml', 'application/xml']

// A section foliate can't display must never reach it. An error while loading leaves its
// paginator without an index, no URL rejects without releasing its turn lock, and a document
// with no <body> makes it throw inside the iframe's load event, so it waits forever.
const isDisplayable = async url => {
    if (typeof url !== 'string' || !url) return false
    const blob = await (await fetch(url)).blob()
    if (PARSEABLE.includes(blob.type)) {
        const doc = new DOMParser().parseFromString(await blob.text(), blob.type)
        return !!doc.body
    }
    return blob.type.startsWith('image/') || blob.type.startsWith('text/')
}

const guardSection = section => {
    const load = section.load
    section.load = async () => {
        try {
            const url = await withTimeout(Promise.resolve().then(load), SECTION_MS, 'section')
            return await isDisplayable(url) ? url : placeholder
        } catch (error) {
            console.warn('Skipping a section', error)
            return placeholder
        }
    }
}

// Hints that could open a connection without passing the app's content rule list. They're
// removed rather than relied on to be blocked. This sees every document foliate loads for a
// section, including ones nested inside it.
const CONNECTION_HINTS = ['preconnect', 'dns-prefetch', 'prefetch', 'preload', 'modulepreload', 'prerender']

const withoutConnectionHints = (data, type) => {
    const doc = new DOMParser().parseFromString(data, type)
    const hints = [...doc.querySelectorAll('link[rel]')].filter(link => link.getAttribute('rel')
        .toLowerCase().split(/\s+/).some(rel => CONNECTION_HINTS.includes(rel)))
    if (!hints.length) return data
    for (const hint of hints) hint.remove()
    return new XMLSerializer().serializeToString(doc)
}

const removeConnectionHints = book => {
    book.transformTarget?.addEventListener('data', ({ detail }) => {
        if (!PARSEABLE.includes(detail.type)) return
        const { type } = detail
        detail.data = Promise.resolve(detail.data).then(data =>
            typeof data === 'string' ? withoutConnectionHints(data, type) : data)
    })
}

const prepareSections = book => {
    if (!book.sections?.length) throw new Error('The book has no chapters')
    // A file missing from the zip has nothing to show, so turning pages goes past it.
    const hasContent = book.sections.filter(section => section.size > 0)
    if (!hasContent.length) throw new Error('The book has no readable chapters')
    for (const section of book.sections) {
        if (!(section.size > 0)) section.linear = 'no'
        guardSection(section)
    }
    // Some books mark their whole spine non-linear, and foliate can't turn pages in those.
    if (hasContent.every(section => section.linear === 'no'))
        for (const section of hasContent) section.linear = 'yes'
}

const sizeOf = element => {
    const { width, height } = element.getBoundingClientRect()
    return `${width}x${height}`
}

// foliate caps columns by how many fit at this size, which would overrule us in a narrow view.
// Setting the size is also what makes it lay out again, as it would not for a new column count
// alone, or in a hidden page, where its resize observer doesn't run.
const fitColumns = () => {
    const { renderer } = view
    laidOutSize = sizeOf(renderer)
    renderer.setAttribute('max-column-count', String(columnCount))
    const { width } = renderer.getBoundingClientRect()
    const { gap, inlineSize } = spread(width)
    renderer.setAttribute('gap', `${gap}%`)
    renderer.setAttribute('max-inline-size', `${inlineSize}px`)
}

// A book's margins: the text stands as far from the spine as from the page's outer edge. foliate
// puts half its column gap, G, inside the page on each side of each column (Readme's paginator lets
// its outer tracks shrink to nothing), so with the container filling the view, columns of width `c`
// leave G = (width - columns * c) / columns, and every margin is G / 2. foliate works its gap out
// as g / (1 - g) of the container, so it's asked for g = G / (container + G), and for columns
// exactly as wide as the view shares out, so the container fills it.
const MIN_GAP_SHARE = 0.04
const spread = width => {
    if (!(width > 0)) return { gap: GAP_SHARE * 100, inlineSize: DEFAULT_INLINE_SIZE }
    const wanted = textWidth(width)
    const gap = Math.max(MIN_GAP_SHARE * width, (width - columnCount * wanted) / columnCount)
    return { gap: gap / (width + gap) * 100, inlineSize: width / columnCount }
}

// The width of the text in each column: what foliate's own layout made of the column width asked
// for, before the margins were evened out. SpreadLayout's character widths were measured against
// these lines, so the text stays exactly as wide as it was and only the margins move.
// foliate's own layout: its container is at most CONTAINER_SHARE of the view, and at most
// `max-inline-size` a column, and its gap is GAP_SHARE / (1 - GAP_SHARE) of the container.
const GAP_SHARE = 0.07
const textWidth = width => {
    const container = Math.min(width * CONTAINER_SHARE, columnCount * foliateInlineSize(width))
    return container / columnCount - GAP_SHARE / (1 - GAP_SHARE) * container
}

// The `max-inline-size` the column width asked for used to be given to foliate as.
const foliateInlineSize = width => {
    if (columnWidth > 0) {
        const container = columnWidth / (1 / columnCount - GAP_SHARE / CONTAINER_SHARE)
        // Wider than the view allows: ask for exactly the columns that fill it.
        return Math.floor(Math.min((container + GAP_SHARE * width) / columnCount, width / columnCount))
    }
    const fits = Math.ceil(width * CONTAINER_SHARE / DEFAULT_INLINE_SIZE) >= columnCount
    return fits ? DEFAULT_INLINE_SIZE : Math.floor(width / columnCount)
}

// foliate paints the margins around the pages (its `filter` part) with the page's colour, but after
// a restyle it does so in an animation frame, and a page in a window that's never shown, as the
// curl's offscreen one is, never gets one. Its pictures would keep the old theme's margins, so they
// take the page's colour here, at once.
const marginStyle = document.createElement('style')
document.head.append(marginStyle)
const paintMargins = () => {
    const doc = currentDocument()
    if (!doc?.body) return
    const color = doc.defaultView.getComputedStyle(doc.body).backgroundColor
    marginStyle.textContent = `foliate-view::part(filter) { background: ${color} !important; }`
}

const setLayout = (css, columns, width) => {
    columnCount = Math.max(1, Math.trunc(finite(columns, 2)))
    columnWidth = Number.isFinite(width) && width > 0 ? width : null
    fitColumns()
    view.renderer.setStyles?.(css ?? '')
    paintMargins()
}

// Makes a layout change, then goes back to the reader's place, which foliate's own re-rendering
// hasn't moved.
const holdingPlace = async change => {
    const cfi = place ?? lastPostedCFI ?? view.lastLocation?.cfi
    change()
    await settle()
    if (cfi) await view.goTo(cfi)
    await settle()
    post()
}

const relayout = () => enqueue(async () => {
    if (sizeOf(view.renderer) === laidOutSize) post()
    else await holdingPlace(fitColumns)
})

const scheduleRelayout = () => {
    clearTimeout(relayoutTimer)
    relayoutTimer = setTimeout(() => {
        relayoutTimer = null
        relayout().catch(error => console.warn(error))
    }, RELAYOUT_MS)
}

// Resolves to the location once the page is done changing, so what's on it can be photographed:
// a pending relayout has run, fonts and images are in, and foliate has paginated around them.
const settled = async () => {
    while (relayoutTimer !== null) await new Promise(resolve => setTimeout(resolve, 25))
    return enqueue(async () => {
        const doc = currentDocument()
        if (doc) {
            await withTimeout(Promise.allSettled([doc.fonts.ready, ...decodedImages(doc)]),
                RESOURCES_MS, 'resources').catch(() => {})
            // foliate paginates again from a resize observer, which a hidden page runs late if at all.
            if (document.hidden) view.renderer.render()
            // A move has already waited its full time, and the offscreen view has to keep up with a
            // reader turning pages.
            await settle(HIDDEN_SETTLE_MS)
        }
        post()
        return location()
    })
}

const firstSectionIndex = () => book.sections.findIndex(section => section.linear !== 'no')
const lastSectionIndex = () => book.sections.findLastIndex(section => section.linear !== 'no')

// How many pages an end of the book can be from where foliate first lands, at most.
const END_STEPS = 50

const pageNow = () => Math.trunc(finite(latest?.location?.current)) + 1

// The spread that holds the start of `page`: the page is from the spread's own up to the next
// spread's. foliate lands by fraction, which it measures by layout rather than text, so this turns
// back or on from there until that's so.
const goToPage = async page => {
    const { renderer } = view
    const total = finite(latest?.location?.total, 1)
    await view.goToFraction(Math.min(1, Math.max(0, (page - 1) / total)))
    for (let i = 0; i < END_STEPS && pageNow() > page && !renderer.atStart; i++) await view.prev()
    for (let i = 0; i < END_STEPS && !renderer.atEnd; i++) {
        await view.next()
        if (pageNow() > page) {
            await view.prev()
            break
        }
    }
}

// The first or last spread. foliate lands near an end by fraction, and can stop a spread short of
// it, so this turns the rest of the way.
const goToEdge = async atEnd => {
    const { renderer } = view
    const index = atEnd ? lastSectionIndex() : firstSectionIndex()
    await renderer.goTo({ index, anchor: atEnd ? 1 : 0 })
    for (let i = 0; i < END_STEPS && !(atEnd ? renderer.atEnd : renderer.atStart); i++)
        await (atEnd ? view.next() : view.prev())
}

const open = async (url, cfi, css, columns, width) => {
    const response = await fetch(url)
    if (!response.ok) throw new Error(`Could not read the book (${response.status})`)
    const blob = await response.blob()
    // Checked here, as foliate would otherwise try its MOBI and PDF readers, which aren't bundled.
    const magic = new Uint8Array(await blob.slice(0, 4).arrayBuffer())
    if (magic[0] !== 0x50 || magic[1] !== 0x4b || magic[2] !== 0x03 || magic[3] !== 0x04)
        throw new Error('The file is not an EPUB')
    book = await makeBook(new File([blob], 'book.epub', { type: 'application/epub+zip' }))
    prepareSections(book)
    removeConnectionHints(book)
    progress = new SectionProgress(book.sections, LOCATION_SIZE, 1600)

    busy = true
    view = document.createElement('foliate-view')
    view.addEventListener('relocate', ({ detail }) => {
        latest = detail
        relocations++
        if (busy) return
        // foliate re-rendering, usually mid-resize, so wait to see where it ends up.
        if (detail.reason === 'anchor') scheduleRelayout()
        else {
            // A move of foliate's own, such as following a link in the book.
            place = detail.cfi
            post()
        }
    })
    view.addEventListener('external-link', event => event.preventDefault())
    // A link in the book waits its turn with the commands, so a layout change under way can't undo
    // it. The app hears it's been followed, and again once it's landed, as a move it didn't ask for.
    view.addEventListener('link', event => {
        event.preventDefault()
        const { href } = event.detail
        const tell = landed => globalThis.webkit?.messageHandlers?.readme?.postMessage(
            JSON.stringify({ type: 'link', landed }))
        tell(false)
        navigate(() => view.goTo(href)).catch(error => console.warn(error)).finally(() => tell(true))
    })
    // Highlights: the page tells the app about a selection worth marking and about a click on a mark.
    const tellApp = message => globalThis.webkit?.messageHandlers?.readme?.postMessage(JSON.stringify(message))
    const rectOf = range => {
        const frame = range.startContainer.ownerDocument.defaultView?.frameElement
        const offset = frame?.getBoundingClientRect() ?? { left: 0, top: 0 }
        const r = range.getBoundingClientRect()
        return { x: r.left + offset.left, y: r.top + offset.top, width: r.width, height: r.height }
    }
    // How far into the book a point of a section is, going by the section's share of the text.
    const fractionOf = (index, range) => {
        const fractions = view.getSectionFractions()
        const start = fractions[index] ?? 0
        const end = fractions[index + 1] ?? start
        const body = range.startContainer.ownerDocument.body
        const total = body?.textContent.length || 1
        const before = range.cloneRange()
        before.selectNodeContents(body)
        before.setEnd(range.startContainer, range.startOffset)
        return Math.min(1, start + (end - start) * Math.min(1, before.toString().length / total))
    }
    view.addEventListener('load', ({ detail: { doc, index } }) => {
        const report = () => {
            const selection = doc.getSelection()
            const text = selection?.toString().trim()
            if (!selection || selection.isCollapsed || !text) return tellApp({ type: 'selection' })
            const range = selection.getRangeAt(0)
            const cfi = view.getCFI(index, range)
            // Without the range in it a CFI is only the section, which isn't worth marking.
            if (!cfi.includes(',')) return tellApp({ type: 'selection' })
            tellApp({
                type: 'selection', cfi, text, rect: rectOf(range),
                fraction: fractionOf(index, range),
                label: view.getProgressOf(index, range).tocItem?.label ?? null,
            })
        }
        let timer
        doc.addEventListener('selectionchange', () => {
            // A selection still being made is reported when the pointer lets go.
            if (!doc.getSelection()?.isCollapsed) return
            clearTimeout(timer)
            timer = setTimeout(report, 50)
        })
        doc.addEventListener('pointerup', () => { clearTimeout(timer); timer = setTimeout(report, 30) })
        doc.addEventListener('keyup', event => {
            if (event.key.startsWith('Arrow') || event.key === 'Shift') {
                clearTimeout(timer)
                timer = setTimeout(report, 150)
            }
        })
    })
    view.addEventListener('draw-annotation', ({ detail: { draw } }) =>
        draw(Overlayer.highlight, { color: highlightColor }))
    view.addEventListener('create-overlay', () => {
        for (const cfi of highlights) view.addAnnotation({ value: cfi }).catch(error => console.warn(error))
    })
    view.addEventListener('show-annotation', ({ detail: { value, range } }) => {
        if (!highlights.has(value)) return
        tellApp({ type: 'highlight', cfi: value, rect: rectOf(range) })
    })
    // Otherwise a big image can be painted blank and repainted later when it's decoded, which a page
    // that isn't visible may never do, leaving a gap in a snapshot.
    view.addEventListener('load', ({ detail: { doc } }) => {
        for (const image of doc.querySelectorAll('img, image')) image.decoding = 'sync'
    })
    document.body.append(view)
    await view.open(book)

    // A range foliate can't express as a CFI shouldn't lose the location, only its precision.
    const originalGetCFI = view.getCFI.bind(view)
    view.getCFI = (index, range) => {
        try {
            return originalGetCFI(index, range)
        } catch (error) {
            console.warn(error)
            return originalGetCFI(index)
        }
    }
    view.renderer.setAttribute('flow', 'paginated')
    setLayout(css, columns, width)
    // foliate opens a place it can't resolve at the start, without saying so.
    let wentToCFI = !!cfi && !!view.resolveNavigation(cfi)
    try {
        await view.init({ lastLocation: cfi ?? null })
    } catch (error) {
        console.warn('Could not go to the saved place', error)
        wentToCFI = false
    }
    // Going to a place foliate can't find fails quietly, so check that it moved.
    if (!relocations || !currentDocument()) {
        wentToCFI = false
        await view.renderer.goTo({ index: firstSectionIndex(), anchor: 0 })
    }
    if (!relocations) throw new Error('The book could not be displayed')
    await settle()
    // A place that took the book somewhere is kept as it was given.
    place = wentToCFI ? cfi : latest?.cfi ?? null
    busy = false
    post()
    new ResizeObserver(scheduleRelayout).observe(view.renderer)
    return location()
}

const tocEntries = async () => {
    const documents = new Map()
    const documentFor = index => {
        if (!documents.has(index)) documents.set(index, book.sections[index].createDocument())
        return documents.get(index)
    }
    // A TOC entry's place in its section is estimated from the text before it.
    const shareBefore = async (index, anchor) => {
        const doc = await documentFor(index)
        const target = anchor(doc)
        if (!target?.nodeType || !doc.body) return 0
        const range = doc.createRange()
        range.setStart(doc.body, 0)
        range.setEndBefore(target)
        const total = doc.body.textContent.length
        return total ? range.toString().length / total : 0
    }
    // Null for a link that leads nowhere in the book, which the contents then show as inert.
    const fractionOf = async href => {
        try {
            const { index, anchor } = book.resolveHref(href)
            const start = progress.sectionFractions[index] ?? 0
            const end = progress.sectionFractions[index + 1] ?? start
            if (!href.includes('#') || end <= start) return start
            return start + (end - start) * await shareBefore(index, anchor)
        } catch (error) {
            console.warn(error)
            return null
        }
    }
    const entries = []
    const walk = async (items, level) => {
        for (const item of items ?? []) {
            const href = item.href ?? ''
            entries.push({
                title: item.label?.trim() ?? '',
                href,
                level,
                fraction: await fractionOf(href),
            })
            await walk(item.subitems, level + 1)
        }
    }
    await walk(book.toc, 0)
    return entries
}

// A title or a name is a string, or a map from language to string when the book gives it in several.
const plainText = value => {
    if (typeof value === 'string') return value.trim() || null
    if (value && typeof value === 'object') return plainText(Object.values(value)[0])
    return null
}

// What the library shows of a book. The first author, as the shelf has room for one.
const bookInfo = () => {
    const metadata = book?.metadata ?? {}
    const author = [].concat(metadata.author ?? [])[0]
    return { title: plainText(metadata.title), author: plainText(author?.name ?? author) }
}

// The cover as base64, or null for a book that has none or whose cover can't be read.
const coverBase64 = () => enqueue(async () => {
    const blob = await book?.getCover?.().catch(() => null)
    if (!blob) return null
    const url = await new Promise((resolve, reject) => {
        const reader = new FileReader()
        reader.onload = () => resolve(reader.result)
        reader.onerror = () => reject(reader.error)
        reader.readAsDataURL(blob)
    })
    return url.slice(url.indexOf(',') + 1)
})

globalThis.readmeBridge = {
    open,
    bookInfo,
    cover: coverBase64,
    currentDocument,
    location,
    // Where the reader is, which a layout change goes back to. See `place`.
    place: () => place,
    settled,
    next: () => navigate(() => view.next()),
    previous: () => navigate(() => view.prev()),
    goToCFI: cfi => navigate(() => view.goTo(cfi), cfi),
    goToFraction: fraction => navigate(() => view.goToFraction(fraction)),
    // Whether the link led anywhere in the book, and where the book went, or null if it was already
    // there. foliate's goTo answers nothing for a link it can't follow.
    goToHref: async href => {
        let resolved = false
        const location = await navigate(async () => { resolved = !!(await view.goTo(href)) })
        return { resolved, location }
    },
    goToPage: page => navigate(() => goToPage(page)),
    goToStart: () => navigate(() => goToEdge(false)),
    goToEnd: () => navigate(() => goToEdge(true)),
    toc: tocEntries,
    // Replaces what's drawn with `cfis`, in `color`.
    setHighlights: async (cfis, color) => {
        const removed = [...highlights].filter(cfi => !cfis.includes(cfi))
        highlights.clear()
        for (const cfi of cfis) highlights.add(cfi)
        highlightColor = color
        // The old ones are redrawn too, for the new colour.
        for (const cfi of removed) await view.deleteAnnotation({ value: cfi }).catch(error => console.warn(error))
        for (const cfi of cfis) await view.addAnnotation({ value: cfi }).catch(error => console.warn(error))
    },
    // Sets the reading marker at the start of `cfi`, or takes it away with null, and answers with the
    // point kept and whether the spread on show now holds it. That's the app's to note, so it isn't
    // told again as a move.
    setMarker: cfi => {
        marker = cfi ? collapse(cfi) : null
        const current = location()
        if (current) {
            lastPostedCFI = current.cfi
            lastPostedKey = postKey(current)
        }
        return { cfi: marker, isMarked: current?.isMarked ?? false }
    },
    addHighlight: async cfi => {
        highlights.add(cfi)
        await view.addAnnotation({ value: cfi })
    },
    removeHighlight: async cfi => {
        highlights.delete(cfi)
        await view.deleteAnnotation({ value: cfi })
    },
    clearSelection: () => view.deselect(),
    applyStyles: (css, columns, width) => enqueue(() => holdingPlace(() => setLayout(css, columns, width))),
    // Called when Swift resizes the view. The page learns its new size a little later.
    resized: async width => {
        for (let i = 0; i < 20 && Math.abs(innerWidth - width) >= 1; i++)
            await new Promise(resolve => setTimeout(resolve, 25))
        scheduleRelayout()
    },
}

globalThis.webkit?.messageHandlers?.readme?.postMessage(JSON.stringify({ type: 'ready', load: new URLSearchParams(globalThis.location.search).get('load') }))
