import Foundation
import Testing
@testable import SillCore

@Suite struct NoteListGroupingTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()
    // 2026-05-15 10:00 JST
    let now = Date(timeIntervalSince1970: 1_778_806_800)

    private func note(_ title: String, daysAgo: Double) -> Note {
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        return Note(id: UUID(), content: title, createdAt: date, updatedAt: date, version: Version(device: UUID(), seq: 1))
    }

    @Test func groupsLikeAppleNotes() {
        let notes = [
            note("today", daysAgo: 0.1),
            note("yesterday", daysAgo: 1),
            note("this week", daysAgo: 5),
            note("this month", daysAgo: 20),
            note("march", daysAgo: 60),
            note("january", daysAgo: 130),
            note("last year", daysAgo: 400),
        ]
        let sections = NoteListGrouping.sections(for: notes, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "March", "January", "2025"])
        #expect(sections.map { $0.notes.count } == [1, 1, 1, 1, 1, 1, 1])
    }

    @Test func consecutiveNotesShareASection() {
        let notes = [note("a", daysAgo: 0.1), note("b", daysAgo: 0.2), note("c", daysAgo: 3)]
        let sections = NoteListGrouping.sections(for: notes, now: now, calendar: calendar)
        #expect(sections.map { ($0.title, $0.notes.count) }.map { "\($0.0):\($0.1)" } == ["Today:2", "Previous 7 Days:1"])
    }

    @Test func rowDateIsTimeForTodayAndNumericDateOtherwise() {
        #expect(NoteListGrouping.rowDate(now.addingTimeInterval(-3600), now: now, calendar: calendar) == "9:00")
        #expect(NoteListGrouping.rowDate(now.addingTimeInterval(-2 * 86_400), now: now, calendar: calendar) == "2026/05/13")
    }

    @Test(arguments: [
        ("# Title\nbody line\nmore", "body line"),
        ("Title\n\n  second  \n", "second"),
        ("only title", nil),
        ("", nil),
    ])
    func previewIsTheLineAfterTheTitle(content: String, expected: String?) {
        #expect(NoteTitle.preview(of: content) == expected)
    }
}
