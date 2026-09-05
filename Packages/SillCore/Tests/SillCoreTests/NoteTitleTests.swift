import Testing

@testable import SillCore

@Suite struct NoteTitleTests {
    @Test(arguments: [
        ("# Meeting memo\n- item", "Meeting memo"),
        ("###   Deep heading  ", "Deep heading"),
        ("\n\n  second line is first\nmore", "second line is first"),
        ("- a list item", "- a list item"),
        ("###", "###"),
        ("", ""),
        ("   \n\t\n", ""),
    ])
    func derivesTitleFromFirstNonBlankLine(content: String, expected: String) {
        #expect(NoteTitle.title(of: content) == expected)
    }
}
