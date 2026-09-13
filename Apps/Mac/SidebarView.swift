import SillCore
import SwiftUI

/// Collapsible list of live notes, newest first. ↑↓ moves, Return goes back to the editor.
/// Delete works the way Apple Notes offers it — Control-click or a swipe on a row — plus the
/// Delete key on the selected one.
struct SidebarView: View {
    let model: EditorModel
    var onDelete: (UUID) -> Void = { _ in }
    @FocusState private var isFocused: Bool

    var body: some View {
        List(selection: selection) {
            ForEach(model.notes) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title.isEmpty ? "New note" : note.title)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(note.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(note.id)
                .contextMenu {
                    Button("Delete", role: .destructive) { onDelete(note.id) }
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { onDelete(note.id) }
                }
            }
        }
        .onDeleteCommand {
            if let id = model.note?.id { onDelete(id) }
        }
        .listStyle(.sidebar)
        // No translucent material: the sidebar shares the window's plain background with the editor.
        .scrollContentBackground(.hidden)
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.return) {
            model.focusEditor()
            return .handled
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.note?.id },
            set: { id in if let id { model.open(id: id) } }
        )
    }
}
