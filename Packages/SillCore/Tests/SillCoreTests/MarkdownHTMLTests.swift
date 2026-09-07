import Foundation
import Testing

@testable import SillCore

@Suite struct MarkdownHTMLTests {
    @Test(arguments: [
        ("plain text", "<p>plain text</p>"),
        ("two\nlines", "<p>two<br>lines</p>"),
        ("one\n\ntwo", "<p>one</p><p>two</p>"),
        ("# Title", "<h1>Title</h1>"),
        ("### Third", "<h3>Third</h3>"),
        ("####### seven", "<p>####### seven</p>"),  // not a heading, so not an <h7>
    ])
    func paragraphsAndHeadings(markdown: String, expected: String) {
        #expect(MarkdownHTML.fragment(from: markdown) == expected)
    }

    @Test(arguments: [
        ("- a\n- b", "<ul><li>a</li><li>b</li></ul>"),
        ("1. a\n2. b", "<ol><li>a</li><li>b</li></ol>"),
        ("- a\n1. b", "<ul><li>a</li></ul><ol><li>b</li></ol>"),
        ("- [ ] todo\n- [x] done", "<ul><li>☐ todo</li><li>☑ done</li></ul>"),
        ("- a\n\n- b", "<ul><li>a</li></ul><ul><li>b</li></ul>"),
    ])
    func lists(markdown: String, expected: String) {
        #expect(MarkdownHTML.fragment(from: markdown) == expected)
    }

    /// A nested list belongs inside its parent `<li>`; a `<ul>` hanging off a `<ul>` is invalid
    /// and a paste target may discard the whole fragment over it.
    @Test(arguments: [
        ("- a\n  - b", "<ul><li>a<ul><li>b</li></ul></li></ul>"),
        ("- a\n  - b\n- c", "<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul>"),
        ("- a\n  1. b\n  2. c", "<ul><li>a<ol><li>b</li><li>c</li></ol></li></ul>"),
        ("- a\n    - deep\n  - mid", "<ul><li>a<ul><li>deep</li></ul><ul><li>mid</li></ul></li></ul>"),
    ])
    func nestedLists(markdown: String, expected: String) {
        #expect(MarkdownHTML.fragment(from: markdown) == expected)
    }

    @Test(arguments: [
        ("**bold**", "<p><strong>bold</strong></p>"),
        ("*italic*", "<p><em>italic</em></p>"),
        ("`code`", "<p><code>code</code></p>"),
        ("a **b** c", "<p>a <strong>b</strong> c</p>"),
        ("- **b**", "<ul><li><strong>b</strong></li></ul>"),
        // The editor leaves a heading's inline spans alone because two fonts would compete for
        // the same characters; HTML has no such conflict, so the copy keeps them.
        ("# **bold heading**", "<h1><strong>bold heading</strong></h1>"),
        ("*unclosed", "<p>*unclosed</p>"),
    ])
    func inlineSpans(markdown: String, expected: String) {
        #expect(MarkdownHTML.fragment(from: markdown) == expected)
    }

    /// The note is arbitrary text, so anything that would open a tag has to be escaped.
    @Test(arguments: [
        ("a < b & c > d", "<p>a &lt; b &amp; c &gt; d</p>"),
        ("<script>alert(1)</script>", "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>"),
        ("`<b>`", "<p><code>&lt;b&gt;</code></p>"),
        ("# <em>", "<h1>&lt;em&gt;</h1>"),
    ])
    func markupInTheNoteIsEscaped(markdown: String, expected: String) {
        #expect(MarkdownHTML.fragment(from: markdown) == expected)
    }

    @Test func anEmptyNoteProducesNothing() {
        #expect(MarkdownHTML.fragment(from: "") == "")
        #expect(MarkdownHTML.fragment(from: "\n\n") == "")
    }

    /// Every `<ul>`/`<ol>`/`<li>`/`<p>` that opens has to close, in order.
    @Test(arguments: [
        "# Release\nintro\n- a\n  - b\n- [ ] c\n\n1. one\n2. two\nend",
        "- a\n    - deep\n1. mixed\n\n# End",
    ])
    func tagsAreBalanced(markdown: String) {
        let html = MarkdownHTML.fragment(from: markdown)
        var stack: [String] = []
        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let tag = String(rest[rest.index(after: open)..<close])
            if tag.hasPrefix("/") {
                #expect(stack.popLast() == String(tag.dropFirst()), "unbalanced \(tag) in \(html)")
            } else if !tag.hasSuffix("/") && tag != "br" {
                stack.append(tag)
            }
            rest = rest[rest.index(after: close)...]
        }
        #expect(stack.isEmpty, "left open \(stack) in \(html)")
    }
}
