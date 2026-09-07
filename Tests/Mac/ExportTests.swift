import AppKit
import Foundation
import SillCore
import Testing

@testable import Sill

/// The app half of "Export Notes…": the folder chooser is not driven here, only what happens once a
/// place has been picked. `MarkdownExportTests` covers the file names and the front matter.
@MainActor
@Suite(.serialized)
struct ExportTests {
    private var app: AppDelegate { AppDelegate.shared }

    private func temporaryParent() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sill-export-tests/\(UUID().uuidString)", isDirectory: true)
    }

    @Test func fillsAFreshFolderWithOneFilePerNote() throws {
        let note = try app.store.createNote(content: "# Export me\n\n- one")
        defer { _ = try? app.store.deleteNote(id: note.id) }

        let parent = temporaryParent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let directory = try app.exportNotes(into: parent)

        #expect(directory.lastPathComponent == "Sill Notes")
        let text = try String(contentsOf: directory.appendingPathComponent("Export me.md"), encoding: .utf8)
        #expect(text.contains("id: \(note.id.uuidString)"))
        #expect(text.hasSuffix("---\n\n# Export me\n\n- one"))
    }

    /// Exporting twice never writes over the first run, and never touches anything already in the
    /// folder the user pointed at — including a note of their own that happens to share a name.
    @Test func leavesTheEarlierExportAndEverythingElseAlone() throws {
        let note = try app.store.createNote(content: "Twice over")
        defer { _ = try? app.store.deleteNote(id: note.id) }

        let parent = temporaryParent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let stranger = parent.appendingPathComponent("Twice over.md")
        try "not Sill's".write(to: stranger, atomically: true, encoding: .utf8)

        let first = try app.exportNotes(into: parent)
        let second = try app.exportNotes(into: parent)

        #expect(first.lastPathComponent == "Sill Notes")
        #expect(second.lastPathComponent == "Sill Notes 2")
        #expect(try String(contentsOf: stranger, encoding: .utf8) == "not Sill's")
        for directory in [first, second] {
            let text = try String(contentsOf: directory.appendingPathComponent("Twice over.md"), encoding: .utf8)
            #expect(text.hasSuffix("---\n\nTwice over"))
        }
    }

    /// An alias left behind by an unmounted volume holds the name without being a folder. The
    /// export has to go around it and leave it standing, rather than take the name and then delete
    /// it on the way out.
    @Test func exportsAroundAStaleAliasWithoutRemovingIt() throws {
        let note = try app.store.createNote(content: "Aliased")
        defer { _ = try? app.store.deleteNote(id: note.id) }

        let parent = temporaryParent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let link = parent.appendingPathComponent("Sill Notes")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: parent.appendingPathComponent("not there"))

        let directory = try app.exportNotes(into: parent)

        #expect(directory.lastPathComponent == "Sill Notes 2")
        // Throws if the link is gone, which is the failure this guards against.
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(destination.hasSuffix("not there"))
    }
}
