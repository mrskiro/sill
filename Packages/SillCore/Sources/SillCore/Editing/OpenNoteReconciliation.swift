import Foundation

/// What an editor should do when the note it has open changed underneath it (sync applied a
/// new version, or a tombstone). Pure decision; each platform performs it.
/// A dirty editor keeps typing: `NoteStore.saveEdit` preserves the replaced text when it saves.
public enum OpenNoteReconciliation: Equatable, Sendable {
    /// Same version as loaded, or the editor has unsaved text: nothing to do now.
    case unchanged
    /// Editor is clean and the note changed: show the new version.
    case reload(Note)
    /// Editor is clean and the note was deleted elsewhere: let it go.
    case deletedRemotely

    public static func decide(open: Note, editorText: String, current: Note?) -> OpenNoteReconciliation {
        let clean = editorText == open.content
        guard let current, !current.isDeleted else {
            return clean ? .deletedRemotely : .unchanged
        }
        guard current.version != open.version else { return .unchanged }
        return clean || current.content == editorText ? .reload(current) : .unchanged
    }
}
