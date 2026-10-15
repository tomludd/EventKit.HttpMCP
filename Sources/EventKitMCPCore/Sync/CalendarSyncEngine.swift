import CryptoKit
import Foundation

public enum SyncMode: String, Codable, Sendable, CaseIterable {
    /// Creates anonymous "Busy" blocking events in the target calendar.
    case block
    /// Copies title and notes of events to the target calendar (shown as Free).
    case copy
}

public struct SyncOptions: Sendable, Equatable {
    public var mode: SyncMode
    public var outsideWorkHoursOnly: Bool
    public var workDayStartHour: Int
    public var workDayEndHour: Int
    public var blockEventName: String
    public var blockEventLocation: String?

    public init(
        mode: SyncMode = .block, outsideWorkHoursOnly: Bool = false, workDayStartHour: Int = 7,
        workDayEndHour: Int = 18, blockEventName: String = "Busy", blockEventLocation: String? = nil
    ) {
        self.mode = mode
        self.outsideWorkHoursOnly = outsideWorkHoursOnly
        self.workDayStartHour = workDayStartHour
        self.workDayEndHour = workDayEndHour
        self.blockEventName = blockEventName
        self.blockEventLocation = blockEventLocation
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
        "\(SyncMarkers.prefix)\(mode.rawValue):\(ruleHash(sourceCalendarId, targetCalendarId))]"
    }

    static func ruleHash(_ source: String, _ target: String) -> String {
        let digest = SHA256.hash(data: Data("\(source):\(target)".utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public func run(
        sourceCalendarId: String, targetCalendarId: String, from: Date, to: Date, options: SyncOptions
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
        let marker = Self.marker(mode: options.mode, sourceCalendarId: sourceCalendarId, targetCalendarId: targetCalendarId)
        let sourceName = backend.calendarDisplayName(sourceCalendarId) ?? sourceCalendarId

        var summary = SyncSummary()

        let sourceEvents = try backend.events(calendarId: sourceCalendarId, from: from, to: to)
            .filter(shouldSync)
            .filter { !options.outsideWorkHoursOnly || isOutsideWorkHours($0, options) }
        let targetEvents = try backend.events(calendarId: targetCalendarId, from: from, to: to)

        let ours = targetEvents.filter { $0.notes?.contains(marker) == true }
        let realTargetSlots = Set(targetEvents.filter { $0.notes?.contains(marker) != true }.map(Slot.init))
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
                    let titleStale = existing.title != expectedTitle
                    let locationStale = blockLocation != nil && existing.location != blockLocation
                    if titleStale || locationStale {
                        do {
                            try backend.updateEvent(id: existing.id, title: expectedTitle, location: blockLocation ?? existing.location)
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

            // The target already has a real event in this exact slot (e.g. invited in both calendars).
            if options.mode == .block && realTargetSlots.contains(Slot(source)) {
                summary.skipped += 1
                continue
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
                    alertMinutesBefore: []
                )
            case .block:
                draft = EventDraft(
                    title: isOutOfOffice ? "Out of Office" : blockName,
                    start: source.start,
                    end: source.end,
                    isAllDay: source.isAllDay,
                    location: blockLocation,
                    notes: "Blocked from \(sourceName)\n\(marker)",
                    availability: isOutOfOffice ? .unavailable : .busy,
                    alertMinutesBefore: []
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

    func isOutsideWorkHours(_ event: CalendarEventRecord, _ options: SyncOptions) -> Bool {
        if event.isAllDay { return true }
        let start = calendar.dateComponents([.hour, .minute], from: event.start)
        let end = calendar.dateComponents([.hour, .minute], from: event.end)
        let startMinutes = (start.hour ?? 0) * 60 + (start.minute ?? 0)
        let endMinutes = (end.hour ?? 0) * 60 + (end.minute ?? 0)
        if !calendar.isDate(event.start, inSameDayAs: event.end) { return true }
        return startMinutes < options.workDayStartHour * 60 || endMinutes > options.workDayEndHour * 60
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
