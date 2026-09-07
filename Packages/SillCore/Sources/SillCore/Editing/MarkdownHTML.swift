import Foundation

/// Renders a note as an HTML fragment, for the rich side of the pasteboard.
///
/// Copying puts the Markdown itself on the pasteboard as plain text; this is the second flavour,
/// so that somewhere like Slack or Google Docs receives a real list instead of a line starting
/// with a hyphen. The vocabulary is the one the toolbar produces and the editor highlights —
/// headings, the list kinds `ListLine` parses, and `**bold**` / `*italic*` / `` `code` ``.
public enum MarkdownHTML {
    public static func fragment(from markdown: String) -> String {
        var out = Builder()
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>" + paragraph.joined(separator: "<br>") + "</p>")
            paragraph = []
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.allSatisfy(\.isWhitespace) {
                flushParagraph()
                out.closeLists()
                continue
            }
            if let heading = HeadingLine(line) {
                flushParagraph()
                out.closeLists()
                out.append("<h\(heading.level)>\(inline(heading.content))</h\(heading.level)>")
                continue
            }
            if let item = ListLine(text: line, at: 0) {
                flushParagraph()
                out.item(
                    checkbox(item) + inline(item.content),
                    kind: item.isNumbered ? .ordered : .unordered, indent: item.indentWidth)
                continue
            }
            out.closeLists()
            paragraph.append(inline(line))
        }
        flushParagraph()
        out.closeLists()
        return out.html
    }

    // MARK: - Inline

    /// Reuses the editor's own span pass, so the copy and the screen can never disagree about
    /// where a `**` ends. Headings are the one place they differ: the editor leaves their inline
    /// spans alone to keep two fonts from competing, which HTML has no reason to do.
    private static func inline(_ text: String) -> String {
        let source = text as NSString
        var html = ""
        var index = 0
        for span in MarkdownHighlighting.spans(in: text) {
            if span.range.location > index {
                html += escape(source.substring(with: NSRange(location: index, length: span.range.location - index)))
            }
            let body = escape(source.substring(with: span.range))
            switch span.style {
            case .marker: break  // the delimiters themselves are what HTML replaces
            case .bold: html += "<strong>\(body)</strong>"
            case .italic: html += "<em>\(body)</em>"
            case .code: html += "<code>\(body)</code>"
            case .heading: html += body
            }
            index = NSMaxRange(span.range)
        }
        if index < source.length {
            html += escape(source.substring(from: index))
        }
        return html
    }

    /// A task item keeps its state as a box, which survives a paste anywhere. An HTML checkbox
    /// input does not: most editors drop it, and the checked state with it.
    private static func checkbox(_ item: ListLine) -> String {
        switch item.checkbox {
        case .none: ""
        case .unchecked: "☐ "
        case .checked: "☑ "
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Block assembly

    private enum ListKind { case unordered, ordered }

    /// Emits the fragment, keeping the open `<ul>` / `<ol>` nesting in a stack so an indented item
    /// opens a child list *inside* its parent `<li>` — a list hanging directly off another list is
    /// invalid, and a paste target is free to throw the whole fragment away over it.
    private struct Builder {
        private(set) var html = ""
        private var open: [(kind: ListKind, indent: Int)] = []

        mutating func append(_ line: String) {
            html += line
        }

        mutating func item(_ content: String, kind: ListKind, indent: Int) {
            while let last = open.last, last.indent > indent {
                html += "</li>" + tag(closing: last.kind)
                open.removeLast()
            }
            if let last = open.last, last.indent == indent {
                html += "</li>"
                if last.kind != kind {
                    html += tag(closing: last.kind)
                    open.removeLast()
                    html += tag(opening: kind)
                    open.append((kind, indent))
                }
            } else {
                html += tag(opening: kind)
                open.append((kind, indent))
            }
            html += "<li>" + content
        }

        mutating func closeLists() {
            while let last = open.popLast() {
                html += "</li>" + tag(closing: last.kind)
            }
        }

        private func tag(opening kind: ListKind) -> String { kind == .ordered ? "<ol>" : "<ul>" }
        private func tag(closing kind: ListKind) -> String { kind == .ordered ? "</ol>" : "</ul>" }
    }
}

/// `#` … `######` followed by a space. Kept here because HTML is the only place that cares
/// about the heading *level*; the editor treats every heading the same.
private struct HeadingLine {
    let level: Int
    let content: String

    init?(_ line: String) {
        var rest = Substring(line)
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        let hashes = rest.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count), rest.dropFirst(hashes.count).first == " " else { return nil }
        level = hashes.count
        content = String(rest.dropFirst(hashes.count + 1))
    }
}
