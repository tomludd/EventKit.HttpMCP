import Foundation

public enum EventAvailability: String, Codable, Sendable, CaseIterable {
    case busy, free, tentative, unavailable, notSupported
}

public enum EventStatus: String, Codable, Sendable {
    case none, confirmed, tentative, canceled
}

public enum ParticipationStatus: String, Codable, Sendable {
    case unknown, pending, accepted, declined, tentative, delegated, completed, inProcess
}

/// Markers written into the notes of events created by calendar sync. Events carrying any of
/// them are never synced again, which prevents block events cascading between calendars.
public enum SyncMarkers {
    public static let prefix = "[eventkit-sync:"
    /// Written by outlook-cli on Windows; respected so the two tools don't re-sync each other's blocks.
    public static let outlookPrefix = "[outlook-sync:"

    public static func isSynced(notes: String?) -> Bool {
        guard let notes else { return false }
        return notes.contains(prefix) || notes.contains(outlookPrefix)
    }
}

/// The subset of an event the sync engine works with. Free of EventKit types so the engine is testable.
public struct CalendarEventRecord: Sendable, Equatable {
    public var id: String
    public var calendarId: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var availability: EventAvailability
    public var status: EventStatus
    public var myParticipation: ParticipationStatus?

    public init(
        id: String, calendarId: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
        location: String? = nil, notes: String? = nil, availability: EventAvailability = .busy,
        status: EventStatus = .none, myParticipation: ParticipationStatus? = nil
    ) {
        self.id = id
        self.calendarId = calendarId
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.availability = availability
        self.status = status
        self.myParticipation = myParticipation
    }
}

public struct EventDraft: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var availability: EventAvailability
    /// nil keeps the calendar default, an empty array means no alerts.
    public var alertMinutesBefore: [Int]?

    public init(
        title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil,
        notes: String? = nil, availability: EventAvailability = .busy, alertMinutesBefore: [Int]? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.availability = availability
        self.alertMinutesBefore = alertMinutesBefore
    }
}

/// Calendar operations needed by `CalendarSyncEngine`.
public protocol CalendarBackend: AnyObject {
    func calendarExists(_ calendarId: String) -> Bool
    func calendarIsWritable(_ calendarId: String) -> Bool
    func calendarDisplayName(_ calendarId: String) -> String?
    func events(calendarId: String, from: Date, to: Date) throws -> [CalendarEventRecord]
    func createEvent(_ draft: EventDraft, calendarId: String) throws
    func updateEvent(id: String, title: String, location: String?) throws
    func deleteEvent(id: String) throws
    /// Persists changes made with the methods above.
    func commit() throws
}

// MARK: - Output DTOs (MCP tool results)

public struct CalendarInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var account: String
    public var accountType: String
    public var color: String?
    public var writable: Bool
    public var isDefault: Bool
    public var supportsAvailability: Bool

    /// "Work (Exchange)" style label used in pickers and sync rule names.
    public var displayName: String { account.isEmpty ? title : "\(title) (\(account))" }
}

public struct ParticipantInfo: Codable, Sendable {
    public var name: String?
    public var email: String?
    public var status: String
    public var role: String
    public var type: String
    public var isCurrentUser: Bool?
}

public struct RecurrenceInfo: Codable, Sendable {
    public var frequency: String
    public var interval: Int
    public var daysOfWeek: [String]?
    public var until: String?
    public var count: Int?
}

public struct EventInfo: Codable, Sendable {
    public var id: String
    public var title: String
    public var start: String
    public var end: String
    public var allDay: Bool
    public var calendar: String
    public var calendarId: String
    public var account: String?
    public var location: String?
    public var url: String?
    public var joinUrl: String?
    public var availability: String
    public var status: String
    public var myStatus: String?
    public var recurring: Bool
    public var recurrence: RecurrenceInfo?
    public var organizer: ParticipantInfo?
    public var attendees: [ParticipantInfo]?
    public var alertsMinutesBefore: [Int]?
    public var synced: Bool?
    public var minutesUntilStart: Int?
    public var notes: String?
}

/// Lightweight view of an upcoming meeting for the menu bar.
public struct MeetingSnapshot: Sendable, Equatable, Identifiable {
    public var id: String
    public var eventIdentifier: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var joinURL: URL?
    public var calendarId: String
    public var calendarTitle: String
    public var calendarColorHex: String?
    public var isDeclined: Bool
    public var isCanceled: Bool
    public var isSyncedBlock: Bool

    public init(
        id: String, eventIdentifier: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
        location: String? = nil, joinURL: URL? = nil, calendarId: String = "", calendarTitle: String = "",
        calendarColorHex: String? = nil, isDeclined: Bool = false, isCanceled: Bool = false, isSyncedBlock: Bool = false
    ) {
        self.id = id
        self.eventIdentifier = eventIdentifier
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.joinURL = joinURL
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.calendarColorHex = calendarColorHex
        self.isDeclined = isDeclined
        self.isCanceled = isCanceled
        self.isSyncedBlock = isSyncedBlock
    }

    public func isOngoing(at now: Date) -> Bool { start <= now && end > now }
}
