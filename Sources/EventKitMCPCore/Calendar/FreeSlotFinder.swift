import Foundation

public struct FreeSlot: Codable, Sendable, Equatable {
    public var start: String
    public var end: String
    public var minutes: Int
}

public struct BusyInterval: Sendable, Equatable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// Finds gaps of at least `durationMinutes` inside working hours between busy intervals.
public enum FreeSlotFinder {
    public static func find(
        busy: [BusyInterval], from: Date, to: Date, durationMinutes: Int, workStartHour: Int, workEndHour: Int,
        includeWeekends: Bool, now: Date = Date(), calendar: Calendar = .current
    ) -> [FreeSlot] {
        let merged = merge(busy)
        var slots: [FreeSlot] = []
        var day = calendar.startOfDay(for: from)
        let minimum = TimeInterval(durationMinutes * 60)

        while day < to {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day)! }
            if !includeWeekends && calendar.isDateInWeekend(day) { continue }
            guard let workStart = calendar.date(bySettingHour: workStartHour, minute: 0, second: 0, of: day),
                  let workEnd = calendar.date(bySettingHour: min(workEndHour, 23), minute: workEndHour >= 24 ? 59 : 0, second: 0, of: day)
            else { continue }

            var cursor = max(workStart, from, roundUpToFiveMinutes(now, calendar: calendar))
            let dayEnd = min(workEnd, to)
            guard cursor < dayEnd else { continue }

            for interval in merged where interval.end > cursor && interval.start < dayEnd {
                if interval.start.timeIntervalSince(cursor) >= minimum {
                    slots.append(slot(cursor, interval.start))
                }
                cursor = max(cursor, interval.end)
                if cursor >= dayEnd { break }
            }
            if dayEnd.timeIntervalSince(cursor) >= minimum {
                slots.append(slot(cursor, dayEnd))
            }
        }
        return slots
    }

    static func merge(_ intervals: [BusyInterval]) -> [BusyInterval] {
        var result: [BusyInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.end > interval.start {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1].end = max(last.end, interval.end)
            } else {
                result.append(interval)
            }
        }
        return result
    }

    private static func slot(_ start: Date, _ end: Date) -> FreeSlot {
        FreeSlot(start: DateInput.format(start), end: DateInput.format(end), minutes: Int(end.timeIntervalSince(start) / 60))
    }

    private static func roundUpToFiveMinutes(_ date: Date, calendar: Calendar) -> Date {
        // Every real time zone offset is a whole multiple of five minutes, so UTC boundaries are local ones too.
        let step: TimeInterval = 300
        return Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }
}
