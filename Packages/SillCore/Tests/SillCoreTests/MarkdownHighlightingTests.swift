import Foundation
import Testing

@testable import SillCore

@Suite struct MarkdownHighlightingTests {
    /// One letter per character: m marker, h heading, b bold, i italic, c code, `.` unstyled.
    /// Overlapping spans would show up as a letter in the wrong column.
    private func styles(of paragraph: String) -> String {
        var marks = [String](repeating: ".", count: (paragraph as NSString).length)
        for span in MarkdownHighlighting.spans(in: paragraph) {
            let letter =
                switch span.style {
                case .heading: "h"
                case .bold: "b"
                case .italic: "i"
                case .code: "c"
                case .marker: "m"
                }
            for offset in span.range.location..<NSMaxRange(span.range) { marks[offset] = letter }
        }
        return marks.joined()
    }

    @Test(arguments: [
        ("# head", "mmhhhh"),
        ("### deep", "mmmmhhhh"),
        ("  # indented", "..mmhhhhhhhh"),
        ("####### seven", ".............".self),  // more than six hashes is not a heading
        ("#no space", "........."),
        ("#", "."),
    ])
    func headingsDimTheHashesAndStyleTheRest(paragraph: String, expected: String) {
        #expect(styles(of: paragraph) == expected)
    }

    @Test(arguments: [
        ("- item", "mm...."),
        ("* item", "mm...."),
        ("1. item", "mmm...."),
        ("- [ ] todo", "mmmmmm...."),
        ("- [x] done", "mmmmmm...."),
        ("  - nested", "..mm......"),
        ("-no space", "........."),
    ])
    func listMarkersAreDimmed(paragraph: String, expected: String) {
        #expect(styles(of: paragraph) == expected)
    }

    @Test(arguments: [
        ("**bold**", "mmbbbbmm"),
        ("*it*", "miim"),
        ("`x`", "mcm"),
        ("a **b** c", "..mmbmm.."),
        ("- **b**", "mmmmbmm"),
        ("**a** *b*", "mmbmm.mim"),
        ("plain text", ".........."),
        ("*abc", "...."),  // no closer: left alone
        ("**", ".."),
        ("a * b", "....."),  // a lone asterisk is not emphasis
    ])
    func inlineSpansStyleTheContentAndDimTheDelimiters(paragraph: String, expected: String) {
        #expect(styles(of: paragraph) == expected)
    }

    /// A heading is emphasis enough; scanning inline spans inside it would put two fonts in
    /// competition for the same characters.
    @Test func headingsDoNotAlsoScanInlineSpans() {
        #expect(styles(of: "# **not bold**") == "mmhhhhhhhhhhhh")
    }

    @Test func theTrailingNewlineIsNeverStyled() {
        #expect(styles(of: "- x\n") == "mm..")
        #expect(styles(of: "\n") == ".")
        #expect(MarkdownHighlighting.spans(in: "") == [])
    }

    /// The renderer applies spans in order and must never be handed overlapping ranges.
    @Test(arguments: [
        "# head", "- [ ] **a** `b`", "**a** *b* `c`", "  1. *x* text", "*a**b**c*",
    ])
    func spansNeverOverlap(paragraph: String) {
        let spans = MarkdownHighlighting.spans(in: paragraph)
        for (earlier, later) in zip(spans, spans.dropFirst()) {
            #expect(NSMaxRange(earlier.range) <= later.range.location)
        }
    }
}
