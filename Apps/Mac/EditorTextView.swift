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
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
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

/// Renders Markdown without rewriting it. TextKit 2 asks for each paragraph as it lays it out,
/// and we hand back a styled copy; the backing storage — and so the note that gets saved — stays
/// the plain string the user typed. Nothing runs on the typing path, and there is nothing to
/// undo, because no attribute is ever written into the document.
final class MarkdownHighlighter: NSObject, NSTextContentStorageDelegate {
    // NSFont is not marked Sendable, but a font instance is immutable once created and the
    // delegate is only ever called while text is laid out. The protocol is not main-actor
    // isolated, so the fonts cannot be either.
    /// One shared instance: the delegate property is weak, and a text view created through an
    /// AppKit/UIKit initializer is not a safe place to hang the strong reference.
    nonisolated(unsafe) static let shared = MarkdownHighlighter()

    nonisolated(unsafe) static let base = NSFont.systemFont(ofSize: 14)
    nonisolated(unsafe) static let headingFont = NSFont.boldSystemFont(ofSize: 17)
    nonisolated(unsafe) private static let bold = NSFont.boldSystemFont(ofSize: 14)
    nonisolated(unsafe) private static let italic = NSFontManager.shared.convert(
        base, toHaveTrait: .italicFontMask)
    nonisolated(unsafe) private static let code = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    func textContentStorage(
        _ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        // AppKit backs the content storage with an NSTextStorage; UIKit uses `attributedString`.
        // Reading only one of them silently yields nil, and the text renders unstyled.
        let backing = textContentStorage.textStorage ?? textContentStorage.attributedString
        guard let original = backing?.attributedSubstring(from: range) else { return nil }
        let spans = MarkdownHighlighting.spans(in: original.string)
        guard !spans.isEmpty else { return nil }
        // Copy and add: the incoming attributes carry the input method's marked-text underline.
        let styled = NSMutableAttributedString(attributedString: original)
        for span in spans {
            switch span.style {
            case .heading: styled.addAttribute(.font, value: Self.headingFont, range: span.range)
            case .bold: styled.addAttribute(.font, value: Self.bold, range: span.range)
            case .italic: styled.addAttribute(.font, value: Self.italic, range: span.range)
            case .code: styled.addAttribute(.font, value: Self.code, range: span.range)
            case .marker:
                styled.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
            }
        }
        return NSTextParagraph(attributedString: styled)
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
        let textView = MarkdownTextView(frame: .zero, textContainer: container)
        contentStorage.delegate = MarkdownHighlighter.shared
        return textView
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
        font = MarkdownHighlighter.base
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
        let isCommandReturn =
            event.keyCode == 36 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        if isCommandReturn, let edit = MarkdownEditing.toggleCheckbox(in: string, selection: selectedRange()) {
            apply(edit)
            return
        }
        super.keyDown(with: event)
    }

    /// Applies an edit through the undo-aware change path, as its own undo step.
    /// The key overrides above are reached only after the input method has committed, but a menu
    /// key equivalent is dispatched before the responder chain — so ⌘B pressed mid-conversion
    /// would otherwise rewrite the text under the marked range.
    func apply(_ edit: TextEdit) {
        guard !hasMarkedText() else { return }
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        breakUndoCoalescing()
    }
}
