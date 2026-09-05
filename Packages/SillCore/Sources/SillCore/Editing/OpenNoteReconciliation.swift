import Foundation

/// What an editor should do when the note it has open changed underneath it (sync applied a
/// new version, or a tombstone). Pure decision; each platform performs it.
public enum OpenNoteReconciliation: Equatable, Sendable {
    /// Same version as loaded: nothing to do.
    case unchanged
    /// Editor is clean and the note changed: show the new version.
    case reload(Note)
    /// Editor is clean and the note was deleted elsewhere: let it go.
    case deletedRemotely
    /// Editor has unsaved text and the note changed: keep typing, but copy the remote text
    /// aside so it is not lost when the local text is saved on top.
    case keepLocalAndCopyRemote(Note)

    public static func decide(open: Note, editorText: String, current: Note?) -> OpenNoteReconciliation {
        let clean = editorText == open.content
        guard let current, !current.isDeleted else {
            // Deleted (or gone). A dirty editor keeps its text: the next save revives the note.
            return clean ? .deletedRemotely : .unchanged
        }
        guard current.version != open.version else { return .unchanged }
        if clean { return .reload(current) }
        return current.content == editorText ? .reload(current) : .keepLocalAndCopyRemote(current)
    }
}
