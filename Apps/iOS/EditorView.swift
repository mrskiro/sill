import SillCore
import SwiftUI
import UIKit

struct EditorView: View {
    @Bindable var draft: NoteDraft

    var body: some View {
        MarkdownTextView(text: $draft.text, identifier: "editor-\(draft.id.uuidString)")
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .navigationTitle(draft.note?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy as Markdown", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = draft.text
                    }
                }
            }
    }
}

/// Plain UITextView with every automatic rewrite switched off, plus Return list continuation.
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    var identifier: String

    func makeUIView(context: Context) -> UITextView {
        let textView = MarkdownUITextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.dataDetectorTypes = []
        textView.text = text
        textView.accessibilityIdentifier = identifier
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        if !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>
        var didFocus = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }

    }
}

/// Return continues Markdown lists. `insertText` is the path both the keyboard and
/// programmatic input take, and it is only reached once the input method has committed.
final class MarkdownUITextView: UITextView {
    override func insertText(_ text: String) {
        guard text == "\n", markedTextRange == nil,
            let edit = MarkdownEditing.insertNewline(in: self.text, selection: selectedRange),
            let start = position(from: beginningOfDocument, offset: edit.range.location),
            let end = position(from: start, offset: edit.range.length),
            let textRange = self.textRange(from: start, to: end)
        else {
            super.insertText(text)
            return
        }
        replace(textRange, withText: edit.replacement)
        selectedRange = edit.selection
        delegate?.textViewDidChange?(self)
    }
}
