import Foundation

/// Apple Notes-style sections: Today, Yesterday, Previous 7 Days, Previous 30 Days,
/// then months of the current year, then years. Notes must already be newest-first.
public struct NoteListSection: Equatable, Sendable, Identifiable {
    public var title: String
    public var notes: [Note]
    public var id: String { title }
}

public enum NoteListGrouping {
    /// The UI is English throughout, so month and year titles do not follow the device locale.
    public static let locale = Locale(identifier: "en_US")

    public static func sections(
        for notes: [Note],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [NoteListSection] {
        let locale = Self.locale
        let startOfToday = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday)!
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday)!
        let thisYear = calendar.component(.year, from: now)

        var sections: [NoteListSection] = []
        for note in notes {
            let date = note.updatedAt
            let title: String
            if date >= startOfToday {
                title = "Today"
            } else if date >= yesterday {
                title = "Yesterday"
            } else if date >= weekAgo {
                title = "Previous 7 Days"
            } else if date >= monthAgo {
                title = "Previous 30 Days"
            } else if calendar.component(.year, from: date) == thisYear {
                title = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.wide))
            } else {
                title = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).year())
            }
            if sections.last?.title == title {
                sections[sections.count - 1].notes.append(note)
            } else {
                sections.append(NoteListSection(title: title, notes: [note]))
            }
        }
        return sections
    }

    /// Row date: `9:02` for today, otherwise `2026/05/13` (the Apple Notes layout, fixed regardless of locale).
    public static func rowDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "H:mm" : "yyyy/MM/dd"
        return formatter.string(from: date)
    }
}

extension NoteTitle {
    /// The first non-blank line after the title line, for list previews. Nil when there is none.
    public static func preview(of content: String) -> String? {
        var lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        lines.removeFirst()
        return lines.first
    }
}
