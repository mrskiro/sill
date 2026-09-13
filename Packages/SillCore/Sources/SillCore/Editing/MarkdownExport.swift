import Foundation

/// Turns the note table into a folder of `.md` files — the way out of Sill.
///
/// This is an escape hatch, not a second home for the notes: SQLite stays the truth (design.md §3),
/// the export is one-shot, and there is no import back. What it owes the reader is that the body of
/// each file is the note's own text, byte for byte, with only a YAML front matter block above it.
///
/// The front matter field names follow Joplin's "Markdown + Front Matter" interchange format, which
/// Obsidian and Hugo also read: `title`, `created`, `updated`. `id` is Sill's own note id, so a file
/// can still be traced back to the row it came from.
public enum MarkdownExport {
    public struct File: Equatable, Sendable {
        /// Includes the `.md` extension, and is unique within one export.
        public var name: String
        public var text: String
        public var created: Date
        public var modified: Date
    }

    /// One file per live note, named after its title, with names made unique.
    ///
    /// Notes are taken in creation order rather than the `updatedAt` order the UI shows, so that
    /// which of two notes sharing a title gets the bare name does not change every time one of them
    /// is edited. It still shifts if an earlier note of the same title is deleted — the suffixes are
    /// positions, not identities — which is why an export goes into a folder of its own.
    public static func files(for notes: [Note], timeZone: TimeZone = .current) -> [File] {
        let stamp = timestampFormatter(timeZone: timeZone)
        let fallback = fallbackNameFormatter(timeZone: timeZone)
        var taken: Set<String> = []

        return
            notes
            .filter { !$0.isDeleted }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            .map { note in
                let base = name(of: note, fallback: fallback)
                var candidate = base
                var suffix = 2
                while !taken.insert(collisionKey(candidate)).inserted {
                    candidate = "\(base) \(suffix)"
                    suffix += 1
                }
                return File(
                    name: candidate + ".md",
                    text: frontMatter(for: note, stamp: stamp) + note.content,
                    created: note.createdAt,
                    modified: note.updatedAt
                )
            }
    }

    /// A folder inside `parent` that does not exist yet: `Sill Notes`, then `Sill Notes 2`, the way
    /// a browser names a second download. An export never writes into a folder someone else filled,
    /// so it cannot overwrite a file it did not create — pointing it at a vault of `.md` files is
    /// safe.
    public static func availableDirectory(in parent: URL, named name: String) -> URL {
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while isTaken(candidate) {
            candidate = parent.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    /// Anything at all under that name, a symlink pointing nowhere included. `fileExists` resolves
    /// symlinks and so calls a stale alias absent, which would hand the export a name it does not
    /// own; reading the attributes asks about the entry itself.
    private static func isTaken(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Writes the files into `directory`, creating it if needed. The caller owns what happens to
    /// anything already there.
    public static func write(_ notes: [Note], to directory: URL, timeZone: TimeZone = .current) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files(for: notes, timeZone: timeZone) {
            let url = directory.appendingPathComponent(file.name)
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            // Cosmetic: the note's own dates on the file. Not worth failing the export over.
            try? manager.setAttributes(
                [.creationDate: file.created, .modificationDate: file.modified],
                ofItemAtPath: url.path)
        }
    }

    // MARK: - Front matter

    private static func frontMatter(for note: Note, stamp: DateFormatter) -> String {
        let lines = [
            "---",
            "id: \(note.id.uuidString)",
            "title: \(yamlString(note.title))",
            "created: \(stamp.string(from: note.createdAt))",
            "updated: \(stamp.string(from: note.updatedAt))",
            "---",
            "",
        ]
        // The blank line after the closing delimiter is part of the interchange format, and it is
        // also what keeps the body separate from the block above it.
        return lines.joined(separator: "\n") + "\n"
    }

    /// A double-quoted YAML scalar: a title is free text and may open with `#`, contain `: `, or be
    /// nothing but digits, none of which survive being written bare.
    ///
    /// Control characters are escaped rather than passed through: YAML rejects a raw one even
    /// inside quotes, and a note can hold one — an escape sequence pasted out of a terminal, say.
    /// The body below keeps whatever it had; only this field is spelled differently.
    private static func yamlString(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\t": escaped += "\\t"
            default:
                if needsEscaping(scalar) {
                    escaped += escapeSequence(for: scalar)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }

    /// The C0 and C1 controls plus the separators YAML reads as a line break of their own.
    private static func needsEscaping(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}"
    }

    private static func escapeSequence(for scalar: Unicode.Scalar) -> String {
        scalar.value <= 0xFF
            ? String(format: "\\x%02X", scalar.value)
            : String(format: "\\u%04X", scalar.value)
    }

    // MARK: - File names

    /// Room for the extension and a collision suffix inside the 255-byte limit APFS puts on a name.
    private static let nameByteLimit = 200

    private static func name(of note: Note, fallback: DateFormatter) -> String {
        let title = sanitized(note.title)
        return title.isEmpty ? fallback.string(from: note.createdAt) : title
    }

    private static func sanitized(_ title: String) -> String {
        let stripped = String(
            title.filter { character in
                // `/` is the path separator; `:` is one too, in the Finder's view of a name.
                // Control characters are legal on APFS and a menace everywhere else.
                character != "/" && character != ":"
                    && !character.unicodeScalars.contains { $0.properties.generalCategory == .control }
            })
        // A leading dot hides the file, and `.`/`..` are not names at all. Trim first: removing a
        // `/` or `:` can leave a space in front of the dot, and dropping dots before that space is
        // gone would let `: .config` through as a hidden `.config`.
        let visible = stripped.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "." })
        let trimmed = visible.trimmingCharacters(in: .whitespaces)
        return truncated(trimmed, toUTF8Bytes: nameByteLimit).trimmingCharacters(in: .whitespaces)
    }

    /// Cuts on a character boundary: the limit is in bytes, but half a character is not a character.
    private static func truncated(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > limit { break }
            result.append(character)
            bytes += size
        }
        return result
    }

    /// Two names collide on disk if they differ only by case or by how a composed character is
    /// spelled, so uniqueness is decided on the same footing the file system decides it on.
    ///
    /// Case folding, not `lowercased()`: a case-insensitive APFS volume folds `ß` to `ss` and `ﬁ`
    /// to `fi`, so `straße.md` and `STRASSE.md` are one file there while lowercasing calls them
    /// two. Missing a collision would mean one note quietly overwriting another on the way out.
    /// Folding too eagerly only ever costs a needless ` 2`.
    private static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    // MARK: - Formatters

    /// RFC 3339 with the offset spelled `+09:00`, which is what reads the field back.
    private static func timestampFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter
    }

    /// For a note whose first line leaves nothing usable behind. Same instant as `created`, spelled
    /// so it can be a file name.
    private static func fallbackNameFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }
}
