import Foundation

/// Parses the date/time strings accepted by the MCP tools and formats dates for output.
public enum DateInput {
    /// Parses ISO 8601 (with or without offset), `yyyy-MM-dd HH:mm`, `yyyy-MM-dd`, or the keywords
    /// `now`, `today`, `tomorrow`, `yesterday`. Values without an offset are local time.
    ///
    /// When `endOfDayIfDateOnly` is set, a date-only value resolves to the start of the *next* day so it
    /// can be used as an exclusive range end that still covers the whole day.
    public static func parse(
        _ input: String,
        now: Date = Date(),
        endOfDayIfDateOnly: Bool = false,
        calendar: Calendar = .current
    ) -> Date? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let startOfToday = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date {
            let base = calendar.date(byAdding: .day, value: offset, to: startOfToday)!
            return endOfDayIfDateOnly ? calendar.date(byAdding: .day, value: 1, to: base)! : base
        }

        switch text.lowercased() {
        case "now": return now
        case "today": return day(0)
        case "tomorrow": return day(1)
        case "yesterday": return day(-1)
        default: break
        }

        for options in [ISO8601DateFormatter.Options.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            if let date = localFormatter(format, calendar: calendar).date(from: text) { return date }
        }

        if let date = localFormatter("yyyy-MM-dd", calendar: calendar).date(from: text) {
            let start = calendar.startOfDay(for: date)
            return endOfDayIfDateOnly ? calendar.date(byAdding: .day, value: 1, to: start)! : start
        }

        return nil
    }

    /// True when the input names a whole day rather than an instant.
    public static func isDateOnly(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["today", "tomorrow", "yesterday"].contains(text) { return true }
        return text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// ISO 8601 in the local time zone, e.g. `2026-10-15T14:00:00+02:00`.
    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .autoupdatingCurrent
        return formatter.string(from: date)
    }

    public static func formatDay(_ date: Date, calendar: Calendar = .current) -> String {
        localFormatter("yyyy-MM-dd", calendar: calendar).string(from: date)
    }

    private static func localFormatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
}
