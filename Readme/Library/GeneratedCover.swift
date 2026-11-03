import AppKit
import SwiftUI

/// A cover's background and the colour of its lettering.
struct CoverPalette: Equatable {
    var background: Color
    var ink: Color
}

/// The typographic cover a book gets when it has none of its own, from its title and author. The
/// colours come from the book's ID, so a book always has the same ones.
enum GeneratedCover {
    /// The twelve pairs of the library mockup.
    static let palettes: [CoverPalette] = [
        ("#22404F", "#EDE3CF"), ("#E6D9C2", "#5A2F2A"), ("#2A2A2E", "#C9B98F"), ("#A8482F", "#F4E7D2"),
        ("#4F5D3F", "#EFE8D4"), ("#5B1A1F", "#EADAC2"), ("#D9CFA8", "#39452C"), ("#3B3550", "#E5DCCB"),
        ("#C49A4A", "#2C2316"), ("#7A2E3A", "#F1E4D3"), ("#1F4A4A", "#E6E0C8"), ("#C7B5A8", "#3E2C2A"),
    ].map { CoverPalette(background: Color(hex: $0.0), ink: Color(hex: $0.1)) }

    /// FNV-1a over the ID, which unlike `hashValue` is the same on every launch.
    static func palette(for book: Book) -> CoverPalette {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in book.id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return palettes[Int(hash % UInt64(palettes.count))]
    }

    // Proportions of the cover's width, from the mockup.
    static let padding: CGFloat = 0.09
    static let titleSize: CGFloat = 0.135
    static let authorSize: CGFloat = 0.095
    static let lineHeight: CGFloat = 1.08
    /// Where lettering stops shrinking.
    private static let smallestTitle: CGFloat = 0.07
    private static let smallestAuthor: CGFloat = 0.06
    private static let gap: CGFloat = 0.05

    /// Lines of text and the size they are set at.
    struct Lines: Equatable {
        var size: CGFloat
        var lines: [String]
    }

    struct Layout: Equatable {
        var title: Lines
        var author: Lines?
    }

    /// What goes on a cover `width` wide. The author is placed first, in at most two lines, and the title
    /// takes what's left.
    @MainActor
    static func layout(title: String, author: String?, width: CGFloat) -> Layout {
        let inner = width * (1 - 2 * padding)
        let height = width * 1.5 - 2 * width * padding
        let author = author?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let authorLines = author.map {
            fit($0, width: inner, height: width * 0.2, start: width * authorSize, smallest: width * smallestAuthor,
                font: CoverFonts.author)
        }
        let taken = authorLines.map { CGFloat($0.lines.count) * $0.size * lineHeight + width * gap } ?? 0
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled"
        let titleLines = fit(
            title, width: inner, height: height - taken, start: width * titleSize, smallest: width * smallestTitle,
            font: CoverFonts.title)
        return Layout(title: titleLines, author: authorLines)
    }

    /// Sets `text` as large as it will go, down to `smallest`, wrapped at words. A word wider than the
    /// line makes that size fail, so a long word shrinks the lot. Only at the smallest size is a word
    /// broken, and only if it must; and text that still won't fit ends in an ellipsis.
    @MainActor
    static func fit(
        _ text: String, width: CGFloat, height: CGFloat, start: CGFloat, smallest: CGFloat,
        font: (CGFloat) -> NSFont
    ) -> Lines {
        func measure(_ s: String, _ size: CGFloat) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font(size)]).width
        }
        func fits(_ lines: [String], _ size: CGFloat) -> Bool {
            CGFloat(lines.count) * size * lineHeight <= height
        }
        var size = start
        while size > smallest {
            if let lines = wrap(text, width: width, breakingWords: false, measure: { measure($0, size) }), fits(lines, size) {
                return Lines(size: size, lines: lines)
            }
            size *= 0.95
        }
        size = smallest
        var lines = wrap(text, width: width, breakingWords: true, measure: { measure($0, size) }) ?? [text]
        let room = max(1, Int(height / (size * lineHeight)))
        if lines.count > room {
            lines = Array(lines.prefix(room))
            var last = lines[room - 1]
            while !last.isEmpty, measure(last + "…", size) > width {
                last.removeLast()
            }
            lines[room - 1] = last.trimmingCharacters(in: .whitespaces) + "…"
        }
        return Lines(size: size, lines: lines)
    }

    /// Greedy line breaking at spaces. Returns nil when a word is wider than a line and may not be broken.
    /// Without spaces (Japanese, say) the "words" are single characters.
    private static func wrap(_ text: String, width: CGFloat, breakingWords: Bool, measure: (String) -> CGFloat) -> [String]? {
        var lines: [String] = []
        for paragraph in text.split(whereSeparator: \.isNewline) {
            var current = ""
            let (words, joiner) = words(of: String(paragraph))
            for word in words {
                let candidate = current.isEmpty ? word : current + joiner + word
                if measure(candidate) <= width {
                    current = candidate
                    continue
                }
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                }
                if measure(word) <= width {
                    current = word
                } else if breakingWords {
                    for character in word {
                        let next = current + String(character)
                        if measure(next) > width, !current.isEmpty {
                            lines.append(current)
                            current = String(character)
                        } else {
                            current = next
                        }
                    }
                } else {
                    return nil
                }
            }
            if !current.isEmpty { lines.append(current) }
        }
        return lines.isEmpty ? [""] : lines
    }

    /// Words split at spaces, and what joins them again. Text with no spaces and any CJK in it splits between characters, since
    /// those scripts break anywhere.
    private static func words(of paragraph: String) -> (words: [String], joiner: String) {
        let spaced = paragraph.split(separator: " ").map(String.init)
        guard spaced.count == 1, let only = spaced.first, only.unicodeScalars.contains(where: isCJK) else {
            return (spaced, " ")
        }
        return (only.map(String.init), "")
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: true
        default: false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Color {
    /// `#RRGGBB`.
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(
            .sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
