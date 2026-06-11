import Foundation

enum HistoryTimestampFormatter {
    static func displayText(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return timeText(for: date, calendar: calendar)
        }

        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        guard let days = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day
        else {
            return timeText(for: date, calendar: calendar)
        }

        if days <= 1 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }
        if days < 30 {
            let weeks = days / 7
            return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
        }

        let components = calendar.dateComponents([.year, .month], from: date, to: now)
        let years = components.year ?? 0
        if years == 1 { return "Last year" }
        if years >= 2 { return "\(years) years ago" }

        let months = max(1, components.month ?? days / 30)
        return months == 1 ? "1 month ago" : "\(months) months ago"
    }

    private static func timeText(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

struct SessionDateGroup: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var sessions: [HermesSessionListItem]
}

enum SessionDateGrouper {
    static func groups(
        for sessions: [HermesSessionListItem],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [SessionDateGroup] {
        var groups: [SessionDateGroup] = []
        let hasToday = sessions.contains { session in
            session.lastActiveDate.map { calendar.isDate($0, inSameDayAs: now) } ?? false
        }
        let hasYesterday = sessions.contains { session in
            guard let date = session.lastActiveDate else { return false }
            return isYesterday(date, now: now, calendar: calendar)
        }
        let usesRelativeDayGroups = hasToday || hasYesterday

        for session in sessions {
            let groupKey = groupKey(
                for: session,
                now: now,
                calendar: calendar,
                usesRelativeDayGroups: usesRelativeDayGroups
            )

            if let index = groups.firstIndex(where: { $0.id == groupKey.id }) {
                groups[index].sessions.append(session)
            } else {
                groups.append(SessionDateGroup(id: groupKey.id, title: groupKey.title, sessions: [session]))
            }
        }

        return groups
    }

    private static func groupKey(
        for session: HermesSessionListItem,
        now: Date,
        calendar: Calendar,
        usesRelativeDayGroups: Bool
    ) -> (id: String, title: String) {
        guard let date = session.lastActiveDate else {
            return ("unknown", "Unknown date")
        }

        if usesRelativeDayGroups {
            if calendar.isDate(date, inSameDayAs: now) {
                return ("today", "Today")
            }

            if isYesterday(date, now: now, calendar: calendar) {
                return ("yesterday", "Yesterday")
            }
        }

        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let key = String(format: "%04d-%02d", year, month)
        return (key, key)
    }

    private static func isYesterday(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else {
            return false
        }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }
}
