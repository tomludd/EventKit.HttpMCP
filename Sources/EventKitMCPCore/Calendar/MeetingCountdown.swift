import Foundation

/// What the menu bar shows for the next meeting.
public struct CountdownDisplay: Equatable, Sendable {
    public enum Level: Sendable {
        /// Nothing to show (no meeting soon, or it is beyond the warning threshold).
        case hidden
        /// Shown because "always show" is on, but the meeting is not close yet.
        case normal
        /// Within the warning threshold (default 10 minutes).
        case warning
        /// Within the critical threshold (default 4 minutes) — drawn in red.
        case critical
    }

    public var level: Level
    public var text: String
    public var meeting: MeetingSnapshot?
}

public enum MeetingCountdown {
    /// The next meeting that has not started yet. All-day, canceled, declined and sync-created events are ignored.
    public static func nextMeeting(in meetings: [MeetingSnapshot], now: Date) -> MeetingSnapshot? {
        meetings
            .filter { countsAsMeeting($0) && $0.start > now }
            .min { $0.start < $1.start }
    }

    public static func countsAsMeeting(_ meeting: MeetingSnapshot) -> Bool {
        !meeting.isAllDay && !meeting.isCanceled && !meeting.isDeclined && !meeting.isSyncedBlock
    }

    public static func display(
        meetings: [MeetingSnapshot], now: Date, warningMinutes: Int, criticalMinutes: Int,
        alwaysShow: Bool, showTitle: Bool
    ) -> CountdownDisplay {
        guard let next = nextMeeting(in: meetings, now: now) else {
            return CountdownDisplay(level: .hidden, text: "", meeting: nil)
        }
        let remaining = next.start.timeIntervalSince(now)
        let level: CountdownDisplay.Level
        if remaining < TimeInterval(criticalMinutes * 60) {
            level = .critical
        } else if remaining < TimeInterval(warningMinutes * 60) {
            level = .warning
        } else if alwaysShow {
            level = .normal
        } else {
            return CountdownDisplay(level: .hidden, text: "", meeting: next)
        }

        var text = format(remaining: remaining, withSeconds: level != .normal)
        if showTitle {
            text = "\(truncate(next.title, to: 24)) · \(text)"
        }
        return CountdownDisplay(level: level, text: text, meeting: next)
    }

    /// `9:05` with seconds, otherwise `42m` / `1h 05m`.
    public static func format(remaining: TimeInterval, withSeconds: Bool) -> String {
        let total = max(0, Int(remaining.rounded(.up)))
        if withSeconds && total < 3600 {
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        let minutes = Int((Double(total) / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    static func truncate(_ text: String, to length: Int) -> String {
        text.count <= length ? text : String(text.prefix(length - 1)) + "…"
    }
}
