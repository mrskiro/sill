import SillCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
                        copy(draft.text)
                    }
                }
            }
    }
}

/// Copies the note twice over: the Markdown itself, and an HTML rendering of it. Somewhere that
/// only takes text still gets the exact characters; somewhere that reads the rich flavour — Slack,
/// Docs, Mail, Notes — gets real lists and real emphasis instead of a line that happens to start
/// with a hyphen.
func copy(_ markdown: String) {
    UIPasteboard.general.items = [
        [
            UTType.utf8PlainText.identifier: markdown,
            UTType.html.identifier: MarkdownHTML.fragment(from: markdown),
        ]
    ]
}

/// Plain UITextView with every automatic rewrite switched off, plus Return list continuation.
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    var identifier: String

    func makeUIView(context: Context) -> UITextView {
        let textView = MarkdownUITextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.startHighlighting()
        textView.font = MarkdownHighlighter.base
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
        textView.inputAccessoryView = FormatToolbar(textView: textView)
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

/// Renders Markdown without rewriting it. TextKit 2 asks for each paragraph as it lays it out,
/// and we hand back a styled copy; the backing storage — and so the note that gets saved — stays
/// the plain string the user typed. Nothing runs on the typing path, and there is nothing to
/// undo, because no attribute is ever written into the document.
final class MarkdownHighlighter: NSObject, NSTextContentStorageDelegate {
    /// One shared instance: the delegate property is weak, and a text view created through an
    /// AppKit/UIKit initializer is not a safe place to hang the strong reference.
    nonisolated(unsafe) static let shared = MarkdownHighlighter()

    static let base = UIFont.preferredFont(forTextStyle: .body)
    static let headingFont = bolded(.preferredFont(forTextStyle: .title3))
    private static let bold = bolded(base)
    private static let italic = withTraits(base, .traitItalic)
    private static let code = UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)

    func textContentStorage(
        _ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        // UIKit backs the content storage with `attributedString`; AppKit uses an NSTextStorage.
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
                styled.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: span.range)
            }
        }
        return NSTextParagraph(attributedString: styled)
    }

    private static func bolded(_ font: UIFont) -> UIFont {
        withTraits(font, .traitBold)
    }

    private static func withTraits(_ font: UIFont, _ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

/// Return continues Markdown lists. `insertText` is the path both the keyboard and
/// programmatic input take, and it is only reached once the input method has committed.
final class MarkdownUITextView: UITextView {
    /// Hands paragraph rendering to `MarkdownHighlighter`. Call once, after the view exists.
    func startHighlighting() {
        (textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate = MarkdownHighlighter.shared
    }

    override func insertText(_ text: String) {
        guard text == "\n", markedTextRange == nil,
            let edit = MarkdownEditing.insertNewline(in: self.text, selection: selectedRange),
            apply(edit)
        else {
            super.insertText(text)
            return
        }
    }

    /// Runs one `MarkdownEditing` command over the current text and selection (toolbar buttons).
    func applyFormat(_ command: (String, NSRange) -> TextEdit?) {
        guard let edit = command(text, selectedRange) else { return }
        apply(edit)
    }

    /// Replaces text through `UITextInput` so the edit is one undo step and the delegate sees it.
    /// A tap in the middle of an unconfirmed conversion is ignored rather than corrupting it.
    @discardableResult
    private func apply(_ edit: TextEdit) -> Bool {
        guard markedTextRange == nil,
            let start = position(from: beginningOfDocument, offset: edit.range.location),
            let end = position(from: start, offset: edit.range.length),
            let textRange = self.textRange(from: start, to: end)
        else { return false }
        replace(textRange, withText: edit.replacement)
        selectedRange = edit.selection
        delegate?.textViewDidChange?(self)
        return true
    }
}

/// The bar above the keyboard, like Notes: Markdown commands from `MarkdownEditing`, applied to
/// the plain-text buffer. It scrolls horizontally so a narrow phone drops none of them.
final class FormatToolbar: UIInputView {
    struct Command {
        let label: String
        let symbol: String
        let edit: (String, NSRange) -> TextEdit?
    }

    /// Block style, then inline spans, then lists with their indentation — the grouping Notes,
    /// TinyMCE-lineage editors and GitHub's Markdown toolbar all share. Within the last group the
    /// order (bullet, numbered, checklist, outdent, indent) is the one every reference uses.
    static let groups: [[Command]] = [
        [
            Command(label: "Heading", symbol: "number", edit: MarkdownEditing.toggleHeading)
        ],
        [
            Command(
                label: "Bold", symbol: "bold",
                edit: { MarkdownEditing.toggleInline(.bold, in: $0, selection: $1) }),
            Command(
                label: "Italic", symbol: "italic",
                edit: { MarkdownEditing.toggleInline(.italic, in: $0, selection: $1) }),
            Command(
                label: "Code", symbol: "chevron.left.forwardslash.chevron.right",
                edit: { MarkdownEditing.toggleInline(.code, in: $0, selection: $1) }),
        ],
        [
            Command(label: "Bulleted List", symbol: "list.bullet", edit: MarkdownEditing.toggleBullet),
            Command(label: "Numbered List", symbol: "list.number", edit: MarkdownEditing.toggleNumbered),
            Command(label: "Checklist", symbol: "checklist", edit: MarkdownEditing.toggleCheckbox),
            Command(label: "Outdent", symbol: "decrease.indent", edit: MarkdownEditing.outdent),
            Command(label: "Indent", symbol: "increase.indent", edit: MarkdownEditing.indent),
        ],
    ]

    static var commands: [Command] { groups.flatMap { $0 } }

    /// Accessibility identifier for a command, e.g. "format-bulleted-list". Used by the tests.
    static func identifier(for label: String) -> String {
        "format-" + label.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    init(textView: MarkdownUITextView) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleWidth

        var items: [UIView] = []
        for group in Self.groups {
            if !items.isEmpty { items.append(Self.groupDivider()) }
            items.append(contentsOf: group.map { Self.button(for: $0, textView: textView) })
        }
        let stack = UIStackView(arrangedSubviews: items)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        // The keyboard's own chrome material, so the bar reads as part of the keyboard rather
        // than as a strip of the note. It follows light and dark like the keys above it.
        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        background.translatesAutoresizingMaskIntoConstraints = false
        background.contentView.addSubview(scrollView)
        addSubview(background)

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        background.contentView.addSubview(separator)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            scrollView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Hairline between groups, the way a toolbar's `|` separator reads.
    private static func groupDivider() -> UIView {
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 22),
        ])
        return divider
    }

    private static func button(for command: Command, textView: MarkdownUITextView) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: command.symbol)
        // The default plain insets are wide enough to push half the commands off a phone screen.
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6)
        // Ink, not accent: these read as part of the keyboard, like the letters on the keys.
        configuration.baseForegroundColor = .label
        let button = UIButton(
            configuration: configuration,
            primaryAction: UIAction { [weak textView] _ in textView?.applyFormat(command.edit) })
        button.accessibilityLabel = command.label
        button.accessibilityIdentifier = identifier(for: command.label)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }
}
