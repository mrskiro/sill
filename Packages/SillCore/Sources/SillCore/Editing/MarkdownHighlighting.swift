import Foundation

/// One styled run inside a paragraph. Ranges are UTF-16 offsets relative to the paragraph,
/// and never overlap, so a renderer can apply them in order without resolving conflicts.
public struct MarkdownSpan: Equatable, Sendable {
    /// What the run is. The renderer owns the fonts and colours; this only names the role.
    public enum Style: Equatable, Sendable {
        case heading
        case bold
        case italic
        case code
        /// The Markdown characters themselves (`#`, `**`, `` ` ``, `- `, `1. `, `[ ]`).
        /// They stay on screen — this only dims them so the prose stands out.
        case marker
    }

    public var range: NSRange
    public var style: Style

    public init(range: NSRange, style: Style) {
        self.range = range
        self.style = style
    }
}

/// Turns one paragraph of Markdown into styled runs, without touching the text. The editor
/// renders the result; the stored note stays the exact string the user typed.
///
/// The vocabulary is deliberately what the formatting toolbar can produce: ATX headings, the
/// list markers `ListLine` parses, and `**bold**` / `*italic*` / `` `code` ``. Inline spans are
/// not scanned inside a heading — the heading already carries its own emphasis, and letting the
/// two compete would mean deciding which font wins.
public enum MarkdownHighlighting {
    /// `paragraph` may keep its trailing newline; it is never part of a span.
    public static func spans(in paragraph: String) -> [MarkdownSpan] {
        let text = paragraph as NSString
        let end = text.hasSuffix("\n") ? text.length - 1 : text.length
        guard end > 0 else { return [] }

        var spans: [MarkdownSpan] = []
        let indent = leadingWhitespaceLength(in: text, limit: end)

        // Heading: dim the "### " and style the rest of the line as one run.
        let hashes = countHashes(in: text, from: indent, limit: end)
        if hashes > 0, hashes <= 6, indent + hashes < end,
            text.character(at: indent + hashes) == UInt16(UnicodeScalar(" ").value)
        {
            spans.append(MarkdownSpan(range: NSRange(location: indent, length: hashes + 1), style: .marker))
            let content = indent + hashes + 1
            if content < end {
                spans.append(MarkdownSpan(range: NSRange(location: content, length: end - content), style: .heading))
            }
            return spans
        }

        // List marker: "- ", "1. ", and the "[ ] " that may follow. `ListLine` decides what counts,
        // so "* item" reads as a bullet here exactly as it does when Return continues the list.
        var scanFrom = indent
        if let line = ListLine(text: text.substring(to: end), at: 0), line.markerWidth > 0 {
            spans.append(
                MarkdownSpan(range: NSRange(location: indent, length: line.markerWidth), style: .marker))
            scanFrom = indent + line.markerWidth
        }

        spans.append(contentsOf: inlineSpans(in: text, from: scanFrom, limit: end))
        return spans
    }

    // MARK: - Internals

    /// Left-to-right scan for `**bold**`, `*italic*` and `` `code` ``. The first opener wins and
    /// the scan resumes after its closer, so the runs cannot overlap.
    private static func inlineSpans(in text: NSString, from start: Int, limit: Int) -> [MarkdownSpan] {
        var spans: [MarkdownSpan] = []
        var index = start
        while index < limit {
            guard let opener = delimiter(in: text, at: index, limit: limit),
                let closer = range(of: opener.token, in: text, from: index + opener.width, limit: limit),
                closer > index + opener.width
            else {
                index += 1
                continue
            }
            spans.append(MarkdownSpan(range: NSRange(location: index, length: opener.width), style: .marker))
            spans.append(
                MarkdownSpan(
                    range: NSRange(location: index + opener.width, length: closer - index - opener.width),
                    style: opener.style))
            spans.append(MarkdownSpan(range: NSRange(location: closer, length: opener.width), style: .marker))
            index = closer + opener.width
        }
        return spans
    }

    private static func delimiter(
        in text: NSString, at index: Int, limit: Int
    ) -> (token: String, width: Int, style: MarkdownSpan.Style)? {
        let character = text.character(at: index)
        if character == UInt16(UnicodeScalar("*").value) {
            let isDouble = index + 1 < limit && text.character(at: index + 1) == character
            return isDouble ? ("**", 2, .bold) : ("*", 1, .italic)
        }
        if character == UInt16(UnicodeScalar("`").value) { return ("`", 1, .code) }
        return nil
    }

    /// First occurrence of `token` at or after `from`, staying inside the paragraph. For `*` the
    /// match must not be part of a `**`, so bold and italic never claim each other's markers.
    private static func range(of token: String, in text: NSString, from: Int, limit: Int) -> Int? {
        let width = (token as NSString).length
        var index = from
        while index + width <= limit {
            if text.substring(with: NSRange(location: index, length: width)) == token {
                let doubled =
                    token == "*" && index + 1 < limit
                    && text.character(at: index + 1) == UInt16(UnicodeScalar("*").value)
                if !doubled { return index }
                index += 2
                continue
            }
            index += 1
        }
        return nil
    }

    private static func leadingWhitespaceLength(in text: NSString, limit: Int) -> Int {
        var length = 0
        while length < limit {
            let character = text.character(at: length)
            guard character == UInt16(UnicodeScalar(" ").value) || character == UInt16(UnicodeScalar("\t").value)
            else { break }
            length += 1
        }
        return length
    }

    private static func countHashes(in text: NSString, from start: Int, limit: Int) -> Int {
        var count = 0
        while start + count < limit, text.character(at: start + count) == UInt16(UnicodeScalar("#").value) {
            count += 1
        }
        return count
    }
}
