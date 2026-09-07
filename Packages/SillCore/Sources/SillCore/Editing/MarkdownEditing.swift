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

/// The inline spans the formatting buttons can toggle. The value is the Markdown delimiter.
public enum InlineMarker: String, Sendable, CaseIterable {
    case bold = "**"
    case italic = "*"
    case code = "`"

    var token: String { rawValue }
}

/// Keyboard behaviours that make Markdown lists feel native, plus the formatting commands the
/// iOS toolbar and the Mac Format menu share. Pure functions over `(text, selection)`; the
/// keyboard ones return nil when the default editor behaviour should run.
public enum MarkdownEditing {
    /// Return: continue the current list item. On an empty item, end the list instead.
    public static func insertNewline(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0, let line = ListLine(text: text, at: selection.location) else { return nil }
        let caretInLine = selection.location - line.range.location
        guard caretInLine >= line.markerEnd else { return nil }  // caret inside the marker: default newline

        if line.isEmptyItem {
            // "- " + Return → plain empty line.
            let removed = NSRange(location: line.range.location, length: line.markerEnd)
            return TextEdit(
                range: removed, replacement: "", selection: NSRange(location: line.range.location, length: 0))
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
        guard selection.length == 0, let line = ListLine(text: text, at: selection.location), line.indentWidth > 0
        else { return nil }
        var target = 0
        var cursor = line
        while let previous = previousListLine(before: cursor, in: text) {
            if previous.indentWidth < line.indentWidth {
                target = previous.indentWidth
                break
            }
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
                return TextEdit(
                    range: NSRange(location: insertAt, length: 0), replacement: "[ ] ",
                    selection: NSRange(location: shifted, length: selection.length))
            }
        }
        // Plain line: prefix it (after any leading whitespace) with "- [ ] ".
        let lineText = nsText.substring(with: lineRange)
        let leading = lineText.prefix(while: { $0 == " " || $0 == "\t" })
        let insertAt = lineRange.location + (String(leading) as NSString).length
        let shifted = caret >= insertAt ? caret + 6 : caret
        return TextEdit(
            range: NSRange(location: insertAt, length: 0), replacement: "- [ ] ",
            selection: NSRange(location: shifted, length: selection.length))
    }

    // MARK: - Formatting commands (toolbar buttons and the Mac Format menu)

    /// Bullet button: add `- `, swap a numbered marker for it, or drop the marker entirely.
    public static func toggleBullet(in text: String, selection: NSRange) -> TextEdit {
        if let block = blockEdit(in: text, selection: selection, rewrite: { lines, _ in bulletLines(lines) }) {
            return block
        }
        return replaceListMarker(in: text, selection: selection) { line in
            guard let line else { return "- " }
            return line.isNumbered ? "- " : nil
        }
    }

    /// Numbered button: add `n. ` continuing the list above, swap a bullet for it, or drop the marker.
    public static func toggleNumbered(in text: String, selection: NSRange) -> TextEdit {
        if let block = blockEdit(in: text, selection: selection, rewrite: { numberedLines($0, startingAt: $1) }) {
            return block
        }
        if let line = ListLine(text: text, at: selection.location), line.isNumbered {
            let start = line.range.location + line.indentWidth
            return replacing(NSRange(location: start, length: line.markerWidth), with: "", selection: selection)
        }
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
        return replaceListMarker(in: text, selection: selection) { line in
            let indentWidth = line?.indentWidth ?? leadingWhitespaceLength(of: lineRange, in: nsText)
            return "\(nextNumber(before: lineRange.location, indentWidth: indentWidth, in: text)). "
        }
    }

    /// Heading button: strip an existing `#`…`###### ` prefix, or add `# `.
    public static func toggleHeading(in text: String, selection: NSRange) -> TextEdit {
        if let block = blockEdit(in: text, selection: selection, rewrite: { lines, _ in headingLines(lines) }) {
            return block
        }
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
        let start = lineRange.location + leadingWhitespaceLength(of: lineRange, in: nsText)
        let hashes = min(6, countPrefix(Self.hash, from: start, limit: NSMaxRange(lineRange), in: nsText))
        let hasHeading =
            hashes > 0 && start + hashes < nsText.length && nsText.character(at: start + hashes) == Self.space
        let existing = NSRange(location: start, length: hasHeading ? hashes + 1 : 0)
        return replacing(existing, with: hasHeading ? "" : "# ", selection: selection)
    }

    /// Bold / italic / code button: wrap the selection, unwrap it when it is already wrapped,
    /// or drop an empty pair at the caret.
    public static func toggleInline(_ marker: InlineMarker, in text: String, selection: NSRange) -> TextEdit {
        let nsText = text as NSString
        let token = marker.token
        let width = (token as NSString).length

        guard selection.length > 0 else {
            return TextEdit(
                range: selection, replacement: token + token,
                selection: NSRange(location: selection.location + width, length: 0))
        }

        // The markers are inside the selection: "**bold**" selected whole.
        let selected = nsText.substring(with: selection) as NSString
        if selected.length >= 2 * width, selected.hasPrefix(token), selected.hasSuffix(token),
            isCleanPair(
                marker, in: nsText,
                leading: NSRange(location: selection.location, length: width),
                trailing: NSRange(location: NSMaxRange(selection) - width, length: width))
        {
            let inner = selected.substring(with: NSRange(location: width, length: selected.length - 2 * width))
            return TextEdit(
                range: selection, replacement: inner,
                selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }

        // The markers sit just outside the selection: "bold" selected inside "**bold**".
        if let pair = surroundingPair(marker, in: nsText, around: selection) {
            return TextEdit(
                range: pair, replacement: nsText.substring(with: selection),
                selection: NSRange(location: pair.location, length: selection.length))
        }

        return TextEdit(
            range: selection, replacement: token + (selected as String) + token,
            selection: NSRange(location: selection.location + width, length: selection.length))
    }

    // MARK: - Block commands over a multi-line selection

    /// Rewrites every line the selection touches, as one replacement. Returns nil for a caret or a
    /// selection inside a single line, which the per-line paths below handle with their own caret
    /// arithmetic. `rewrite` is given the lines and the number a new ordered list should start at.
    private static func blockEdit(
        in text: String, selection: NSRange, rewrite: ([String], Int) -> [String]
    ) -> TextEdit? {
        guard selection.length > 0 else { return nil }
        let nsText = text as NSString
        let range = nsText.lineRange(for: selection)
        let block = nsText.substring(with: range)
        let newline = block.hasSuffix("\n") ? "\n" : ""
        let lines = String(block.dropLast(newline.count)).components(separatedBy: "\n")
        guard lines.count > 1 else { return nil }

        let indent = leadingWhitespaceLength(of: range, in: nsText)
        let start = nextNumber(before: range.location, indentWidth: indent, in: text)
        let body = rewrite(lines, start).joined(separator: "\n")
        return TextEdit(
            range: range, replacement: body + newline,
            selection: NSRange(location: range.location, length: (body as NSString).length))
    }

    /// Bullet across lines: strip the markers when every non-blank line already has one, otherwise
    /// give them all a `- `. Blank lines are left alone and do not vote.
    private static func bulletLines(_ lines: [String]) -> [String] {
        let items = markedLines(lines)
        let allBulleted = !items.isEmpty && items.allSatisfy { $0.1 != nil && !$0.1!.isNumbered }
        return lines.enumerated().map { index, line in
            guard let (_, parsed) = items.first(where: { $0.0 == index }) else { return line }
            if allBulleted, let parsed { return parsed.indent + parsed.content }
            if let parsed { return parsed.indent + "- " + parsed.afterBullet }
            return insertingAfterIndent("- ", in: line)
        }
    }

    /// Numbered across lines: strip when every non-blank line is already numbered, otherwise
    /// number them in sequence from `start`.
    private static func numberedLines(_ lines: [String], startingAt start: Int) -> [String] {
        let items = markedLines(lines)
        let allNumbered = !items.isEmpty && items.allSatisfy { $0.1?.isNumbered == true }
        var number = start
        return lines.enumerated().map { index, line in
            guard let (_, parsed) = items.first(where: { $0.0 == index }) else { return line }
            if allNumbered, let parsed { return parsed.indent + parsed.content }
            let marker = "\(number). "
            number += 1
            if let parsed { return parsed.indent + marker + parsed.afterBullet }
            return insertingAfterIndent(marker, in: line)
        }
    }

    /// Heading across lines: strip when every non-blank line is already a heading, otherwise add.
    private static func headingLines(_ lines: [String]) -> [String] {
        let items = lines.enumerated().filter { !$0.element.allSatisfy(\.isWhitespace) }
        let allHeadings = !items.isEmpty && items.allSatisfy { headingPrefixLength(of: $0.element) > 0 }
        return lines.enumerated().map { index, line in
            guard items.contains(where: { $0.0 == index }) else { return line }
            let hashes = headingPrefixLength(of: line)
            if allHeadings, hashes > 0 {
                let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
                return String(leading) + String(line.dropFirst(leading.count + hashes))
            }
            return insertingAfterIndent("# ", in: line)
        }
    }

    /// The non-blank lines, paired with their parsed list marker (nil when they have none).
    private static func markedLines(_ lines: [String]) -> [(Int, ListLine?)] {
        lines.enumerated()
            .filter { !$0.element.allSatisfy(\.isWhitespace) }
            .map { ($0.offset, ListLine(text: $0.element, at: 0)) }
    }

    /// Length of a `#`…`###### ` prefix, including its space. 0 when the line is not a heading.
    private static func headingPrefixLength(of line: String) -> Int {
        let text = line as NSString
        let start = leadingWhitespaceLength(of: NSRange(location: 0, length: text.length), in: text)
        let hashes = countPrefix(Self.hash, from: start, limit: text.length, in: text)
        guard hashes > 0, hashes <= 6, start + hashes < text.length,
            text.character(at: start + hashes) == Self.space
        else { return 0 }
        return hashes + 1
    }

    private static func insertingAfterIndent(_ marker: String, in line: String) -> String {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        return leading + marker + line.dropFirst(leading.count)
    }

    // MARK: - Internals

    /// Rewrites the list marker of the line holding the caret. `newBullet` returns the bullet to
    /// write, or nil to remove the whole marker (bullet and checkbox alike).
    private static func replaceListMarker(
        in text: String, selection: NSRange, newBullet: (ListLine?) -> String?
    ) -> TextEdit {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
        guard let line = ListLine(text: text, at: selection.location) else {
            let start = lineRange.location + leadingWhitespaceLength(of: lineRange, in: nsText)
            let bullet = newBullet(nil) ?? ""
            return replacing(NSRange(location: start, length: 0), with: bullet, selection: selection)
        }
        let start = line.range.location + line.indentWidth
        guard let bullet = newBullet(line) else {
            return replacing(NSRange(location: start, length: line.markerWidth), with: "", selection: selection)
        }
        return replacing(NSRange(location: start, length: line.bulletWidth), with: bullet, selection: selection)
    }

    /// Applies a replacement and moves the selection with the text around it.
    private static func replacing(_ range: NSRange, with replacement: String, selection: NSRange) -> TextEdit {
        let delta = (replacement as NSString).length - range.length
        // An offset sitting exactly where the marker goes rides along with it, so the caret on an
        // empty line ends up after the new "- " rather than before it.
        func shift(_ offset: Int) -> Int {
            offset < range.location ? offset : max(range.location, offset + delta)
        }
        let start = shift(selection.location)
        return TextEdit(
            range: range, replacement: replacement,
            selection: NSRange(location: start, length: shift(NSMaxRange(selection)) - start))
    }

    private static let hash = unichar(UnicodeScalar("#").value)
    private static let asterisk = unichar(UnicodeScalar("*").value)
    private static let space = unichar(UnicodeScalar(" ").value)
    private static let tab = unichar(UnicodeScalar("\t").value)

    private static func leadingWhitespaceLength(of lineRange: NSRange, in text: NSString) -> Int {
        var length = 0
        while lineRange.location + length < NSMaxRange(lineRange) {
            let character = text.character(at: lineRange.location + length)
            guard character == Self.space || character == Self.tab else { break }
            length += 1
        }
        return length
    }

    private static func countPrefix(_ character: unichar, from start: Int, limit: Int, in text: NSString) -> Int {
        var count = 0
        while start + count < limit, text.character(at: start + count) == character { count += 1 }
        return count
    }

    /// The number a new item on this line should carry: one past the item above it at the same
    /// indent, or 1 when there is none. Plain text has no renderer to renumber it afterwards.
    private static func nextNumber(before lineStart: Int, indentWidth: Int, in text: String) -> Int {
        guard lineStart > 0, let previous = ListLine(text: text, at: lineStart - 1),
            previous.indentWidth == indentWidth, let number = Int(previous.bullet.dropLast(2))
        else { return 1 }
        return number + 1
    }

    /// A `*` that touches another `*` belongs to a `**` run, not to an italic pair. Without this,
    /// selecting the inner `*bold*` of `**bold**` and tapping Italic would shave one asterisk off
    /// each end and silently demote bold to italic.
    private static func isCleanPair(
        _ marker: InlineMarker, in text: NSString, leading: NSRange, trailing: NSRange
    ) -> Bool {
        guard marker == .italic else { return true }
        for pair in [leading, trailing] {
            if isAsterisk(text, pair.location - 1) || isAsterisk(text, NSMaxRange(pair)) { return false }
        }
        return true
    }

    /// The range of a delimiter pair wrapping `selection` from the outside, or nil when there is
    /// none to remove. Italic reads the asterisk runs instead of matching one character, so that
    /// `***bold***` gives back `**bold**` (a real toggle) while `**bold**` nests into `***bold***`.
    private static func surroundingPair(
        _ marker: InlineMarker, in text: NSString, around selection: NSRange
    ) -> NSRange? {
        if marker == .italic {
            // A selection that itself starts or ends on an asterisk is cutting through the
            // delimiters rather than sitting inside them; there is no pair to take off.
            guard !isAsterisk(text, selection.location), !isAsterisk(text, NSMaxRange(selection) - 1)
            else { return nil }
            let left = asteriskRun(in: text, endingBefore: selection.location)
            let right = asteriskRun(in: text, startingAt: NSMaxRange(selection))
            guard left == right, left % 2 == 1 else { return nil }
            return NSRange(location: selection.location - 1, length: selection.length + 2)
        }
        let width = (marker.token as NSString).length
        let before = NSRange(location: selection.location - width, length: width)
        let after = NSRange(location: NSMaxRange(selection), length: width)
        guard selection.location >= width, NSMaxRange(after) <= text.length,
            text.substring(with: before) == marker.token, text.substring(with: after) == marker.token
        else { return nil }
        return NSRange(location: before.location, length: width + selection.length + width)
    }

    private static func isAsterisk(_ text: NSString, _ index: Int) -> Bool {
        index >= 0 && index < text.length && text.character(at: index) == Self.asterisk
    }

    private static func asteriskRun(in text: NSString, endingBefore index: Int) -> Int {
        var count = 0
        while isAsterisk(text, index - count - 1) { count += 1 }
        return count
    }

    private static func asteriskRun(in text: NSString, startingAt index: Int) -> Int {
        var count = 0
        while isAsterisk(text, index + count) { count += 1 }
        return count
    }

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

    let range: NSRange  // full line range excluding the newline
    let indent: String
    let bullet: String  // "- ", "* ", "+ ", or "3. "
    let checkbox: Checkbox
    let content: String

    var indentWidth: Int { (indent as NSString).length }
    var bulletWidth: Int { (bullet as NSString).length }
    var checkboxWidth: Int { checkbox == .none ? 0 : 4 }
    var markerWidth: Int { bulletWidth + checkboxWidth }
    /// Offset within the line where the item's content starts.
    var markerEnd: Int { indentWidth + markerWidth }
    var isEmptyItem: Bool { content.allSatisfy(\.isWhitespace) }
    var isNumbered: Bool { Int(bullet.dropLast(2)) != nil }

    /// The item with its bullet removed but its checkbox kept, for swapping one marker for another.
    var afterBullet: String {
        switch checkbox {
        case .none: content
        case .unchecked: "[ ] " + content
        case .checked: "[x] " + content
        }
    }

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
