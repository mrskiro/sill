public enum NoteTitle {
    /// The first non-blank line, with leading `#` heading markers stripped.
    /// Returns an empty string when the note has no text; the UI decides the placeholder.
    public static func title(of content: String) -> String {
        for line in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let withoutHeading = trimmed.drop(while: { $0 == "#" })
            let title = withoutHeading.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? String(trimmed) : title
        }
        return ""
    }
}
