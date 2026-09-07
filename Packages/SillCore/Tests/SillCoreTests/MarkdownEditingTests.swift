import Foundation
import Testing

@testable import SillCore

@Suite struct MarkdownEditingTests {
    /// Builds (text, selection) from a string where one `|` marks the caret and two mark a range.
    private func parse(_ marked: String) -> (String, NSRange) {
        let nsMarked = marked as NSString
        let start = nsMarked.range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "")
        let length = (nsMarked.substring(from: start + 1) as NSString).range(of: "|").location
        return (text, NSRange(location: start, length: length == NSNotFound ? 0 : length))
    }

    private func apply(_ edit: TextEdit?, to text: String) -> String? {
        guard let edit else { return nil }
        var result = edit.applying(to: text) as NSString
        if edit.selection.length > 0 {
            let end = NSRange(location: NSMaxRange(edit.selection), length: 0)
            result = result.replacingCharacters(in: end, with: "|") as NSString
        }
        let start = NSRange(location: edit.selection.location, length: 0)
        return result.replacingCharacters(in: start, with: "|")
    }

    @Test(arguments: [
        ("- item|", "- item\n- |"),
        ("* item|", "* item\n* |"),
        ("- [ ] todo|", "- [ ] todo\n- [ ] |"),
        ("- [x] done|", "- [x] done\n- [ ] |"),
        ("1. first|", "1. first\n2. |"),
        ("9. ninth|\nnext", "9. ninth\n10. |\nnext"),
        ("  - nested|", "  - nested\n  - |"),
        ("- ab|cd", "- ab\n- |cd"),
        ("- |", "|"),
        ("  - [ ] |", "|"),
    ])
    func returnContinuesOrEndsLists(input: String, expected: String) {
        let (text, caret) = parse(input)
        #expect(apply(MarkdownEditing.insertNewline(in: text, selection: caret), to: text) == expected)
    }

    @Test(arguments: ["plain text|", "-no space|", "-|item", "1.|x"])
    func returnFallsBackOutsideLists(input: String) {
        let (text, caret) = parse(input)
        #expect(MarkdownEditing.insertNewline(in: text, selection: caret) == nil)
    }

    @Test func returnWithSelectionUsesDefault() {
        #expect(MarkdownEditing.insertNewline(in: "- item", selection: NSRange(location: 2, length: 3)) == nil)
    }

    @Test(arguments: [
        ("- a\n- b|", "- a\n  - b|"),
        ("1. a\n- b|", "1. a\n   - b|"),
        ("- b|", "  - b|"),
        ("- a\n  - b\n  - c|", "- a\n  - b\n    - c|"),
    ])
    func tabNestsUnderPreviousItem(input: String, expected: String) {
        let (text, caret) = parse(input)
        #expect(apply(MarkdownEditing.indent(in: text, selection: caret), to: text) == expected)
    }

    @Test(arguments: [
        ("- a\n  - b|", "- a\n- b|"),
        ("1. a\n   - b|", "1. a\n- b|"),
        ("- a\n  - b\n    - c|", "- a\n  - b\n  - c|"),
        ("    - x|", "- x|"),
    ])
    func shiftTabAlignsWithShallowerItem(input: String, expected: String) {
        let (text, caret) = parse(input)
        #expect(apply(MarkdownEditing.outdent(in: text, selection: caret), to: text) == expected)
    }

    @Test func tabOutsideListsUsesDefault() {
        let (text, caret) = parse("plain|")
        #expect(MarkdownEditing.indent(in: text, selection: caret) == nil)
        #expect(MarkdownEditing.outdent(in: text, selection: caret) == nil)
    }

    @Test(arguments: [
        ("- [ ] to|do", "- [x] to|do"),
        ("- [x] do|ne", "- [ ] do|ne"),
        ("- [X] do|ne", "- [ ] do|ne"),
        ("- it|em", "- [ ] it|em"),
        ("pl|ain", "- [ ] pl|ain"),
        ("|", "- [ ] |"),
        ("  in|dented", "  - [ ] in|dented"),
        ("|- item", "|- [ ] item"),
    ])
    func commandReturnTogglesCheckbox(input: String, expected: String) {
        let (text, caret) = parse(input)
        #expect(apply(MarkdownEditing.toggleCheckbox(in: text, selection: caret), to: text) == expected)
    }

    // MARK: - Formatting buttons

    @Test(arguments: [
        ("plain|", "- plain|"),
        ("|", "- |"),
        ("- item|", "item|"),
        ("* item|", "item|"),
        ("- [ ] todo|", "todo|"),
        ("1. item|", "- item|"),
        ("1. [x] done|", "- [x] done|"),
        ("  - nested|", "  nested|"),
        ("  in|dented", "  - in|dented"),
    ])
    func bulletButtonAddsSwapsOrRemovesTheMarker(input: String, expected: String) {
        let (text, caret) = parse(input)
        #expect(apply(MarkdownEditing.toggleBullet(in: text, selection: caret), to: text) == expected)
    }

    @Test(arguments: [
        ("plain|", "1. plain|"),
        ("1. item|", "item|"),
        ("1. [ ] todo|", "todo|"),
        ("- item|", "1. item|"),
        ("- [ ] todo|", "1. [ ] todo|"),
        ("1. a\n- b|", "1. a\n2. b|"),
        ("1. a\nplain|", "1. a\n2. plain|"),
        ("- a\n- b|", "- a\n1. b|"),
        ("  - nested|", "  1. nested|"),
    ])
    func numberedButtonContinuesTheListAbove(input: String, expected: String) {
        let (text, caret) = parse(input)
        #expect(apply(MarkdownEditing.toggleNumbered(in: text, selection: caret), to: text) == expected)
    }

    @Test(arguments: [
        ("plain|", "# plain|"),
        ("|", "# |"),
        ("# head|", "head|"),
        ("### de|ep", "de|ep"),
        ("####### seven|", "# ####### seven|"),
        ("#no space|", "# #no space|"),
        ("  in|dented", "  # in|dented"),
    ])
    func headingButtonTogglesTheHashPrefix(input: String, expected: String) {
        let (text, caret) = parse(input)
        #expect(apply(MarkdownEditing.toggleHeading(in: text, selection: caret), to: text) == expected)
    }

    @Test(arguments: [
        (InlineMarker.bold, "a|", "a**|**"),
        (.bold, "|bold|", "**|bold|**"),
        (.bold, "|**bold**|", "|bold|"),
        (.bold, "**|bold|**", "|bold|"),
        (.italic, "|it|", "*|it|*"),
        (.italic, "|*it*|", "|it|"),
        (.italic, "*|it|*", "|it|"),
        (.code, "|x|", "`|x|`"),
        (.code, "`|x|`", "|x|"),
    ])
    func inlineButtonsWrapAndUnwrap(marker: InlineMarker, input: String, expected: String) {
        let (text, selection) = parse(input)
        #expect(apply(MarkdownEditing.toggleInline(marker, in: text, selection: selection), to: text) == expected)
    }

    // MARK: - Block commands over several lines

    @Test(arguments: [
        ("|one\ntwo\nthree|", "|- one\n- two\n- three|"),
        ("|- one\n- two|", "|one\ntwo|"),
        ("|- one\ntwo|", "|- one\n- two|"),  // mixed: fill in rather than strip
        ("|1. one\n2. two|", "|- one\n- two|"),
        ("|- [ ] one\n- [x] two|", "|one\ntwo|"),
        ("|one\n\ntwo|", "|- one\n\n- two|"),  // blank lines are left alone
        ("|  one\n  two|", "|  - one\n  - two|"),
    ])
    func bulletAppliesToEverySelectedLine(input: String, expected: String) {
        let (text, selection) = parse(input)
        #expect(apply(MarkdownEditing.toggleBullet(in: text, selection: selection), to: text) == expected)
    }

    @Test(arguments: [
        ("|one\ntwo\nthree|", "|1. one\n2. two\n3. three|"),
        ("|1. one\n2. two|", "|one\ntwo|"),
        ("|- one\n- two|", "|1. one\n2. two|"),
        ("|- [ ] one\n- [ ] two|", "|1. [ ] one\n2. [ ] two|"),
    ])
    func numberedNumbersEverySelectedLine(input: String, expected: String) {
        let (text, selection) = parse(input)
        #expect(apply(MarkdownEditing.toggleNumbered(in: text, selection: selection), to: text) == expected)
    }

    /// The sequence continues the ordered list the selection starts under.
    @Test func numberedContinuesTheListAboveTheSelection() {
        let (text, selection) = parse("1. a\n2. b\n|c\nd|")
        #expect(
            apply(MarkdownEditing.toggleNumbered(in: text, selection: selection), to: text)
                == "1. a\n2. b\n|3. c\n4. d|")
    }

    @Test(arguments: [
        ("|one\ntwo|", "|# one\n# two|"),
        ("|# one\n## two|", "|one\ntwo|"),
        ("|# one\ntwo|", "|# # one\n# two|"),  // mixed: add to all, as the reference toolbars do
    ])
    func headingAppliesToEverySelectedLine(input: String, expected: String) {
        let (text, selection) = parse(input)
        #expect(apply(MarkdownEditing.toggleHeading(in: text, selection: selection), to: text) == expected)
    }

    /// A selection inside one line keeps the single-line behaviour and its caret arithmetic.
    @Test func aSelectionWithinOneLineIsNotABlockEdit() {
        let (text, selection) = parse("pl|ai|n")
        #expect(apply(MarkdownEditing.toggleBullet(in: text, selection: selection), to: text) == "- pl|ai|n")
    }

    /// Italic must not shave one asterisk off each end of a bold span; it nests instead.
    /// The third case is the dangerous one: the inner `*bold*` of `**bold**` is a valid-looking
    /// italic pair, and stripping it would silently demote bold to italic.
    @Test(arguments: ["**|bold|**", "|**bold**|", "*|*bold*|*"])
    func italicLeavesBoldMarkersAlone(input: String) {
        let (text, selection) = parse(input)
        let edit = MarkdownEditing.toggleInline(.italic, in: text, selection: selection)
        #expect(edit.applying(to: text).contains("**bold**"))
    }

    /// Italic inside bold has to come back off, or the toolbar just piles up asterisks.
    @Test func italicInsideBoldIsAToggle() {
        let (bold, selection) = parse("**|bold|**")
        let nested = MarkdownEditing.toggleInline(.italic, in: bold, selection: selection)
        #expect(nested.applying(to: bold) == "***bold***")

        let text = nested.applying(to: bold)
        let back = MarkdownEditing.toggleInline(.italic, in: text, selection: nested.selection)
        #expect(back.applying(to: text) == "**bold**")
        #expect(back.selection == NSRange(location: 2, length: 4))
    }
}
