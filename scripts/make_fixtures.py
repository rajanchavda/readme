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
    def __init__(self, ident, title, content, subsections=(), in_zip=True):
        self.ident = ident
        self.title = title
        self.content = content
        self.subsections = subsections  # (title, fragment) pairs nested under the chapter
        self.in_zip = in_zip  # False: named in the manifest but missing from the zip

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

    items = "\n".join(item(chapter) for chapter in chapters)
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
    spine = "\n".join(f'<itemref idref="{c.ident}"/>' for c in chapters)
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
    encryption=None, corrupt=(),
):
    path = OUT / name
    with zipfile.ZipFile(path, "w") as archive:
        write_entry(archive, "mimetype", "application/epub+zip", zipfile.ZIP_STORED)
        write_entry(archive, "META-INF/container.xml", CONTAINER)
        if encryption:
            write_entry(archive, "META-INF/encryption.xml", encryption)
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


def drm_book():
    rng = random.Random(3)
    cipher = rng.randbytes(8192)
    write_epub(
        "drm.epub",
        "DRM Book",
        [Chapter("ch1", "Locked", cipher)],
        encryption=DRM_ENCRYPTION,
    )


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    long_book()
    write_epub("no-cover.epub", "No Cover Book", short_chapters(random.Random(4)))
    broken_chapter_book()
    write_epub("no-toc.epub", "No TOC Book", short_chapters(random.Random(5)), has_toc=False)
    scripted_book()
    remote_image_book()
    drm_book()
    (OUT / "not-an-epub.epub").write_bytes(random.Random(6).randbytes(4096))


if __name__ == "__main__":
    main()
