import AppKit
import EventKit
import Foundation

public struct CalendarStoreError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// All EventKit access goes through this type. Calls are serialized on one queue because
/// EKEventStore/EKEvent objects must not be used from several threads at once.
public final class EventKitCalendarStore: CalendarBackend, @unchecked Sendable {
    public let store = EKEventStore()
    private let queue = DispatchQueue(label: "eventkit-mcp.store", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()

    public init() {
        queue.setSpecific(key: queueKey, value: true)
    }

    private func onQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try work() }
        return try queue.sync(execute: work)
    }

    // MARK: - Access

    public static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    public static var hasFullAccess: Bool {
        authorizationStatus == .fullAccess
    }

    public static var authorizationDescription: String {
        switch authorizationStatus {
        case .fullAccess: return "granted"
        case .writeOnly: return "write-only"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not requested"
        @unknown default: return "unknown"
        }
    }

    public func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            if granted { onQueue { store.reset() } }
            return granted
        } catch {
            NSLog("EventKitMCP: calendar access request failed: \(error)")
            return false
        }
    }

    private func ensureAccess() throws {
        guard Self.hasFullAccess else {
            throw CalendarStoreError(
                "EventKit MCP has no calendar access (status: \(Self.authorizationDescription)). Ask the user to open the EventKit MCP menu bar item and choose “Grant Calendar Access…”."
            )
        }
    }

    // MARK: - Calendars

    public func calendars() throws -> [CalendarInfo] {
        try ensureAccess()
        return onQueue {
            let defaultId = store.defaultCalendarForNewEvents?.calendarIdentifier
            return store.calendars(for: .event)
                .map { Self.info(for: $0, defaultId: defaultId) }
                .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        }
    }

    public func calendarInfo(reference: String) throws -> CalendarInfo {
        try ensureAccess()
        return try onQueue {
            Self.info(for: try resolveCalendar(reference), defaultId: store.defaultCalendarForNewEvents?.calendarIdentifier)
        }
    }

    /// Accepts a calendar identifier, a title, or "Title (Account)".
    func resolveCalendar(_ reference: String) throws -> EKCalendar {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        if let calendar = store.calendar(withIdentifier: ref) { return calendar }
        let all = store.calendars(for: .event)
        let byDisplayName = all.filter { Self.displayName($0).caseInsensitiveCompare(ref) == .orderedSame }
        if byDisplayName.count == 1 { return byDisplayName[0] }
        let byTitle = all.filter { $0.title.caseInsensitiveCompare(ref) == .orderedSame }
        if byTitle.count == 1 { return byTitle[0] }
        if byTitle.count > 1 {
            let options = byTitle.map { "\(Self.displayName($0)) [id: \($0.calendarIdentifier)]" }.joined(separator: "; ")
            throw CalendarStoreError("Calendar name '\(ref)' is ambiguous. Use one of: \(options)")
        }
        let names = all.map(Self.displayName).sorted().joined(separator: ", ")
        throw CalendarStoreError("Calendar not found: '\(ref)'. Available calendars: \(names)")
    }

    func resolveCalendars(_ references: [String]?) throws -> [EKCalendar]? {
        guard let references, !references.isEmpty else { return nil }
        return try references.map(resolveCalendar)
    }

    // MARK: - Events (MCP)

    public func events(
        from: Date, to: Date, calendars references: [String]?, includeNotes: Bool, now: Date = Date()
    ) throws -> [EventInfo] {
        try ensureAccess()
        return try onQueue {
            let calendars = try resolveCalendars(references)
            return try fetch(from: from, to: to, calendars: calendars)
                .map { Self.info(for: $0, includeNotes: includeNotes, now: now) }
        }
    }

    public func event(id: String) throws -> EventInfo {
        try ensureAccess()
        return try onQueue {
            Self.info(for: try findEvent(id: id), includeNotes: true, includeDetails: true, now: Date())
        }
    }

    public struct EventChanges {
        public var title: String?
        public var start: Date?
        public var end: Date?
        public var isAllDay: Bool?
        public var calendar: String?
        public var location: String??
        public var notes: String??
        public var url: String??
        public var availability: EventAvailability?
        public var alertMinutesBefore: [Int]?
        public var recurrence: RecurrenceInput?

        public init() {}
    }

    public struct RecurrenceInput {
        public var frequency: String
        public var interval: Int
        public var daysOfWeek: [String]?
        public var until: Date?
        public var count: Int?

        public init(frequency: String, interval: Int = 1, daysOfWeek: [String]? = nil, until: Date? = nil, count: Int? = nil) {
            self.frequency = frequency
            self.interval = interval
            self.daysOfWeek = daysOfWeek
            self.until = until
            self.count = count
        }
    }

    public func createEvent(_ changes: EventChanges) throws -> EventInfo {
        try ensureAccess()
        return try onQueue {
            let event = EKEvent(eventStore: store)
            if let reference = changes.calendar {
                event.calendar = try resolveCalendar(reference)
            } else if let calendar = store.defaultCalendarForNewEvents {
                event.calendar = calendar
            } else {
                throw CalendarStoreError("No default calendar; pass `calendar`.")
            }
            guard event.calendar.allowsContentModifications else {
                throw CalendarStoreError("Calendar is read-only: \(Self.displayName(event.calendar))")
            }
            try apply(changes, to: event)
            try store.save(event, span: .thisEvent, commit: true)
            return Self.info(for: event, includeNotes: true, includeDetails: true, now: Date())
        }
    }

    public func updateEvent(id: String, changes: EventChanges, futureEvents: Bool) throws -> EventInfo {
        try ensureAccess()
        return try onQueue {
            let event = try findEvent(id: id)
            guard event.calendar.allowsContentModifications else {
                throw CalendarStoreError("Calendar is read-only: \(Self.displayName(event.calendar))")
            }
            if let reference = changes.calendar {
                event.calendar = try resolveCalendar(reference)
            }
            try apply(changes, to: event)
            try store.save(event, span: futureEvents ? .futureEvents : .thisEvent, commit: true)
            return Self.info(for: event, includeNotes: true, includeDetails: true, now: Date())
        }
    }

    public func deleteEvent(id: String, futureEvents: Bool) throws -> EventInfo {
        try ensureAccess()
        return try onQueue {
            let event = try findEvent(id: id)
            let info = Self.info(for: event, includeNotes: false, now: Date())
            try store.remove(event, span: futureEvents ? .futureEvents : .thisEvent, commit: true)
            return info
        }
    }

    /// Time blocked by events: everything except free, canceled and declined events. All-day events
    /// only count when explicitly marked busy or out of office.
    public func busyIntervals(from: Date, to: Date, calendars references: [String]?) throws -> [BusyInterval] {
        try ensureAccess()
        return try onQueue {
            let calendars = try resolveCalendars(references)
            return try fetch(from: from, to: to, calendars: calendars).compactMap { event in
                if event.status == .canceled || Self.myParticipation(event) == .declined { return nil }
                let availability = Self.availability(event.availability)
                if availability == .free { return nil }
                if event.isAllDay && availability != .busy && availability != .unavailable { return nil }
                return BusyInterval(start: event.startDate, end: event.endDate)
            }
        }
    }

    private func apply(_ changes: EventChanges, to event: EKEvent) throws {
        if let title = changes.title { event.title = title }
        if let isAllDay = changes.isAllDay { event.isAllDay = isAllDay }

        let oldStart: Date? = event.startDate
        let oldEnd: Date? = event.endDate
        if let start = changes.start {
            event.startDate = start
            if changes.end == nil, let oldStart, let oldEnd {
                event.endDate = start.addingTimeInterval(oldEnd.timeIntervalSince(oldStart))
            }
        }
        if let end = changes.end { event.endDate = end }
        guard let start = event.startDate, let end = event.endDate else {
            throw CalendarStoreError("Event needs both start and end.")
        }
        if event.isAllDay ? end < start : end <= start {
            throw CalendarStoreError("End (\(DateInput.format(end))) must be after start (\(DateInput.format(start))).")
        }

        if let location = changes.location { event.location = location }
        if let notes = changes.notes { event.notes = notes }
        if let url = changes.url { event.url = url.flatMap(URL.init(string:)) }
        if let availability = changes.availability, !event.calendar.supportedEventAvailabilities.isEmpty {
            event.availability = Self.ekAvailability(availability)
        }
        if let minutes = changes.alertMinutesBefore {
            event.alarms = minutes.map { EKAlarm(relativeOffset: TimeInterval(-$0 * 60)) }
        }
        if let recurrence = changes.recurrence {
            event.recurrenceRules = [try Self.recurrenceRule(recurrence)]
        }
    }

    // MARK: - Menu bar

    public func upcomingMeetings(from now: Date, hours: Int, calendarIds: [String]?) -> [MeetingSnapshot] {
        guard Self.hasFullAccess else { return [] }
        return onQueue {
            let calendars = calendarIds.map { ids in ids.compactMap { store.calendar(withIdentifier: $0) } }
            if let calendars, calendars.isEmpty { return [] }
            let end = now.addingTimeInterval(TimeInterval(hours * 3600))
            let events = (try? fetch(from: now, to: end, calendars: calendars)) ?? []
            return events.filter { $0.endDate > now }.map { event in
                let info = Self.info(for: event, includeNotes: false, now: now)
                return MeetingSnapshot(
                    id: info.id,
                    eventIdentifier: event.eventIdentifier ?? "",
                    title: info.title,
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    location: event.location,
                    joinURL: info.joinUrl.flatMap(URL.init(string:)),
                    calendarId: event.calendar.calendarIdentifier,
                    calendarTitle: event.calendar.title,
                    calendarColorHex: Self.hex(event.calendar.color),
                    isDeclined: Self.myParticipation(event) == .declined,
                    isCanceled: event.status == .canceled,
                    isSyncedBlock: SyncMarkers.isSynced(notes: event.notes)
                )
            }
        }
    }

    // MARK: - CalendarBackend (sync engine)

    public func calendarExists(_ calendarId: String) -> Bool {
        onQueue { store.calendar(withIdentifier: calendarId) != nil }
    }

    public func calendarIsWritable(_ calendarId: String) -> Bool {
        onQueue { store.calendar(withIdentifier: calendarId)?.allowsContentModifications ?? false }
    }

    public func calendarDisplayName(_ calendarId: String) -> String? {
        onQueue { store.calendar(withIdentifier: calendarId).map(Self.displayName) }
    }

    public func events(calendarId: String, from: Date, to: Date) throws -> [CalendarEventRecord] {
        try ensureAccess()
        return try onQueue {
            guard let calendar = store.calendar(withIdentifier: calendarId) else {
                throw SyncError.calendarNotFound(calendarId)
            }
            return try fetch(from: from, to: to, calendars: [calendar]).map { event in
                CalendarEventRecord(
                    id: Self.eventId(event),
                    calendarId: calendarId,
                    title: event.title ?? "",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    location: event.location,
                    notes: event.notes,
                    availability: Self.availability(event.availability),
                    status: Self.status(event.status),
                    myParticipation: Self.myParticipation(event)
                )
            }
        }
    }

    public func createEvent(_ draft: EventDraft, calendarId: String) throws {
        try onQueue {
            guard let calendar = store.calendar(withIdentifier: calendarId) else {
                throw SyncError.calendarNotFound(calendarId)
            }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = draft.title
            event.isAllDay = draft.isAllDay
            event.startDate = draft.start
            event.endDate = draft.end
            event.location = draft.location
            event.notes = draft.notes
            if !calendar.supportedEventAvailabilities.isEmpty {
                event.availability = Self.ekAvailability(draft.availability)
            }
            if let minutes = draft.alertMinutesBefore {
                event.alarms = minutes.map { EKAlarm(relativeOffset: TimeInterval(-$0 * 60)) }
            }
            try store.save(event, span: .thisEvent, commit: false)
        }
    }

    public func updateEvent(id: String, title: String, location: String?) throws {
        try onQueue {
            let event = try findEvent(id: id)
            event.title = title
            event.location = location
            try store.save(event, span: .thisEvent, commit: false)
        }
    }

    public func deleteEvent(id: String) throws {
        try onQueue {
            let event = try findEvent(id: id)
            try store.remove(event, span: .thisEvent, commit: false)
        }
    }

    public func commit() throws {
        try onQueue {
            do {
                try store.commit()
            } catch {
                store.reset()
                throw error
            }
        }
    }

    // MARK: - Helpers (call on queue)

    private func fetch(from: Date, to: Date, calendars: [EKCalendar]?) throws -> [EKEvent] {
        guard to > from else { throw CalendarStoreError("`to` must be after `from`.") }
        guard to.timeIntervalSince(from) <= 4 * 365 * 86400 else {
            throw CalendarStoreError("Date range is limited to 4 years.")
        }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate).sorted { $0.compareStartDate(with: $1) == .orderedAscending }
    }

    /// Event ids are `eventIdentifier`, plus `|<occurrence epoch>` for recurring events because every
    /// occurrence of a series shares the same eventIdentifier.
    static func eventId(_ event: EKEvent) -> String {
        let identifier: String = event.eventIdentifier ?? ""
        guard event.hasRecurrenceRules || event.isDetached else { return identifier }
        let occurrence: Date = event.occurrenceDate ?? event.startDate
        return "\(identifier)|\(Int(occurrence.timeIntervalSince1970))"
    }

    private func findEvent(id: String) throws -> EKEvent {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        if let separator = trimmed.lastIndex(of: "|"),
           let epoch = Int(trimmed[trimmed.index(after: separator)...]) {
            let identifier = String(trimmed[..<separator])
            let occurrence = Date(timeIntervalSince1970: TimeInterval(epoch))
            let predicate = store.predicateForEvents(
                withStart: occurrence.addingTimeInterval(-8 * 86400),
                end: occurrence.addingTimeInterval(8 * 86400),
                calendars: nil
            )
            let match = store.events(matching: predicate).first { event in
                guard event.eventIdentifier == identifier else { return false }
                let date: Date = event.occurrenceDate ?? event.startDate
                return abs(date.timeIntervalSince(occurrence)) < 1
            }
            if let match { return match }
            throw CalendarStoreError("Event occurrence not found: \(id)")
        }
        if let event = store.event(withIdentifier: trimmed) { return event }
        throw CalendarStoreError("Event not found: \(id)")
    }

    static func displayName(_ calendar: EKCalendar) -> String {
        let account = calendar.source?.title ?? ""
        return account.isEmpty ? calendar.title : "\(calendar.title) (\(account))"
    }

    static func info(for calendar: EKCalendar, defaultId: String?) -> CalendarInfo {
        CalendarInfo(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            account: calendar.source?.title ?? "",
            accountType: sourceType(calendar.source?.sourceType),
            color: hex(calendar.color),
            writable: calendar.allowsContentModifications,
            isDefault: calendar.calendarIdentifier == defaultId,
            supportsAvailability: !calendar.supportedEventAvailabilities.isEmpty
        )
    }

    static func info(for event: EKEvent, includeNotes: Bool, includeDetails: Bool = false, now: Date) -> EventInfo {
        let start: Date = event.startDate
        let end: Date = event.endDate
        let attendees = event.attendees ?? []
        let notes = event.notes
        let urlString = event.url?.absoluteString
        let alarms = (event.alarms ?? []).compactMap { alarm -> Int? in
            alarm.absoluteDate == nil ? Int((-alarm.relativeOffset / 60).rounded()) : nil
        }
        let minutesUntil = start > now ? Int((start.timeIntervalSince(now) / 60).rounded(.down)) : nil

        return EventInfo(
            id: eventId(event),
            title: event.title ?? "",
            start: DateInput.format(start),
            end: DateInput.format(end),
            allDay: event.isAllDay,
            calendar: event.calendar?.title ?? "",
            calendarId: event.calendar?.calendarIdentifier ?? "",
            account: event.calendar?.source?.title,
            location: event.location?.isEmpty == false ? event.location : nil,
            url: urlString,
            joinUrl: JoinLinkResolver.resolve(url: urlString, location: event.location, notes: notes),
            availability: availability(event.availability).rawValue,
            status: status(event.status).rawValue,
            myStatus: myParticipation(event)?.rawValue,
            recurring: event.hasRecurrenceRules,
            recurrence: includeDetails ? event.recurrenceRules?.first.map(recurrenceInfo) : nil,
            organizer: includeDetails ? event.organizer.map(participant) : nil,
            attendees: includeDetails && !attendees.isEmpty ? attendees.map(participant) : nil,
            alertsMinutesBefore: includeDetails && !alarms.isEmpty ? alarms : nil,
            synced: SyncMarkers.isSynced(notes: notes) ? true : nil,
            minutesUntilStart: minutesUntil,
            notes: includeNotes && notes?.isEmpty == false ? notes : nil
        )
    }

    static func myParticipation(_ event: EKEvent) -> ParticipationStatus? {
        if let me = event.attendees?.first(where: { $0.isCurrentUser }) {
            return participationStatus(me.participantStatus)
        }
        if event.organizer?.isCurrentUser == true { return .accepted }
        return nil
    }

    static func participant(_ participant: EKParticipant) -> ParticipantInfo {
        let url = participant.url.absoluteString
        let email = url.lowercased().hasPrefix("mailto:") ? String(url.dropFirst("mailto:".count)) : nil
        let role: String
        switch participant.participantRole {
        case .required: role = "required"
        case .optional: role = "optional"
        case .chair: role = "chair"
        case .nonParticipant: role = "nonParticipant"
        default: role = "unknown"
        }
        let type: String
        switch participant.participantType {
        case .person: type = "person"
        case .room: type = "room"
        case .resource: type = "resource"
        case .group: type = "group"
        default: type = "unknown"
        }
        return ParticipantInfo(
            name: participant.name,
            email: email,
            status: participationStatus(participant.participantStatus).rawValue,
            role: role,
            type: type,
            isCurrentUser: participant.isCurrentUser ? true : nil
        )
    }

    static func participationStatus(_ status: EKParticipantStatus) -> ParticipationStatus {
        switch status {
        case .pending: return .pending
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        case .delegated: return .delegated
        case .completed: return .completed
        case .inProcess: return .inProcess
        default: return .unknown
        }
    }

    static func availability(_ availability: EKEventAvailability) -> EventAvailability {
        switch availability {
        case .busy: return .busy
        case .free: return .free
        case .tentative: return .tentative
        case .unavailable: return .unavailable
        default: return .notSupported
        }
    }

    static func ekAvailability(_ availability: EventAvailability) -> EKEventAvailability {
        switch availability {
        case .busy: return .busy
        case .free: return .free
        case .tentative: return .tentative
        case .unavailable: return .unavailable
        case .notSupported: return .notSupported
        }
    }

    static func status(_ status: EKEventStatus) -> EventStatus {
        switch status {
        case .confirmed: return .confirmed
        case .tentative: return .tentative
        case .canceled: return .canceled
        default: return .none
        }
    }

    static func sourceType(_ type: EKSourceType?) -> String {
        switch type {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "caldav"
        case .mobileMe: return "icloud"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        default: return "unknown"
        }
    }

    static func hex(_ color: NSColor?) -> String? {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }

    private static let weekdays: [(String, EKWeekday)] = [
        ("mon", .monday), ("tue", .tuesday), ("wed", .wednesday), ("thu", .thursday),
        ("fri", .friday), ("sat", .saturday), ("sun", .sunday),
    ]

    static func recurrenceRule(_ input: RecurrenceInput) throws -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch input.frequency.lowercased() {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default: throw CalendarStoreError("recurrence.frequency must be daily, weekly, monthly or yearly.")
        }
        let days = try input.daysOfWeek?.map { name -> EKRecurrenceDayOfWeek in
            let key = String(name.lowercased().prefix(3))
            guard let day = weekdays.first(where: { $0.0 == key })?.1 else {
                throw CalendarStoreError("Unknown weekday '\(name)'. Use mon, tue, wed, thu, fri, sat, sun.")
            }
            return EKRecurrenceDayOfWeek(day)
        }
        let end: EKRecurrenceEnd?
        if let until = input.until {
            end = EKRecurrenceEnd(end: until)
        } else if let count = input.count {
            end = EKRecurrenceEnd(occurrenceCount: count)
        } else {
            end = nil
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: max(1, input.interval),
            daysOfTheWeek: days?.isEmpty == false ? days : nil,
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: end
        )
    }

    static func recurrenceInfo(_ rule: EKRecurrenceRule) -> RecurrenceInfo {
        let frequency: String
        switch rule.frequency {
        case .daily: frequency = "daily"
        case .weekly: frequency = "weekly"
        case .monthly: frequency = "monthly"
        case .yearly: frequency = "yearly"
        @unknown default: frequency = "unknown"
        }
        let days = rule.daysOfTheWeek?.compactMap { day in weekdays.first { $0.1 == day.dayOfTheWeek }?.0 }
        return RecurrenceInfo(
            frequency: frequency,
            interval: rule.interval,
            daysOfWeek: days?.isEmpty == false ? days : nil,
            until: rule.recurrenceEnd?.endDate.map(DateInput.format),
            count: rule.recurrenceEnd.flatMap { $0.occurrenceCount > 0 ? $0.occurrenceCount : nil }
        )
    }
}
