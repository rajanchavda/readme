// Drives <foliate-view> for BookWebView.swift. Every method on `readmeBridge` is called from
// Swift with callAsyncJavaScript and answers with plain JSON-safe values.
import { makeBook } from './foliate/view.js'
import { SectionProgress } from './foliate/progress.js'

const COMMAND_MS = 15000
const SECTION_MS = 10000
const SETTLE_MS = 100
const HIDDEN_SETTLE_MS = 40
const RELAYOUT_MS = 150
const RESOURCES_MS = 5000
const DEFAULT_INLINE_SIZE = 720
// foliate's #container is the view less a 3.5% gutter on each side.
const CONTAINER_SHARE = 0.93

let view = null
let book = null
let progress = null
let latest = null // the last `relocate` detail from foliate
let relocations = 0
let busy = false // true during a command, so its in-between stops aren't reported
let lastPostedCFI = null
let columnCount = 2
let laidOutSize = null
let relayoutTimer = null
let queue = Promise.resolve()

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
    }
}

const post = () => {
    const current = location()
    if (!current || current.cfi === lastPostedCFI) return
    lastPostedCFI = current.cfi
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

// Resolves to the new location, or null if nothing moved.
const navigate = move => enqueue(async () => {
    const before = relocations
    await move()
    await settle()
    if (relocations === before) return null
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
    const fits = Math.ceil(width * CONTAINER_SHARE / DEFAULT_INLINE_SIZE) >= columnCount
    renderer.setAttribute('max-inline-size',
        width > 0 && !fits ? `${Math.floor(width / columnCount)}px` : `${DEFAULT_INLINE_SIZE}px`)
}

const setLayout = (css, columns) => {
    columnCount = Math.max(1, Math.trunc(finite(columns, 2)))
    fitColumns()
    view.renderer.setStyles?.(css ?? '')
}

// Makes a layout change, then goes back to the last place reported, which foliate's own
// re-rendering hasn't moved.
const holdingPlace = async change => {
    const cfi = lastPostedCFI ?? view.lastLocation?.cfi
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

const open = async (url, cfi, css, columns) => {
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
    progress = new SectionProgress(book.sections, 1500, 1600)

    busy = true
    view = document.createElement('foliate-view')
    view.addEventListener('relocate', ({ detail }) => {
        latest = detail
        relocations++
        if (busy) return
        // foliate re-rendering, usually mid-resize, so wait to see where it ends up.
        if (detail.reason === 'anchor') scheduleRelayout()
        else post()
    })
    view.addEventListener('external-link', event => event.preventDefault())
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
    setLayout(css, columns)
    try {
        await view.init({ lastLocation: cfi ?? null })
    } catch (error) {
        console.warn('Could not go to the saved place', error)
    }
    // Going to a place foliate can't find fails quietly, so check that it moved.
    if (!relocations || !currentDocument())
        await view.renderer.goTo({ index: firstSectionIndex(), anchor: 0 })
    if (!relocations) throw new Error('The book could not be displayed')
    await settle()
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
    const fractionOf = async href => {
        try {
            const { index, anchor } = book.resolveHref(href)
            const start = progress.sectionFractions[index] ?? 0
            const end = progress.sectionFractions[index + 1] ?? start
            if (!href.includes('#') || end <= start) return start
            return start + (end - start) * await shareBefore(index, anchor)
        } catch (error) {
            console.warn(error)
            return 0
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

globalThis.readmeBridge = {
    open,
    currentDocument,
    location,
    settled,
    next: () => navigate(() => view.next()),
    previous: () => navigate(() => view.prev()),
    goToCFI: cfi => navigate(() => view.goTo(cfi)),
    goToFraction: fraction => navigate(() => view.goToFraction(fraction)),
    toc: tocEntries,
    applyStyles: (css, columns) => enqueue(() => holdingPlace(() => setLayout(css, columns))),
    // Called when Swift resizes the view. The page learns its new size a little later.
    resized: async width => {
        for (let i = 0; i < 20 && Math.abs(innerWidth - width) >= 1; i++)
            await new Promise(resolve => setTimeout(resolve, 25))
        scheduleRelayout()
    },
}

globalThis.webkit?.messageHandlers?.readme?.postMessage(JSON.stringify({ type: 'ready', load: new URLSearchParams(globalThis.location.search).get('load') }))
