import Foundation
import Testing
@testable import SillCore

@Suite struct MarkdownEditingTests {
    /// Builds (text, caret) from a string with `|` marking the caret.
    private func parse(_ marked: String) -> (String, NSRange) {
        let caret = (marked as NSString).range(of: "|").location
        return (marked.replacingOccurrences(of: "|", with: ""), NSRange(location: caret, length: 0))
    }

    private func apply(_ edit: TextEdit?, to text: String) -> String? {
        guard let edit else { return nil }
        var result = edit.applying(to: text)
        result.insert("|", at: String.Index(utf16Offset: edit.selection.location, in: result))
        return result
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
}
