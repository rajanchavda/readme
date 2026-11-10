#!/usr/bin/env python3
"""Writes the EPUB test fixtures into ReadmeTests/Fixtures.

The output is deterministic (fixed seed, fixed zip timestamps), so running this
again only changes the files if this script changed.

Usage: scripts/make_fixtures.py
"""
import random
import struct
import zipfile
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "ReadmeTests" / "Fixtures"
ZIP_DATE = (2000, 1, 1, 0, 0, 0)
WORDS = (
    "the sea was calm that morning and every sail in the harbour hung still while old "
    "men mended their nets along the quay talking of weather and of ships that never "
    "came home again a gull turned over the water with a slow patient cry"
).split()

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

DRM_ENCRYPTION = """<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes256-cbc"/>
    <enc:CipherData><enc:CipherReference URI="OEBPS/ch1.xhtml"/></enc:CipherData>
  </enc:EncryptedData>
</encryption>
"""

# Font obfuscation, which every reading system undoes with the book's own identifier. It isn't DRM.
OBFUSCATION_ENCRYPTION = """<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
    <enc:CipherData><enc:CipherReference URI="OEBPS/fixture.ttf"/></enc:CipherData>
  </enc:EncryptedData>
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://ns.adobe.com/pdf/enc#RC"/>
    <enc:CipherData><enc:CipherReference URI="OEBPS/other.ttf"/></enc:CipherData>
  </enc:EncryptedData>
</encryption>
"""


def paragraphs(rng, count, words=80):
    return "\n".join(
        "<p>" + " ".join(rng.choice(WORDS) for _ in range(words)) + ".</p>" for _ in range(count)
    )


def xhtml(title, body, head=""):
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head><title>{title}</title>{head}</head>
<body>
{body}
</body>
</html>
"""


def png(width=120, height=180, rgb=(90, 60, 40)):
    def chunk(kind, data):
        checksum = zlib.crc32(kind + data)
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", checksum)

    row = b"\x00" + bytes(rgb) * width
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(row * height, 9))
        + chunk(b"IEND", b"")
    )


class Chapter:
    def __init__(self, ident, title, content, subsections=(), in_zip=True, linear=True):
        self.ident = ident
        self.title = title
        self.content = content
        self.subsections = subsections  # (title, fragment) pairs nested under the chapter
        self.in_zip = in_zip  # False: named in the manifest but missing from the zip
        self.linear = linear  # False: linear="no" in the spine, as endnotes often are

    @property
    def href(self):
        return f"{self.ident}.xhtml"


def nav_document(chapters):
    def item(chapter):
        nested = ""
        if chapter.subsections:
            links = "".join(
                f'<li><a href="{chapter.href}#{fragment}">{title}</a></li>'
                for title, fragment in chapter.subsections
            )
            nested = f"<ol>{links}</ol>"
        return f'<li><a href="{chapter.href}">{chapter.title}</a>{nested}</li>'

    items = "\n".join(item(chapter) for chapter in chapters if chapter.linear)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Contents</title></head>
<body><nav epub:type="toc"><ol>
{items}
</ol></nav></body>
</html>
"""


def package(title, chapters, has_toc, has_cover, extra_manifest):
    manifest = [
        f'<item id="{c.ident}" href="{c.href}" media-type="application/xhtml+xml"/>'
        for c in chapters
    ]
    if has_toc:
        manifest.append(
            '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
        )
    if has_cover:
        manifest.append(
            '<item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>'
        )
    manifest.extend(extra_manifest)
    spine = "\n".join(
        f'<itemref idref="{c.ident}"' + ("" if c.linear else ' linear="no"') + "/>" for c in chapters
    )
    manifest_xml = "\n".join(manifest)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="id">urn:readme:fixture:{title.replace(' ', '-').lower()}</dc:identifier>
<dc:title>{title}</dc:title>
<dc:creator>Fixture Author</dc:creator>
<dc:language>en</dc:language>
<meta property="dcterms:modified">2000-01-01T00:00:00Z</meta>
</metadata>
<manifest>
{manifest_xml}
</manifest>
<spine>
{spine}
</spine>
</package>
"""


def write_entry(archive, name, data, compress=zipfile.ZIP_DEFLATED):
    info = zipfile.ZipInfo(name, ZIP_DATE)
    info.compress_type = compress
    info.external_attr = 0o644 << 16
    archive.writestr(info, data)


def write_epub(
    name, title, chapters, has_toc=True, has_cover=False, extra_files=None, extra_manifest=(),
    encryption=None, corrupt=(), meta_inf=None, comment=b"",
):
    path = OUT / name
    with zipfile.ZipFile(path, "w") as archive:
        archive.comment = comment
        write_entry(archive, "mimetype", "application/epub+zip", zipfile.ZIP_STORED)
        write_entry(archive, "META-INF/container.xml", CONTAINER)
        if encryption:
            write_entry(archive, "META-INF/encryption.xml", encryption)
        for file_name, data in (meta_inf or {}).items():
            write_entry(archive, f"META-INF/{file_name}", data)
        write_entry(
            archive,
            "OEBPS/content.opf",
            package(title, chapters, has_toc, has_cover, extra_manifest),
        )
        if has_toc:
            write_entry(archive, "OEBPS/nav.xhtml", nav_document(chapters))
        if has_cover:
            write_entry(archive, "OEBPS/cover.png", png(), zipfile.ZIP_STORED)
        for chapter in chapters:
            if chapter.in_zip:
                write_entry(archive, f"OEBPS/{chapter.href}", chapter.content)
        for file_name, data in (extra_files or {}).items():
            write_entry(archive, f"OEBPS/{file_name}", data)
        offsets = {
            info.filename: (info.header_offset, info.compress_size)
            for info in archive.infolist()
            if info.filename in {f"OEBPS/{c}" for c in corrupt}
        }
    # Overwrite the compressed bytes in place, so the entry is listed but cannot be inflated.
    with open(path, "r+b") as file:
        for entry, (offset, size) in offsets.items():
            file.seek(offset + 26)
            name_length, extra_length = struct.unpack("<HH", file.read(4))
            file.seek(offset + 30 + name_length + extra_length)
            file.write(b"\xff" * size)


def set_declared_size(path, entry, size=None, compressed_size=None):
    """Changes what the zip's central directory says about an entry, so the entry lies about itself."""
    data = bytearray(path.read_bytes())
    position = data.rfind(b"PK\x01\x02")
    while position >= 0:
        name_length = struct.unpack_from("<H", data, position + 28)[0]
        if bytes(data[position + 46 : position + 46 + name_length]) == entry.encode():
            if compressed_size is not None:
                struct.pack_into("<I", data, position + 20, compressed_size)
            if size is not None:
                struct.pack_into("<I", data, position + 24, size)
            path.write_bytes(data)
            return
        position = data.rfind(b"PK\x01\x02", 0, position)
    raise ValueError(entry)


def long_book():
    rng = random.Random(1)
    chapters = []
    for number in range(1, 41):
        title = f"Chapter {number}"
        body = f"<h1>{title}</h1>\n{paragraphs(rng, 20)}"
        subsections = ()
        if number == 5:
            part = f"{title}, Part Two"
            body += f'\n<h2 id="part-two">{part}</h2>\n{paragraphs(rng, 20)}'
            subsections = ((part, "part-two"),)
        else:
            body += f"\n{paragraphs(rng, 20)}"
        chapters.append(Chapter(f"ch{number}", title, xhtml(title, body), subsections))
    write_epub("long.epub", "Long Fixture Book", chapters, has_cover=True)


def search_book():
    # Known words among the filler: "Elena" three times in the readable chapters and once in the
    # non-linear notes, "Café" once, and "Zanzibar" only in the notes.
    rng = random.Random(7)

    def chapter(ident, title, lines, linear=True):
        body = f"<h1>{title}</h1>\n" + "\n".join(
            f"{paragraphs(rng, 4)}\n<p>{line}</p>" for line in lines
        ) + f"\n{paragraphs(rng, 4)}"
        return Chapter(ident, title, xhtml(title, body), linear=linear)

    chapters = [
        chapter("ch1", "The Harbour", [
            "The girl they called Elena stood at the rail.",
            "Elena had never seen the sea so still.",
        ]),
        chapter("ch2", "The Letter", [
            "They met at the Café Lumière before the bells.",
            "When Elena came down the stairs she found the letter.",
        ]),
        chapter("ch3", "The Road", ["Nobody in the village remembered the road."]),
        chapter("notes", "Notes", ["Elena is a name from Zanzibar."], linear=False),
    ]
    write_epub("search.epub", "Search Fixture Book", chapters)


def short_chapters(rng, count=3):
    return [
        Chapter(
            f"ch{number}",
            f"Chapter {number}",
            xhtml(f"Chapter {number}", f"<h1>Chapter {number}</h1>\n{paragraphs(rng, 12)}"),
        )
        for number in range(1, count + 1)
    ]


def broken_chapter_book():
    """Each failure mode here used to stall foliate's paginator, or could."""
    rng = random.Random(2)
    good = lambda title: xhtml(title, f"<h1>{title}</h1>\n{paragraphs(rng, 12)}")
    chapters = [
        Chapter("ch1", "Good Start", good("Good Start")),
        Chapter("ch2", "Missing File", "", in_zip=False),
        Chapter("ch3", "Malformed", "<html><body><p>Unclosed <b>markup<p>and <i>more"),
        Chapter(
            "ch4",
            "No Body",
            '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>x</title></head></html>',
        ),
        Chapter("ch5", "Empty File", ""),
        Chapter("ch6", "Corrupt Entry", good("Corrupt Entry")),
        Chapter("ch7", "Good End", good("Good End")),
    ]
    write_epub("broken-chapter.epub", "Broken Chapter Book", chapters, corrupt=["ch6.xhtml"])


def scripted_book():
    script = """
var mark = 'PWNED';
document.title = mark;
try { parent.document.title = mark; } catch (e) {}
try { top.document.title = mark; } catch (e) {}
try { parent.__pwned = true; } catch (e) {}
try { window.webkit.messageHandlers.readme.postMessage(mark); } catch (e) {}
try { parent.webkit.messageHandlers.readme.postMessage(mark); } catch (e) {}
"""
    inline = f"<script>//<![CDATA[\n{script}\n//]]></script>"
    body = (
        '<h1 onclick="parent.__pwned = true">Scripted Chapter</h1>\n'
        '<p>Plain text that should still render.</p>\n'
        '<img src="missing.png" alt="" onerror="parent.__pwned = true; document.title = \'PWNED\'"/>\n'
        '<iframe srcdoc="&lt;script&gt;parent.parent.__pwned = true&lt;/script&gt;"></iframe>\n'
    )
    head = inline + '<script src="evil.js"></script>'
    content = xhtml("Scripted Chapter", body, head).replace(
        "<body>", "<body onload=\"parent.__pwned = true; document.title = 'PWNED'\">"
    )
    write_epub(
        "scripted.epub",
        "Scripted Book",
        [Chapter("ch1", "Scripted Chapter", content)],
        extra_files={"evil.js": script},
        extra_manifest=['<item id="evil" href="evil.js" media-type="application/javascript"/>'],
    )


def remote_image_book():
    body = (
        "<h1>Remote Image</h1>\n"
        '<p><img id="remote" src="https://www.apple.com/favicon.ico" alt=""/></p>\n'
    )
    write_epub(
        "remote-image.epub",
        "Remote Image Book",
        [Chapter("ch1", "Remote Image", xhtml("Remote Image", body))],
    )


def link_hints_book():
    """Hints that may open connections without passing the content rule list."""
    hints = (
        '<link rel="preconnect" href="https://www.apple.com/"/>'
        '<link rel="DNS-Prefetch" href="https://www.apple.com/"/>'
        '<link rel="prefetch" href="https://www.apple.com/a"/>'
        '<link rel="preload stylesheet" as="style" href="https://www.apple.com/b.css"/>'
    )
    head = hints + '<link rel="stylesheet" href="style.css"/>'
    body = (
        "<h1>Link Hints</h1>\n"
        "<p>Plain text.</p>\n"
        '<iframe id="inner" src="inner.xhtml"></iframe>\n'
    )
    write_epub(
        "link-hints.epub",
        "Link Hints Book",
        [Chapter("ch1", "Link Hints", xhtml("Link Hints", body, head))],
        extra_files={
            "style.css": "h1 { color: rgb(1, 2, 3); }\n",
            "inner.xhtml": xhtml("Inner", "<p>Inner.</p>", hints),
        },
        extra_manifest=[
            '<item id="style" href="style.css" media-type="text/css"/>',
            '<item id="inner" href="inner.xhtml" media-type="application/xhtml+xml"/>',
        ],
    )


def drm_book():
    rng = random.Random(3)
    cipher = rng.randbytes(8192)
    write_epub(
        "drm.epub",
        "DRM Book",
        [Chapter("ch1", "Locked", cipher)],
        encryption=DRM_ENCRYPTION,
    )


def locked_books():
    """Books that must be turned away as protected, each in a different way."""
    encryption = "META-INF/encryption.xml"

    def make(name, **options):
        write_epub(name, "Locked", short_chapters(random.Random(9)), **options)
        return OUT / name

    make("drm-bad-xml.epub", encryption="<encryption><unclosed")
    set_declared_size(
        make("drm-bad-size.epub", encryption=DRM_ENCRYPTION), encryption, size=len(DRM_ENCRYPTION) + 7)
    # Claims to inflate to nearly 4 GB, which must never be allocated.
    set_declared_size(
        make("drm-bomb.epub", encryption=DRM_ENCRYPTION), encryption, size=0xFFFFFFF0)
    # Claims to be stored beyond the end of the file.
    set_declared_size(
        make("drm-past-end.epub", encryption=DRM_ENCRYPTION), encryption, compressed_size=500_000)
    make("drm-rights.epub", meta_inf={"rights.xml": "<rights/>"})
    make("drm-lcp.epub", meta_inf={"license.lcpl": "{}"})
    make("drm-sinf.epub", meta_inf={"sinf.xml": "<sinf/>"})


def comment_book():
    """A good book whose zip comment holds what looks like an end record."""
    write_epub(
        "pk-comment.epub", "Comment Book", short_chapters(random.Random(10)),
        comment=b"PK\x05\x06" + b"x" * 30)


def obfuscated_book():
    """Obfuscated fonts and nothing else listed as encrypted, so it must open as an ordinary book."""
    write_epub(
        "obfuscated.epub",
        "Obfuscated Fonts Book",
        short_chapters(random.Random(8)),
        encryption=OBFUSCATION_ENCRYPTION,
    )


def plain_zip():
    """A zip that holds no book: no mimetype and no container.xml."""
    with zipfile.ZipFile(OUT / "plain-zip.epub", "w") as archive:
        write_entry(archive, "notes/hello.txt", "Hello, this is not a book.\n")


def spreads_book():
    """Chapters of rising length, so several of them end on a half-empty two-page spread."""
    rng = random.Random(7)
    chapters = []
    for number, count in enumerate((3, 5, 7, 9, 11, 13, 15), start=1):
        title = f"Chapter {number}"
        chapters.append(
            Chapter(f"ch{number}", title, xhtml(title, f"<h1>{title}</h1>\n{paragraphs(rng, count)}"))
        )
    write_epub("spreads.epub", "Spreads Book", chapters)


def tiny_font():
    """A TrueType font whose every printable character is one wide box.

    It's far wider than any system font, so text reflows visibly if the font arrives late.
    """
    units = 1000
    box = struct.pack(">hhhhh", 1, 0, 0, 800, 700)  # one contour and its bounds
    box += struct.pack(">HH", 3, 0)  # last point of the contour, no instructions
    box += bytes([0x01] * 4)  # four on-curve points with 16-bit coordinates
    box += struct.pack(">hhhh", 0, 800, 0, -800)  # x deltas
    box += struct.pack(">hhhh", 0, 0, 700, 0)  # y deltas
    box += b"\x00" * (-len(box) % 4)
    segments = struct.pack(
        ">HHHHHHHHHHHHHHHH",
        4, 16 + 16, 0,  # format, length, language
        4, 4, 1, 0,  # twice the segment count, then the search fields
        126, 0xFFFF,  # segment ends
        0,  # reserved
        32, 0xFFFF,  # segment starts
        (1 - 32) & 0xFFFF, 1,  # id deltas, so all of 32 to 126 map to glyph 1
        0, 0,  # range offsets
    )
    cmap = struct.pack(">HHHHI", 0, 1, 3, 1, 12) + segments
    name_text = "Fixture".encode("utf-16-be")
    name = struct.pack(">HHH", 0, 2, 6 + 24)
    name += struct.pack(">HHHHHH", 3, 1, 0x409, 1, len(name_text), 0)
    name += struct.pack(">HHHHHH", 3, 1, 0x409, 4, len(name_text), 0)
    name += name_text
    head = struct.pack(
        ">IIIIHHQQhhhhHHhhh",
        0x00010000, 0x00010000, 0, 0x5F0F3CF5, 0, units, 0, 0,
        0, 0, 800, 700, 0, 8, 2, 0, 0,
    )
    hhea = struct.pack(
        ">IhhhHhhhhhhhhhhhH",
        0x00010000, 800, -200, 0, units, 0, 0, 800, 1, 0, 0, 0, 0, 0, 0, 0, 2,
    )
    maxp = struct.pack(">IHHHHHHHHHHHHHH", 0x00010000, 2, 4, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0)
    os2 = struct.pack(
        ">HhHHHhhhhhhhhhhh10sIIII4sHHHhhhHH",
        1, units, 400, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, b"\x00" * 10, 0, 0, 0, 0,
        b"NONE", 0x40, 32, 126, 800, -200, 0, 800, 200,
    ) + struct.pack(">II", 1, 0)
    post = struct.pack(">IIhhIIIII", 0x00030000, 0, -100, 50, 0, 0, 0, 0, 0)
    tables = {
        b"OS/2": os2,
        b"cmap": cmap,
        b"glyf": box,
        b"head": head,
        b"hhea": hhea,
        b"hmtx": struct.pack(">HhHh", units, 0, units, 0),
        b"loca": struct.pack(">HHH", 0, 0, len(box) // 2),
        b"maxp": maxp,
        b"name": name,
        b"post": post,
    }

    def checksum(data):
        padded = data + b"\x00" * (-len(data) % 4)
        return sum(struct.unpack(f">{len(padded) // 4}I", padded)) & 0xFFFFFFFF

    directory = struct.pack(">IHHHH", 0x00010000, len(tables), 128, 3, len(tables) * 16 - 128)
    offset = len(directory) + 16 * len(tables)
    body = b""
    for tag, data in tables.items():
        directory += struct.pack(">4sIII", tag, checksum(data), offset + len(body), len(data))
        body += data + b"\x00" * (-len(data) % 4)
    font = bytearray(directory + body)
    # head's checkSumAdjustment, which is taken over the whole file.
    head_offset = offset + sum(
        len(data) + (-len(data) % 4) for tag, data in tables.items() if tag < b"head"
    )
    struct.pack_into(">I", font, head_offset + 8, (0xB1B0AFBA - checksum(bytes(font))) & 0xFFFFFFFF)
    return bytes(font)


def late_resources_book():
    """Everything here can land after navigation: a web font and large images with no set size."""
    rng = random.Random(8)
    chapters = []
    for number in range(1, 4):
        title = f"Chapter {number}"
        body = (
            f"<h1>{title}</h1>\n{paragraphs(rng, 2)}\n"
            f'<p><img src="plate{number}.png" alt=""/></p>\n{paragraphs(rng, 6)}\n'
            # Not waited for by the chapter's load event, and it moves the text after it.
            f'<p><img loading="lazy" src="plate{number}.png" alt=""/></p>\n{paragraphs(rng, 3)}\n'
            f'<p><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 300">'
            f'<image href="plate{number}.png" width="300" height="300"/></svg></p>\n'
            f"{paragraphs(rng, 2)}"
        )
        head = '<link rel="stylesheet" href="fixture.css"/>'
        chapters.append(Chapter(f"ch{number}", title, xhtml(title, body, head)))
    plates = {
        # Large enough to take a while to decode, though one colour keeps the file small.
        f"plate{number}.png": png(4000, 3000, (40 * number, 90, 200 - 40 * number))
        for number in range(1, 4)
    }
    write_epub(
        "late-resources.epub",
        "Late Resources Book",
        chapters,
        extra_files={
            **plates,
            "fixture.ttf": tiny_font(),
            "fixture.css": (
                '@font-face { font-family: "Fixture"; src: url("fixture.ttf"); }\n'
                'body { font-family: "Fixture", serif; }\n'
            ),
        },
        extra_manifest=[
            *(
                f'<item id="plate{number}" href="plate{number}.png" media-type="image/png"/>'
                for number in range(1, 4)
            ),
            '<item id="font" href="fixture.ttf" media-type="font/ttf"/>',
            '<item id="css" href="fixture.css" media-type="text/css"/>',
        ],
    )


def wide_content_book():
    """Content that won't wrap by itself, as real books have: verse set in <pre>, a long web
    address, a very long word, text held on one line, a wide table and a fixed-width block, with
    the book's own styles asking for no wrapping."""
    rng = random.Random(7)
    verse = "\n".join(
        "     " + " ".join(rng.choice(WORDS) for _ in range(14)) for _ in range(6)
    )
    risky = [
        f"<pre>{verse}</pre>",
        "<p>See https://www.gutenberg.org/ebooks/2701/the-whole-of-the-project-gutenberg-license-"
        "included-with-this-ebook-or-online-at-www.gutenberg.org/license for more.</p>",
        "<p>Pneumonoultramicroscopicsilicovolcanoconiosisandantidisestablishmentarianismtogether"
        "withfloccinaucinihilipilification is a word.</p>",
        '<p><span style="white-space: nowrap">'
        + " ".join(rng.choice(WORDS) for _ in range(24)) + "</span></p>",
        '<p class="nowrap">' + " ".join(rng.choice(WORDS) for _ in range(30)) + "</p>",
        '<table width="900"><tr>'
        + "".join(f"<td>{' '.join(rng.choice(WORDS) for _ in range(6))}</td>" for _ in range(6))
        + "</tr></table>",
        '<div style="width: 900px">' + " ".join(rng.choice(WORDS) for _ in range(40)) + "</div>",
    ]
    head = (
        "<style>pre { white-space: pre; } p { overflow-wrap: normal; word-break: keep-all; } "
        ".nowrap { white-space: nowrap; }</style>"
    )
    chapters = []
    for number in range(1, 4):
        title = f"Chapter {number}"
        parts = [f"<h1>{title}</h1>"]
        for block in risky:
            parts.append(paragraphs(rng, 2, words=60))
            parts.append(block)
        parts.append(paragraphs(rng, 2, words=60))
        chapters.append(Chapter(f"ch{number}", title, xhtml(title, "\n".join(parts), head)))
    write_epub("wide-content.epub", "Wide Content Book", chapters)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    spreads_book()
    late_resources_book()
    long_book()
    search_book()
    write_epub("no-cover.epub", "No Cover Book", short_chapters(random.Random(4)))
    broken_chapter_book()
    write_epub("no-toc.epub", "No TOC Book", short_chapters(random.Random(5)), has_toc=False)
    scripted_book()
    remote_image_book()
    link_hints_book()
    drm_book()
    obfuscated_book()
    locked_books()
    comment_book()
    plain_zip()
    wide_content_book()
    (OUT / "not-an-epub.epub").write_bytes(random.Random(6).randbytes(4096))


if __name__ == "__main__":
    main()
