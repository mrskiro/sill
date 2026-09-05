import SillCore
import SwiftUI

/// Collapsible list of live notes, newest first. ↑↓ moves, Return goes back to the editor.
struct SidebarView: View {
    let model: EditorModel
    @FocusState private var isFocused: Bool

    var body: some View {
        List(selection: selection) {
            ForEach(model.notes) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title.isEmpty ? "New note" : note.title)
                        .lineLimit(1)
                    Text(note.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(note.id)
            }
        }
        .listStyle(.sidebar)
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
