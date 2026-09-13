import Foundation
import Testing

@testable import SillCore

@Suite struct MarkdownExportTests {
    private let zone = TimeZone(secondsFromGMT: 9 * 3600)!
    private let device = UUID(uuidString: "22222222-0000-0000-0000-000000000000")!
    /// 2026-09-07 12:34:56 +09:00.
    private let t0 = Date(timeIntervalSince1970: 1_788_752_096)

    private func note(
        _ content: String,
        id: String = "11111111-0000-0000-0000-000000000000",
        created: TimeInterval = 0,
        updated: TimeInterval? = nil,
        deleted: Bool = false
    ) -> Note {
        let createdAt = t0.addingTimeInterval(created)
        return Note(
            id: UUID(uuidString: id)!, content: content,
            createdAt: createdAt,
            updatedAt: updated.map { t0.addingTimeInterval($0) } ?? createdAt,
            deletedAt: deleted ? createdAt : nil,
            version: Version(device: device, seq: 1))
    }

    private func files(_ notes: [Note]) -> [MarkdownExport.File] {
        MarkdownExport.files(for: notes, timeZone: zone)
    }

    // MARK: - Front matter and body

    @Test func writesFrontMatterAboveTheNoteUntouched() throws {
        let file = try #require(files([note("# Groceries\n\n- milk\n- eggs", updated: 60)]).first)

        #expect(
            file.text == """
                ---
                id: 11111111-0000-0000-0000-000000000000
                title: "Groceries"
                created: 2026-09-07T12:34:56+09:00
                updated: 2026-09-07T12:35:56+09:00
                ---

                # Groceries

                - milk
                - eggs
                """)
    }

    /// Text preservation is the whole point: no trailing newline is added, none is removed, and
    /// nothing between the first character and the last is rewritten.
    @Test(arguments: ["a\n\n\n", "  leading spaces", "no trailing newline", "\ttab\r\nCRLF"])
    func bodyIsVerbatim(content: String) throws {
        let file = try #require(files([note(content)]).first)
        let body = try #require(file.text.range(of: "---\n\n").map { String(file.text[$0.upperBound...]) })
        #expect(body == content)
    }

    @Test func carriesTheNoteDatesForTheFileItself() throws {
        let file = try #require(files([note("x", created: 0, updated: 120)]).first)
        #expect(file.created == t0)
        #expect(file.modified == t0.addingTimeInterval(120))
    }

    @Test(arguments: [
        ("plain", #""plain""#),
        ("say \"hi\"", #""say \"hi\"""#),
        ("back\\slash", #""back\\slash""#),
        ("a\tb", #""a\tb""#),
        ("key: value", #""key: value""#),
        ("2026", #""2026""#),
        // YAML rejects a raw control character even between quotes. Pasted terminal output has
        // them, and the title is whatever the first line happens to be.
        ("\u{1B}[31mred", #""\x1B[31mred""#),
        ("bell\u{7}", #""bell\x07""#),
        // Everything above U+FFFF is left alone: it is text, not a control character.
        ("emoji 🎉", #""emoji 🎉""#),
    ])
    func quotesTheTitleAsAYamlString(title: String, expected: String) throws {
        let file = try #require(files([note(title)]).first)
        #expect(file.text.contains("title: \(expected)\n"))
    }

    // MARK: - File names

    @Test(arguments: [
        ("# Meeting notes", "Meeting notes.md"),
        ("2026/09/07 standup", "20260907 standup.md"),
        ("Re: the plan", "Re the plan.md"),
        (".hidden", "hidden.md"),
        // Stripping the `:` leaves a space in front of the dot; the file must still not be hidden.
        (": .config notes", "config notes.md"),
        ("/ .env sample", "env sample.md"),
        ("  padded  \nbody", "padded.md"),
        ("emoji 🎉 title", "emoji 🎉 title.md"),
    ])
    func namesTheFileAfterTheTitle(content: String, expected: String) throws {
        #expect(try #require(files([note(content)]).first).name == expected)
    }

    /// A note whose first line leaves nothing usable still needs a name of its own.
    @Test(arguments: ["", "   ", "///", "..", ":", ": ..", "/ ."])
    func fallsBackToTheCreationTime(content: String) throws {
        #expect(try #require(files([note(content)]).first).name == "2026-09-07 12-34-56.md")
    }

    /// APFS caps a name at 255 bytes, and a character can weigh four of them.
    @Test(arguments: [String(repeating: "あ", count: 120), String(repeating: "🎉", count: 120)])
    func keepsTheNameInsideTheByteLimit(title: String) throws {
        let name = try #require(files([note(title)]).first).name
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(".md"))
        // Cut on a character boundary, so the name is still the start of the title.
        #expect(title.hasPrefix(String(name.dropLast(3))))
    }

    // MARK: - Collisions

    @Test func numbersTheDuplicatesInCreationOrder() {
        let notes = [
            note("Standup", id: "AAAAAAAA-0000-0000-0000-000000000000", created: 0),
            note("Standup", id: "BBBBBBBB-0000-0000-0000-000000000000", created: 10),
            note("Standup", id: "CCCCCCCC-0000-0000-0000-000000000000", created: 20),
        ]
        // Reversed on the way in: the UI orders by edit time, the export must not.
        #expect(files(notes.reversed()).map(\.name) == ["Standup.md", "Standup 2.md", "Standup 3.md"])
        #expect(files(notes).map(\.name) == ["Standup.md", "Standup 2.md", "Standup 3.md"])
    }

    /// The file system would treat these as one name, so the export has to as well.
    @Test(arguments: [("Standup", "STANDUP"), ("café", "cafe\u{301}")])
    func countsCaseAndCompositionAsTheSameName(first: String, second: String) {
        let notes = [
            note(first, id: "AAAAAAAA-0000-0000-0000-000000000000", created: 0),
            note(second, id: "BBBBBBBB-0000-0000-0000-000000000000", created: 10),
        ]
        let names = files(notes).map(\.name)
        #expect(names.count == 2)
        #expect(names[1] == "\(second) 2.md")
    }

    /// Titles a case-insensitive volume folds together, which plain lowercasing does not: `ß`
    /// folds to `ss`, the `ﬁ` ligature to `fi`. Asked on disk rather than from a table, because
    /// getting it wrong means one note overwriting another and leaving no trace that it did.
    @Test(arguments: [
        ("straße", "STRASSE"),
        ("\u{FB01}le", "file"),
        ("Standup", "STANDUP"),
        ("café", "cafe\u{301}"),
    ])
    func neverLetsOneNoteOverwriteAnother(first: String, second: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sill-export-tests/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let notes = [
            note(first, id: "AAAAAAAA-0000-0000-0000-000000000000", created: 0),
            note(second, id: "BBBBBBBB-0000-0000-0000-000000000000", created: 10),
        ]
        try MarkdownExport.write(notes, to: directory, timeZone: zone)

        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(written.count == 2, "\(first) and \(second) landed on top of each other")
    }

    @Test func skipsDeletedNotes() {
        let notes = [
            note("kept", id: "AAAAAAAA-0000-0000-0000-000000000000", created: 0),
            note("gone", id: "BBBBBBBB-0000-0000-0000-000000000000", created: 10, deleted: true),
        ]
        #expect(files(notes).map(\.name) == ["kept.md"])
    }

    // MARK: - Writing

    /// Each export gets a folder of its own, so a second run cannot land on the first one's files.
    @Test func picksAFolderNameNothingIsUsing() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("sill-export-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let first = MarkdownExport.availableDirectory(in: parent, named: "Sill Notes")
        #expect(first.lastPathComponent == "Sill Notes")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)

        let second = MarkdownExport.availableDirectory(in: parent, named: "Sill Notes")
        #expect(second.lastPathComponent == "Sill Notes 2")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        #expect(MarkdownExport.availableDirectory(in: parent, named: "Sill Notes").lastPathComponent == "Sill Notes 3")
    }

    /// A stale alias into a volume that is no longer mounted still occupies the name. `fileExists`
    /// follows the link, finds nothing and calls the name free, which would point the export at an
    /// entry it did not create and must not remove.
    @Test func treatsALinkPointingNowhereAsTaken() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("sill-export-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let link = parent.appendingPathComponent("Sill Notes")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: parent.appendingPathComponent("not there"))
        #expect(FileManager.default.fileExists(atPath: link.path) == false)

        #expect(MarkdownExport.availableDirectory(in: parent, named: "Sill Notes").lastPathComponent == "Sill Notes 2")
    }

    @Test func writesEveryNoteIntoTheFolder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sill-export-tests/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let notes = [
            note("Groceries\n- milk", id: "AAAAAAAA-0000-0000-0000-000000000000", created: 0, updated: 300),
            note("Groceries", id: "BBBBBBBB-0000-0000-0000-000000000000", created: 10),
        ]
        try MarkdownExport.write(notes, to: directory, timeZone: zone)

        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(written == ["Groceries 2.md", "Groceries.md"])

        let text = try String(contentsOf: directory.appendingPathComponent("Groceries.md"), encoding: .utf8)
        #expect(text.hasSuffix("---\n\nGroceries\n- milk"))

        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("Groceries.md").path)
        #expect(attributes[.modificationDate] as? Date == t0.addingTimeInterval(300))
    }
}
