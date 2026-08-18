import Foundation

/// Recorded sessions, bucketed the way a photographer thinks about them.
///
/// A flat reverse-chronological list answers "what is the newest?" and nothing else.
/// Buckets answer "where is the one from the game last Saturday?", which is the
/// question someone actually opens this list with.
nonisolated enum SessionGrouping {
    struct Group: Identifiable, Equatable {
        /// Stable across regroupings so `List` can animate rather than reload.
        let id: String
        let title: String
        let sessionIDs: [UUID]
    }

    /// Buckets `sessions` — which must already be newest-first — relative to `now`.
    ///
    /// Recent sessions get relative names because that is how they are remembered;
    /// anything older falls back to its month, which stays unambiguous however long
    /// the list grows.
    static func groups(
        startedAtByID: [(id: UUID, startedAt: Date)],
        now: Date,
        calendar: Calendar = .current
    ) -> [Group] {
        var order: [String] = []
        var titles: [String: String] = [:]
        var buckets: [String: [UUID]] = [:]

        for entry in startedAtByID {
            let (key, title) = bucket(for: entry.startedAt, now: now, calendar: calendar)
            if buckets[key] == nil {
                order.append(key)
                titles[key] = title
                buckets[key] = []
            }
            buckets[key]?.append(entry.id)
        }

        return order.map { key in
            Group(id: key, title: titles[key] ?? key, sessionIDs: buckets[key] ?? [])
        }
    }

    private static func bucket(
        for date: Date,
        now: Date,
        calendar: Calendar
    ) -> (key: String, title: String) {
        // Everything below is relative to `now`, never to the process's own idea of
        // the current moment: `isDateInToday` and friends consult the real clock, which
        // would silently ignore the parameter and make this untestable.
        let startOfToday = calendar.startOfDay(for: now)

        if calendar.isDate(date, inSameDayAs: now) {
            return ("today", "Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return ("yesterday", "Yesterday")
        }

        // "Last 7 days" rather than the calendar week: on a Monday, a calendar week
        // would push Saturday's game into "Earlier" while it is still the most recent
        // thing the photographer shot.
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday),
           date >= weekAgo {
            return ("week", "Earlier This Week")
        }

        let month = calendar.component(.month, from: date)
        let year = calendar.component(.year, from: date)
        let key = String(format: "m%04d-%02d", year, month)

        // Same-year months drop the year, the way Photos and Mail do.
        let sameYear = year == calendar.component(.year, from: now)
        let title = sameYear
            ? date.formatted(.dateTime.month(.wide))
            : date.formatted(.dateTime.month(.wide).year())
        return (key, title)
    }
}
