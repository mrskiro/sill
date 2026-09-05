import Foundation

/// A single replacement to apply to the editor, expressed in UTF-16 offsets
/// (what NSTextView and UITextView use). `selection` is the caret after the edit.
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// Convenience for tests and callers that hold a plain string.
    public func applying(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

/// Keyboard behaviours that make Markdown lists feel native. Pure functions over
/// `(text, selection)`; each returns nil when the default editor behaviour should run.
public enum MarkdownEditing {
    /// Return: continue the current list item. On an empty item, end the list instead.
    public static func insertNewline(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0, let line = ListLine(text: text, at: selection.location) else { return nil }
        let caretInLine = selection.location - line.range.location
        guard caretInLine >= line.markerEnd else { return nil } // caret inside the marker: default newline

        if line.isEmptyItem {
            // "- " + Return → plain empty line.
            let removed = NSRange(location: line.range.location, length: line.markerEnd)
            return TextEdit(range: removed, replacement: "", selection: NSRange(location: line.range.location, length: 0))
        }
        let replacement = "\n" + line.indent + line.nextMarker
        let caret = selection.location + (replacement as NSString).length
        return TextEdit(range: selection, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    /// Tab on a list line: nest it under the previous list item (CommonMark content column).
    public static func indent(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0, let line = ListLine(text: text, at: selection.location) else { return nil }
        let parentColumn = previousListLine(before: line, in: text).map { $0.indentWidth + $0.markerWidth } ?? 2
        let target = max(parentColumn, line.indentWidth + 2)
        return replaceIndent(of: line, with: String(repeating: " ", count: target), selection: selection)
    }

    /// Shift+Tab on a list line: align with the nearest shallower list item, or column 0.
    public static func outdent(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0, let line = ListLine(text: text, at: selection.location), line.indentWidth > 0 else { return nil }
        var target = 0
        var cursor = line
        while let previous = previousListLine(before: cursor, in: text) {
            if previous.indentWidth < line.indentWidth { target = previous.indentWidth; break }
            cursor = previous
        }
        return replaceIndent(of: line, with: String(repeating: " ", count: target), selection: selection)
    }

    /// ⌘Return: toggle `[ ]` / `[x]`; add a checkbox to a bullet or plain line that has none.
    public static func toggleCheckbox(in text: String, selection: NSRange) -> TextEdit? {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
        let caret = selection.location

        if let line = ListLine(text: text, at: selection.location) {
            let markerStart = line.range.location + line.indentWidth
            switch line.checkbox {
            case .unchecked:
                let box = NSRange(location: markerStart + line.bulletWidth, length: 3)
                return TextEdit(range: box, replacement: "[x]", selection: selection)
            case .checked:
                let box = NSRange(location: markerStart + line.bulletWidth, length: 3)
                return TextEdit(range: box, replacement: "[ ]", selection: selection)
            case .none:
                let insertAt = markerStart + line.bulletWidth
                let shifted = caret >= insertAt ? caret + 4 : caret
                return TextEdit(range: NSRange(location: insertAt, length: 0), replacement: "[ ] ", selection: NSRange(location: shifted, length: selection.length))
            }
        }
        // Plain line: prefix it (after any leading whitespace) with "- [ ] ".
        let lineText = nsText.substring(with: lineRange)
        let leading = lineText.prefix(while: { $0 == " " || $0 == "\t" })
        let insertAt = lineRange.location + (String(leading) as NSString).length
        let shifted = caret >= insertAt ? caret + 6 : caret
        return TextEdit(range: NSRange(location: insertAt, length: 0), replacement: "- [ ] ", selection: NSRange(location: shifted, length: selection.length))
    }

    // MARK: - Internals

    private static func replaceIndent(of line: ListLine, with indent: String, selection: NSRange) -> TextEdit {
        let old = NSRange(location: line.range.location, length: line.indentWidth)
        let delta = (indent as NSString).length - line.indentWidth
        let caret = max(line.range.location, selection.location + delta)
        return TextEdit(range: old, replacement: indent, selection: NSRange(location: caret, length: 0))
    }

    private static func previousListLine(before line: ListLine, in text: String) -> ListLine? {
        guard line.range.location > 0 else { return nil }
        return ListLine(text: text, at: line.range.location - 1)
    }
}

/// Parsed shape of one line: `<indent><bullet>[<checkbox> ]<content>`.
struct ListLine {
    enum Checkbox { case none, unchecked, checked }

    let range: NSRange          // full line range excluding the newline
    let indent: String
    let bullet: String          // "- ", "* ", "+ ", or "3. "
    let checkbox: Checkbox
    let content: String

    var indentWidth: Int { (indent as NSString).length }
    var bulletWidth: Int { (bullet as NSString).length }
    var checkboxWidth: Int { checkbox == .none ? 0 : 4 }
    var markerWidth: Int { bulletWidth + checkboxWidth }
    /// Offset within the line where the item's content starts.
    var markerEnd: Int { indentWidth + markerWidth }
    var isEmptyItem: Bool { content.allSatisfy(\.isWhitespace) }

    /// Marker for the following item: numbers increment, checkboxes start unchecked.
    var nextMarker: String {
        var next = bullet
        if let number = Int(bullet.dropLast(2)) { next = "\(number + 1). " }
        return checkbox == .none ? next : next + "[ ] "
    }

    init?(text: String, at location: Int) {
        let nsText = text as NSString
        guard location <= nsText.length else { return nil }
        var lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        let withNewline = nsText.substring(with: lineRange)
        let lineText = withNewline.hasSuffix("\n") ? String(withNewline.dropLast()) : withNewline
        lineRange.length = (lineText as NSString).length

        var rest = Substring(lineText)
        let indent = rest.prefix(while: { $0 == " " || $0 == "\t" })
        rest = rest.dropFirst(indent.count)

        let bullet: String
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            bullet = String(rest.prefix(2))
        } else {
            let digits = rest.prefix(while: \.isNumber)
            let afterDigits = rest.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count <= 9, afterDigits.hasPrefix(". ") else { return nil }
            bullet = String(digits) + ". "
        }
        rest = rest.dropFirst(bullet.count)

        var checkbox = Checkbox.none
        if rest.hasPrefix("[ ] ") {
            checkbox = .unchecked
            rest = rest.dropFirst(4)
        } else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
            checkbox = .checked
            rest = rest.dropFirst(4)
        }

        self.range = lineRange
        self.indent = String(indent)
        self.bullet = bullet
        self.checkbox = checkbox
        self.content = String(rest)
    }
}
