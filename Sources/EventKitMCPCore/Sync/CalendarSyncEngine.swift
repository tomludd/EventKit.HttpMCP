import CryptoKit
import Foundation

public enum SyncMode: String, Codable, Sendable, CaseIterable {
    /// Creates anonymous "Busy" blocking events in the target calendar.
    case block
    /// Copies title and notes of events to the target calendar (shown as Free).
    case copy
}

/// A day of the week, stored by its three-letter code.
public enum Weekday: String, Codable, Sendable, CaseIterable {
    case sun, mon, tue, wed, thu, fri, sat

    public static let workdays: Set<Weekday> = [.mon, .tue, .wed, .thu, .fri]

    /// `Calendar.Component.weekday` numbering: Sunday is 1.
    public var number: Int { Self.allCases.firstIndex(of: self)! + 1 }

    public init?(number: Int) {
        guard (1...7).contains(number) else { return nil }
        self = Self.allCases[number - 1]
    }

    /// "mon", "Monday", "man" style input: the first three letters of the English name.
    public init?(name: String) {
        self.init(rawValue: String(name.lowercased().trimmingCharacters(in: .whitespaces).prefix(3)))
    }
}

/// Which source events a rule syncs, by time of day (`workDayStartHour`–`workDayEndHour`).
public enum HoursFilter: String, Codable, Sendable, CaseIterable {
    /// Every event, whatever the time.
    case any
    /// Only events that start before or end after the hours, e.g. work meetings in the evening.
    case outside
    /// Only events that overlap the hours, e.g. personal appointments during the working day.
    case within
}

public struct SyncOptions: Sendable, Equatable {
    public var mode: SyncMode
    public var hoursFilter: HoursFilter
    /// Days of the week whose events sync; nil means every day.
    public var days: Set<Weekday>?
    public var workDayStartHour: Int
    public var workDayEndHour: Int
    public var blockEventName: String
    public var blockEventLocation: String?
    /// Block events show as Out of Office instead of Busy, where the target calendar supports it.
    public var blockAsOutOfOffice: Bool

    public init(
        mode: SyncMode = .block, hoursFilter: HoursFilter = .any, days: Set<Weekday>? = nil, workDayStartHour: Int = 7,
        workDayEndHour: Int = 18, blockEventName: String = "Busy", blockEventLocation: String? = nil,
        blockAsOutOfOffice: Bool = false
    ) {
        self.mode = mode
        self.hoursFilter = hoursFilter
        self.days = days
        self.workDayStartHour = workDayStartHour
        self.workDayEndHour = workDayEndHour
        self.blockEventName = blockEventName
        self.blockEventLocation = blockEventLocation
        self.blockAsOutOfOffice = blockAsOutOfOffice
    }
}

public struct SyncSummary: Codable, Sendable, Equatable {
    public var created = 0
    public var updated = 0
    public var deleted = 0
    public var skipped = 0
    public var errors = 0

    public init() {}

    public var description: String {
        var text = "\(created) created, \(updated) updated, \(deleted) deleted, \(skipped) skipped"
        if errors > 0 { text += ", \(errors) errors" }
        return text
    }
}

public enum SyncError: LocalizedError {
    case calendarNotFound(String)
    case calendarReadOnly(String)
    case sameCalendar

    public var errorDescription: String? {
        switch self {
        case .calendarNotFound(let id): return "Calendar not found: \(id)"
        case .calendarReadOnly(let name): return "Calendar is read-only: \(name)"
        case .sameCalendar: return "Source and target calendar must differ"
        }
    }
}

/// Mirrors busy time from one calendar into another. Port of outlook-cli's CalendarSyncService.
///
/// Every created event carries `[eventkit-sync:<mode>:<rule hash>]` in its notes. On each run the engine
/// matches its own events to source events by time slot, deletes the ones whose source is gone, refreshes
/// stale block titles/locations and creates what is missing.
public final class CalendarSyncEngine {
    private let backend: CalendarBackend
    private let calendar: Calendar

    public init(backend: CalendarBackend, calendar: Calendar = .current) {
        self.backend = backend
        self.calendar = calendar
    }

    /// Stable marker for a source/target/mode combination.
    public static func marker(mode: SyncMode, sourceCalendarId: String, targetCalendarId: String) -> String {
        marker(mode: mode, key: ruleHash(sourceCalendarId, targetCalendarId))
    }

    static func marker(mode: SyncMode, key: String) -> String {
        "\(SyncMarkers.prefix)\(mode.rawValue):\(key)]"
    }

    static func ruleHash(_ source: String, _ target: String) -> String {
        let digest = SHA256.hash(data: Data("\(source):\(target)".utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// `marker` defaults to `marker(mode:sourceCalendarId:targetCalendarId:)`; saved rules pass their own
    /// so events stay theirs when calendar ids change.
    /// `cleanUpUntil` also deletes this rule's events from `to` up to that date, e.g. after the range got shorter.
    public func run(
        sourceCalendarId: String, targetCalendarId: String, from: Date, to: Date, options: SyncOptions, marker: String? = nil,
        cleanUpUntil: Date? = nil
    ) throws -> SyncSummary {
        guard sourceCalendarId != targetCalendarId else { throw SyncError.sameCalendar }
        guard backend.calendarExists(sourceCalendarId) else { throw SyncError.calendarNotFound(sourceCalendarId) }
        guard backend.calendarExists(targetCalendarId) else { throw SyncError.calendarNotFound(targetCalendarId) }
        guard backend.calendarIsWritable(targetCalendarId) else {
            throw SyncError.calendarReadOnly(backend.calendarDisplayName(targetCalendarId) ?? targetCalendarId)
        }

        let blockName = options.blockEventName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Busy" : options.blockEventName
        let blockLocation = options.blockEventLocation.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let marker = marker ?? Self.marker(mode: options.mode, sourceCalendarId: sourceCalendarId, targetCalendarId: targetCalendarId)
        let sourceName = backend.calendarDisplayName(sourceCalendarId) ?? sourceCalendarId
        // Only compared against existing blocks where Out of Office is possible: other calendars may
        // report a different availability than was saved, which would update the blocks on every run.
        let targetSupportsOutOfOffice = backend.calendarSupportsOutOfOffice(targetCalendarId)

        var summary = SyncSummary()

        let sourceEvents = try backend.events(calendarId: sourceCalendarId, from: from, to: to)
            .filter(shouldSync)
            .filter { matchesDays($0, options) && matchesHours($0, options) }
        // Events of ours beyond `to` have no source in the range, so the pass below deletes them.
        let targetEvents = try backend.events(calendarId: targetCalendarId, from: from, to: max(to, cleanUpUntil ?? to))

        let ours = targetEvents.filter { $0.notes?.contains(marker) == true }
        // Slots taken by other events in the target, and whether one of them already shows Out of Office.
        var realTargetSlots: [Slot: Bool] = [:]
        for event in targetEvents where event.notes?.contains(marker) != true {
            realTargetSlots[Slot(event), default: false] = realTargetSlots[Slot(event)] == true || event.availability == .unavailable
        }
        let sourceKeys = Set(sourceEvents.map { key(for: $0, mode: options.mode) })

        // Delete synced events whose source no longer exists (and duplicates of the same slot);
        // keep the rest so the pass below can refresh stale titles/locations.
        var syncedByKey: [SlotKey: CalendarEventRecord] = [:]
        for synced in ours {
            let syncedKey = key(for: synced, mode: options.mode)
            if sourceKeys.contains(syncedKey) && syncedByKey[syncedKey] == nil {
                syncedByKey[syncedKey] = synced
                continue
            }
            do {
                try backend.deleteEvent(id: synced.id)
                summary.deleted += 1
            } catch {
                summary.errors += 1
            }
        }

        var handled = Set<SlotKey>()
        for source in sourceEvents {
            let sourceKey = key(for: source, mode: options.mode)
            guard handled.insert(sourceKey).inserted else {
                summary.skipped += 1
                continue
            }
            let isOutOfOffice = source.availability == .unavailable

            if let existing = syncedByKey[sourceKey] {
                if options.mode == .block {
                    let expectedTitle = isOutOfOffice ? "Out of Office" : blockName
                    let expectedAvailability = blockAvailability(source, options, targetSupportsOutOfOffice: targetSupportsOutOfOffice)
                    let titleStale = existing.title != expectedTitle
                    let locationStale = blockLocation != nil && existing.location != blockLocation
                    let availabilityStale = targetSupportsOutOfOffice && existing.availability != expectedAvailability
                    if titleStale || locationStale || availabilityStale {
                        do {
                            try backend.updateEvent(
                                id: existing.id, title: expectedTitle, location: blockLocation ?? existing.location,
                                availability: availabilityStale ? expectedAvailability : nil
                            )
                            summary.updated += 1
                        } catch {
                            summary.errors += 1
                        }
                        continue
                    }
                }
                summary.skipped += 1
                continue
            }

            // The target already has an event in this exact slot (e.g. invited in both calendars). An Out of
            // Office block is still added unless that event shows Out of Office too: being away matters
            // more than the meeting it overlaps.
            if options.mode == .block, let slotIsOutOfOffice = realTargetSlots[Slot(source)] {
                let blocksAsOutOfOffice = blockAvailability(source, options, targetSupportsOutOfOffice: targetSupportsOutOfOffice) == .unavailable
                if !blocksAsOutOfOffice || slotIsOutOfOffice {
                    summary.skipped += 1
                    continue
                }
            }

            let draft: EventDraft
            switch options.mode {
            case .copy:
                let sourceNotes = source.notes ?? ""
                draft = EventDraft(
                    title: source.title,
                    start: source.start,
                    end: source.end,
                    isAllDay: source.isAllDay,
                    location: source.location,
                    notes: sourceNotes.isEmpty ? marker : "\(sourceNotes)\n\(marker)",
                    availability: isOutOfOffice ? .unavailable : .free,
                    alertMinutesBefore: [],
                    timeZone: source.timeZone
                )
            case .block:
                draft = EventDraft(
                    title: isOutOfOffice ? "Out of Office" : blockName,
                    start: source.start,
                    end: source.end,
                    isAllDay: source.isAllDay,
                    location: blockLocation,
                    notes: "Blocked from \(sourceName)\n\(marker)",
                    availability: blockAvailability(source, options, targetSupportsOutOfOffice: targetSupportsOutOfOffice),
                    alertMinutesBefore: [],
                    timeZone: source.timeZone
                )
            }

            do {
                try backend.createEvent(draft, calendarId: targetCalendarId)
                summary.created += 1
            } catch {
                summary.errors += 1
            }
        }

        try backend.commit()
        return summary
    }

    /// Deletes sync-created events from a calendar. With `marker` only that rule's events are removed,
    /// otherwise every `[eventkit-sync:` event in the range.
    public func purge(calendarId: String, from: Date, to: Date, marker: String? = nil, dryRun: Bool = false) throws -> Int {
        guard backend.calendarExists(calendarId) else { throw SyncError.calendarNotFound(calendarId) }
        let needle = marker ?? SyncMarkers.prefix
        let doomed = try backend.events(calendarId: calendarId, from: from, to: to)
            .filter { $0.notes?.contains(needle) == true }
        if dryRun { return doomed.count }
        var deleted = 0
        for event in doomed {
            if (try? backend.deleteEvent(id: event.id)) != nil { deleted += 1 }
        }
        try backend.commit()
        return deleted
    }

    // MARK: - Filtering

    func shouldSync(_ event: CalendarEventRecord) -> Bool {
        if event.status == .canceled { return false }
        if event.myParticipation == .declined { return false }
        if SyncMarkers.isSynced(notes: event.notes) { return false }

        switch event.availability {
        case .busy, .unavailable:
            return true
        case .free, .tentative:
            return false
        case .notSupported:
            // Calendars without free/busy (e.g. "On My Mac"): timed events count as busy, all-day as free.
            return !event.isAllDay
        }
    }

    /// Out of Office sources always block as Out of Office; others only when the rule asks for it and
    /// the target calendar can show it, so they stay Busy rather than lose their availability.
    func blockAvailability(_ source: CalendarEventRecord, _ options: SyncOptions, targetSupportsOutOfOffice: Bool) -> EventAvailability {
        if source.availability == .unavailable { return .unavailable }
        return options.blockAsOutOfOffice && targetSupportsOutOfOffice ? .unavailable : .busy
    }

    /// All-day and multi-day events pass both filters: they cover the hours and the time around them.
    func matchesHours(_ event: CalendarEventRecord, _ options: SyncOptions) -> Bool {
        if options.hoursFilter == .any || event.isAllDay { return true }
        let start = calendar.dateComponents([.hour, .minute], from: event.start)
        let end = calendar.dateComponents([.hour, .minute], from: event.end)
        let startMinutes = (start.hour ?? 0) * 60 + (start.minute ?? 0)
        var endMinutes = (end.hour ?? 0) * 60 + (end.minute ?? 0)
        if !calendar.isDate(event.start, inSameDayAs: event.end) {
            // For "within", an event ending at midnight still belongs to the day it started. "outside"
            // keeps counting it as outside, as it always has, so existing rules sync the same events.
            let endsAtMidnight = endMinutes == 0
                && calendar.isDate(event.end, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: event.start)!)
            guard options.hoursFilter == .within, endsAtMidnight else { return true }
            endMinutes = 24 * 60
        }
        let windowStart = options.workDayStartHour * 60
        let windowEnd = options.workDayEndHour * 60
        switch options.hoursFilter {
        case .any: return true
        case .outside: return startMinutes < windowStart || endMinutes > windowEnd
        case .within: return startMinutes < windowEnd && endMinutes > windowStart
        }
    }

    /// Whether the event falls on one of the rule's days. All-day and multi-day events need to cover one.
    func matchesDays(_ event: CalendarEventRecord, _ options: SyncOptions) -> Bool {
        guard let days = options.days else { return true }
        var day = calendar.startOfDay(for: event.start)
        // Seven days cover every weekday.
        for _ in 0..<7 {
            if let weekday = Weekday(number: calendar.component(.weekday, from: day)), days.contains(weekday) { return true }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
            if day >= event.end { break }
        }
        return false
    }

    // MARK: - Matching

    struct Slot: Hashable {
        let start: Int64
        let end: Int64

        init(_ event: CalendarEventRecord) {
            start = Int64(event.start.timeIntervalSince1970.rounded())
            end = Int64(event.end.timeIntervalSince1970.rounded())
        }
    }

    struct SlotKey: Hashable {
        let slot: Slot
        let title: String?
    }

    /// Block events are matched to their source by time slot. Copies also match on title so two
    /// different meetings in the same slot each get a copy; a renamed source is replaced by a new copy.
    func key(for event: CalendarEventRecord, mode: SyncMode) -> SlotKey {
        SlotKey(slot: Slot(event), title: mode == .copy ? event.title : nil)
    }
}
