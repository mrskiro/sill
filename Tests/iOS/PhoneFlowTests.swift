import SillCore
import Testing
import UIKit

@testable import Sill

/// Runs inside Sill on the simulator against a throwaway database.
@MainActor
@Suite(.serialized)
struct PhoneFlowTests {
    private var model: PhoneModel { PhoneModel.shared }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out waiting for condition")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The UITextView bound to `draft`, once its screen is on. Stale views from popped screens are ignored.
    private func editorTextView(for draft: NoteDraft) async throws -> UITextView {
        let identifier = "editor-\(draft.id.uuidString)"
        var found: UITextView?
        let deadline = ContinuousClock.now + .seconds(3)
        while found == nil, ContinuousClock.now < deadline {
            found = allTextViews().first { $0.accessibilityIdentifier == identifier }
            if found == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        if found == nil {
            let seen = allTextViews().map { $0.accessibilityIdentifier ?? "nil" }
            Issue.record("DIAG wanted \(identifier) path=\(model.path) seen=\(seen)")
        }
        return try #require(found)
    }

    private func allTextViews() -> [UITextView] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .flatMap { $0.allDescendants(of: UITextView.self) }
    }

    /// Pops to the list, waits for the stack to settle, then pushes a fresh editor.
    private func openNewEditor() async throws -> (NoteDraft, UITextView) {
        model.path = []
        try await waitUntil { self.allTextViews().isEmpty }
        model.newNote()
        let destination = try #require(model.path.last)
        let draft = model.draft(for: destination)
        return (draft, try await editorTextView(for: draft))
    }

    @Test func usesThrowawayDatabaseAndLandsInAnEditorOnLaunch() {
        #expect(model.databaseURL.path.contains("sill-tests"))
        #expect(model.path.count == 1)
    }

    @Test func typingAutosavesAndTheListShowsTheNote() async throws {
        let (draft, textView) = try await openNewEditor()

        textView.insertText("# Phone note\n- a")
        #expect(draft.text == "# Phone note\n- a")
        try await waitUntil { draft.note != nil }
        #expect(try model.store.note(id: draft.note!.id)?.content == "# Phone note\n- a")
        try await waitUntil { self.model.notes.first?.title == "Phone note" }

        // Going back flushes the latest text even before the debounce fires.
        textView.insertText("\nmore")
        model.path = []
        try await waitUntil { (try? self.model.store.note(id: draft.note!.id)?.content) == "# Phone note\n- a\nmore" }
    }

    @Test func returnContinuesListsThroughTheRealTextView() async throws {
        let (_, textView) = try await openNewEditor()
        textView.insertText("- item")
        textView.insertText("\n")
        #expect(textView.text == "- item\n- ")
        textView.insertText("\n")
        #expect(textView.text == "- item\n")
        model.path = []
    }

    @Test func syncedChangesToTheOpenNoteShowUpOrGetCopiedAside() async throws {
        let mac = UUID()
        try model.store.addPeer(id: mac, name: "Mac", fingerprint: Data(repeating: 1, count: 32))
        let (draft, textView) = try await openNewEditor()
        textView.insertText("base")
        try await waitUntil { draft.note != nil }
        let open = try #require(draft.note)

        var remote = open
        remote.content = "edited on the mac"
        remote.version = Version(device: mac, seq: 1)
        try model.store.apply(
            [remote], senderID: mac, senderName: "Mac",
            senderVector: VersionVector([mac: 1, model.store.deviceID: open.version.seq]))
        try await waitUntil { draft.text == "edited on the mac" }
        try await waitUntil { textView.text == "edited on the mac" }

        textView.insertText(" plus local")
        var newer = remote
        newer.content = "mac wrote more"
        newer.version = Version(device: mac, seq: 2)
        try model.store.apply(
            [newer], senderID: mac, senderName: "Mac",
            senderVector: VersionVector([mac: 2, model.store.deviceID: open.version.seq]))
        try await waitUntil { self.model.notes.contains { $0.content == "mac wrote more (Conflict from Mac)" } }
        #expect(draft.text == "edited on the mac plus local")
        try await waitUntil { (try? self.model.store.note(id: open.id)?.content) == "edited on the mac plus local" }
        try model.store.removePeer(id: mac)
        model.path = []
    }

    /// Renders the grouped list with notes of assorted ages into tmp/list.png (pulled by the CLI for a visual check).
    @Test func rendersTheGroupedListForInspection() async throws {
        let now = Date()
        for (title, daysAgo) in [
            ("Meeting notes\n- decide the roadmap", 0.01), ("Groceries\nbread, milk", 1.0),
            ("Draft for Slack\nWe should ship on Friday.", 4.0), ("Idea", 20.0), ("Old plan\nRBAC", 70.0),
            ("Last year\nkeep", 400.0),
        ] {
            let date = now.addingTimeInterval(-daysAgo * 86_400)
            try model.store.createNote(content: title, now: date)
        }
        model.path = []
        try await waitUntil { self.allTextViews().isEmpty }
        try await Task.sleep(for: .milliseconds(600))
        let window = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first {
                $0.isKeyWindow
            })
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("list.png")
        try image.pngData()?.write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func emptyNewNoteIsNeverStored() async throws {
        let before = try model.store.liveNotes().count
        let (_, textView) = try await openNewEditor()
        textView.insertText("  \n")
        try await Task.sleep(for: .milliseconds(600))
        model.path = []
        #expect(try model.store.liveNotes().count == before)
    }

    @Test func relaunchOpensTheLastEditedNote() throws {
        let note = try model.store.createNote(content: "latest")
        model.openLastNoteOnLaunch()
        #expect(model.path == [.existing(note.id)])
    }

    @Test func deleteRemovesFromTheList() async throws {
        let note = try model.store.createNote(content: "to delete")
        try await waitUntil { self.model.notes.contains { $0.id == note.id } }
        model.deleteNote(id: note.id)
        try await waitUntil { !self.model.notes.contains { $0.id == note.id } }
        #expect(try model.store.note(id: note.id)?.isDeleted == true)
    }

    @Test func editorNeverRewritesWhatWasTyped() async throws {
        let (_, textView) = try await openNewEditor()
        #expect(textView.smartQuotesType == .no)
        #expect(textView.smartDashesType == .no)
        #expect(textView.autocorrectionType == .no)
        #expect(textView.autocapitalizationType == .none)
        model.path = []
    }
}

extension UIView {
    fileprivate func allDescendants<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in
            var result: [T] = []
            if let match = view as? T { result.append(match) }
            result.append(contentsOf: view.allDescendants(of: type))
            return result
        }
    }
}
