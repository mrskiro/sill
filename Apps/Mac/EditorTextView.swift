import AppKit
import SillCore
import SwiftUI

/// Plain-text NSTextView wrapped for SwiftUI. The string is the only source of truth;
/// every automatic substitution that could rewrite Markdown or code is switched off.
struct EditorTextView: NSViewRepresentable {
    let model: EditorModel
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView.makeTextKit2()
        textView.onEscape = onEscape
        textView.delegate = context.coordinator
        model.attach(textView)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        textView.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let model: EditorModel

        init(model: EditorModel) {
            self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            model.textDidChange(textView.string)
        }
    }
}

final class MarkdownTextView: NSTextView {
    var onEscape: (() -> Void)?

    /// TextKit 2 stack: NSTextContentStorage → NSTextLayoutManager → NSTextContainer.
    static func makeTextKit2() -> MarkdownTextView {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        return MarkdownTextView(frame: .zero, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isRichText = false
        allowsUndo = true
        font = .systemFont(ofSize: 14)
        textContainerInset = NSSize(width: 12, height: 12)
        drawsBackground = false
        usesFontPanel = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        smartInsertDeleteEnabled = false
    }

    /// Esc. Reached only after the input method has finished with the key,
    /// so cancelling a Japanese conversion never closes the panel.
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    // MARK: Markdown list keys (also reached only after IME composition is committed)

    override func insertNewline(_ sender: Any?) {
        if let edit = MarkdownEditing.insertNewline(in: string, selection: selectedRange()) {
            apply(edit)
        } else {
            super.insertNewline(sender)
        }
    }

    override func insertTab(_ sender: Any?) {
        if let edit = MarkdownEditing.indent(in: string, selection: selectedRange()) {
            apply(edit)
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if let edit = MarkdownEditing.outdent(in: string, selection: selectedRange()) {
            apply(edit)
        } else {
            super.insertBacktab(sender)
        }
    }

    /// ⌘Return toggles the checkbox on the current line.
    override func keyDown(with event: NSEvent) {
        let isCommandReturn = event.keyCode == 36 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        if isCommandReturn, let edit = MarkdownEditing.toggleCheckbox(in: string, selection: selectedRange()) {
            apply(edit)
            return
        }
        super.keyDown(with: event)
    }

    /// Applies an edit through the undo-aware change path, as its own undo step.
    private func apply(_ edit: TextEdit) {
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        breakUndoCoalescing()
    }
}
