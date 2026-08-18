import Foundation
import Testing
@testable import GPeX

@Suite("Session grouping")
nonisolated struct SessionGroupingTests {
    /// Wednesday 2026-08-19, 14:00 local. A midweek anchor so "earlier this week"
    /// and "last 7 days" can actually disagree.
    private let now = Date(timeIntervalSince1970: 1_787_148_000)

    /// A UTC calendar so these expectations do not change with the machine's zone.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func entry(hoursAgo: Double) -> (id: UUID, startedAt: Date) {
        (id: UUID(), startedAt: now.addingTimeInterval(-hoursAgo * 3_600))
    }

    private func groups(_ entries: [(id: UUID, startedAt: Date)]) -> [SessionGrouping.Group] {
        SessionGrouping.groups(startedAtByID: entries, now: now, calendar: calendar)
    }

    @Test("Today, yesterday and the rest of the week are named relatively")
    func relativeBuckets() throws {
        let today = entry(hoursAgo: 2)
        let yesterday = entry(hoursAgo: 26)
        let midweek = entry(hoursAgo: 3 * 24)

        let result = groups([today, yesterday, midweek])

        try #require(result.count == 3)
        #expect(result.map(\.title) == ["Today", "Yesterday", "Earlier This Week"])
        #expect(result[0].sessionIDs == [today.id])
        #expect(result[1].sessionIDs == [yesterday.id])
        #expect(result[2].sessionIDs == [midweek.id])
    }

    @Test("Anything older than a week falls back to its month")
    func monthBuckets() throws {
        let lastMonth = entry(hoursAgo: 40 * 24)
        let result = groups([lastMonth])

        try #require(result.count == 1)
        // July 2026 — same year as the anchor, so the year is dropped.
        #expect(result[0].title == "July")
    }

    @Test("A month in another year keeps its year")
    func priorYearKeepsYear() throws {
        let lastYear = entry(hoursAgo: 400 * 24)
        let result = groups([lastYear])

        try #require(result.count == 1)
        #expect(result[0].title.contains("2025"))
    }

    @Test("The seven-day window is relative to today, not to the calendar week")
    func sevenDayWindowIgnoresWeekBoundary() throws {
        // Six days back from a Wednesday is the previous Thursday — a different
        // calendar week, but still the most recent thing the photographer shot.
        let sixDaysAgo = entry(hoursAgo: 6 * 24)
        let eightDaysAgo = entry(hoursAgo: 8 * 24)

        let result = groups([sixDaysAgo, eightDaysAgo])

        try #require(result.count == 2)
        #expect(result[0].title == "Earlier This Week")
        #expect(result[0].sessionIDs == [sixDaysAgo.id])
        #expect(result[1].title != "Earlier This Week")
        #expect(result[1].sessionIDs == [eightDaysAgo.id])
    }

    @Test("Order is preserved, and same-bucket tracks stay together")
    func preservesOrderWithinBuckets() throws {
        let first = entry(hoursAgo: 1)
        let second = entry(hoursAgo: 3)
        let third = entry(hoursAgo: 5)

        let result = groups([first, second, third])

        try #require(result.count == 1)
        #expect(result[0].sessionIDs == [first.id, second.id, third.id])
    }

    @Test("No tracks means no sections")
    func emptyInput() {
        #expect(groups([]).isEmpty)
    }

    @Test("Group ids are stable so the list animates instead of reloading")
    func stableIdentifiers() {
        let entries = [entry(hoursAgo: 2), entry(hoursAgo: 30 * 24)]
        #expect(groups(entries).map(\.id) == groups(entries).map(\.id))
    }
}
