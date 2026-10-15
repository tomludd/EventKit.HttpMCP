import Foundation
import Testing
@testable import EventKitMCPCore

/// In-memory calendar used to exercise the sync engine without EventKit.
final class InMemoryBackend: CalendarBackend {
    var calendars: [String: (name: String, writable: Bool)] = [:]
    var events: [CalendarEventRecord] = []
    private var nextId = 1

    init(_ calendars: [String: (String, Bool)]) {
        for (id, value) in calendars { self.calendars[id] = (value.0, value.1) }
    }

    @discardableResult
    func add(_ calendarId: String, _ title: String, _ start: Date, minutes: Int = 30, availability: EventAvailability = .busy,
             notes: String? = nil, isAllDay: Bool = false, participation: ParticipationStatus? = nil) -> CalendarEventRecord {
        let event = CalendarEventRecord(
            id: "e\(nextId)", calendarId: calendarId, title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
            isAllDay: isAllDay, notes: notes, availability: availability, myParticipation: participation
        )
        nextId += 1
        events.append(event)
        return event
    }

    func inCalendar(_ id: String) -> [CalendarEventRecord] { events.filter { $0.calendarId == id }.sorted { $0.start < $1.start } }

    func calendarExists(_ calendarId: String) -> Bool { calendars[calendarId] != nil }
    func calendarIsWritable(_ calendarId: String) -> Bool { calendars[calendarId]?.writable ?? false }
    func calendarDisplayName(_ calendarId: String) -> String? { calendars[calendarId]?.name }

    func events(calendarId: String, from: Date, to: Date) throws -> [CalendarEventRecord] {
        events.filter { $0.calendarId == calendarId && $0.end > from && $0.start < to }
    }

    func createEvent(_ draft: EventDraft, calendarId: String) throws {
        events.append(CalendarEventRecord(
            id: "e\(nextId)", calendarId: calendarId, title: draft.title, start: draft.start, end: draft.end,
            isAllDay: draft.isAllDay, location: draft.location, notes: draft.notes, availability: draft.availability
        ))
        nextId += 1
    }

    func updateEvent(id: String, title: String, location: String?) throws {
        guard let index = events.firstIndex(where: { $0.id == id }) else { throw SyncError.calendarNotFound(id) }
        events[index].title = title
        events[index].location = location
    }

    func deleteEvent(id: String) throws {
        events.removeAll { $0.id == id }
    }

    func commit() throws {}
}

struct CalendarSyncEngineTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return calendar
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func makeBackend() -> InMemoryBackend {
        InMemoryBackend(["work": ("Work (Exchange)", true), "home": ("Home (iCloud)", true), "subscribed": ("Holidays", false)])
    }

    func run(_ backend: InMemoryBackend, _ options: SyncOptions = SyncOptions(), source: String = "work", target: String = "home") throws -> SyncSummary {
        try CalendarSyncEngine(backend: backend, calendar: calendar)
            .run(sourceCalendarId: source, targetCalendarId: target, from: at(15, 0), to: at(30, 0), options: options)
    }

    @Test func createsAnonymousBlocksForBusyEvents() throws {
        let backend = makeBackend()
        backend.add("work", "Secret project", at(16, 9))
        backend.add("work", "Lunch (free)", at(16, 11), availability: .free)
        backend.add("work", "Maybe", at(16, 12), availability: .tentative)

        let summary = try run(backend)

        #expect(summary.created == 1)
        let blocks = backend.inCalendar("home")
        #expect(blocks.count == 1)
        #expect(blocks[0].title == "Busy")
        #expect(blocks[0].start == at(16, 9))
        #expect(blocks[0].availability == .busy)
        #expect(blocks[0].notes?.contains("Blocked from Work (Exchange)") == true)
        #expect(blocks[0].notes?.contains(CalendarSyncEngine.marker(mode: .block, sourceCalendarId: "work", targetCalendarId: "home")) == true)
    }

    @Test func secondRunIsIdempotent() throws {
        let backend = makeBackend()
        backend.add("work", "Standup", at(16, 9))
        _ = try run(backend)
        let summary = try run(backend)
        #expect(summary.created == 0)
        #expect(summary.skipped == 1)
        #expect(backend.inCalendar("home").count == 1)
    }

    @Test func deletesBlocksWhoseSourceIsGone() throws {
        let backend = makeBackend()
        let meeting = backend.add("work", "Standup", at(16, 9))
        _ = try run(backend)
        try backend.deleteEvent(id: meeting.id)

        let summary = try run(backend)
        #expect(summary.deleted == 1)
        #expect(backend.inCalendar("home").isEmpty)
    }

    @Test func movedSourceEventMovesTheBlock() throws {
        let backend = makeBackend()
        let meeting = backend.add("work", "Standup", at(16, 9))
        _ = try run(backend)
        let index = backend.events.firstIndex { $0.id == meeting.id }!
        backend.events[index].start = at(16, 10)
        backend.events[index].end = at(16, 10, 30)

        let summary = try run(backend)
        #expect(summary.deleted == 1)
        #expect(summary.created == 1)
        #expect(backend.inCalendar("home").map(\.start) == [at(16, 10)])
    }

    @Test func outOfOfficeKeepsItsTitleAndStatus() throws {
        let backend = makeBackend()
        backend.add("work", "Vacation", at(17, 8), minutes: 600, availability: .unavailable)
        _ = try run(backend)
        let block = try #require(backend.inCalendar("home").first)
        #expect(block.title == "Out of Office")
        #expect(block.availability == .unavailable)
    }

    @Test func refreshesStaleBlockTitleAndLocation() throws {
        let backend = makeBackend()
        backend.add("work", "Standup", at(16, 9))
        _ = try run(backend)

        let summary = try run(backend, SyncOptions(blockEventName: "Opptatt", blockEventLocation: "Kontoret"))
        #expect(summary.updated == 1)
        let block = try #require(backend.inCalendar("home").first)
        #expect(block.title == "Opptatt")
        #expect(block.location == "Kontoret")
    }

    @Test func skipsSlotsWhereTargetAlreadyHasARealEvent() throws {
        let backend = makeBackend()
        backend.add("work", "All hands", at(16, 13))
        backend.add("home", "All hands", at(16, 13))
        let summary = try run(backend)
        #expect(summary.created == 0)
        #expect(backend.inCalendar("home").count == 1)
    }

    @Test func neverResyncsSyncedEventsSoTwoWayRulesDoNotCascade() throws {
        let backend = makeBackend()
        backend.add("work", "Standup", at(16, 9))
        backend.add("home", "Dentist", at(16, 15))
        backend.add("work", "From outlook-cli", at(16, 17), notes: "Blocked\n[outlook-sync:block:abcd1234]")

        for _ in 0..<3 {
            _ = try run(backend, source: "work", target: "home")
            _ = try run(backend, source: "home", target: "work")
        }

        #expect(backend.inCalendar("home").count == 2) // Dentist + block for Standup
        #expect(backend.inCalendar("work").count == 3) // Standup + outlook block + block for Dentist
    }

    @Test func skipsDeclinedAndCanceledEvents() throws {
        let backend = makeBackend()
        backend.add("work", "Declined", at(16, 9), participation: .declined)
        var canceled = backend.add("work", "Canceled", at(16, 10))
        canceled.status = .canceled
        backend.events[backend.events.firstIndex { $0.id == canceled.id }!] = canceled

        let summary = try run(backend)
        #expect(summary.created == 0)
    }

    @Test func notSupportedAvailabilityCountsTimedEventsAsBusy() throws {
        let backend = makeBackend()
        backend.add("work", "Timed", at(16, 9), availability: .notSupported)
        backend.add("work", "Birthday", at(16, 0), minutes: 1440, availability: .notSupported, isAllDay: true)
        _ = try run(backend)
        #expect(backend.inCalendar("home").map(\.start) == [at(16, 9)])
    }

    @Test func outsideWorkHoursOnly() throws {
        let backend = makeBackend()
        backend.add("work", "Day meeting", at(16, 10))
        backend.add("work", "Early call", at(16, 6, 30))
        backend.add("work", "Evening", at(16, 17, 45))
        _ = try run(backend, SyncOptions(outsideWorkHoursOnly: true, workDayStartHour: 7, workDayEndHour: 18))
        #expect(backend.inCalendar("home").map(\.start) == [at(16, 6, 30), at(16, 17, 45)])
    }

    @Test func copyModeCopiesTitleAndNotesAsFree() throws {
        let backend = makeBackend()
        backend.add("work", "Planning", at(16, 9), notes: "Agenda")
        backend.add("work", "Review", at(16, 9))
        _ = try run(backend, SyncOptions(mode: .copy))

        let copies = backend.inCalendar("home")
        #expect(Set(copies.map(\.title)) == ["Planning", "Review"])
        #expect(copies.allSatisfy { $0.availability == .free })
        #expect(copies.first { $0.title == "Planning" }?.notes?.hasPrefix("Agenda\n[eventkit-sync:copy:") == true)

        let second = try run(backend, SyncOptions(mode: .copy))
        #expect(second.created == 0)
        #expect(second.skipped == 2)
    }

    @Test func removesDuplicateBlocksForTheSameSlot() throws {
        let backend = makeBackend()
        backend.add("work", "Standup", at(16, 9))
        _ = try run(backend)
        let block = backend.inCalendar("home")[0]
        backend.add("home", "Busy", at(16, 9), notes: block.notes)

        let summary = try run(backend)
        #expect(summary.deleted == 1)
        #expect(backend.inCalendar("home").count == 1)
    }

    @Test func rejectsReadOnlyOrSameCalendar() throws {
        let backend = makeBackend()
        #expect(throws: SyncError.self) { try run(backend, target: "subscribed") }
        #expect(throws: SyncError.self) { try run(backend, target: "work") }
        #expect(throws: SyncError.self) { try run(backend, target: "missing") }
    }

    @Test func purgeRemovesOnlySyncedEvents() throws {
        let backend = makeBackend()
        backend.add("work", "Standup", at(16, 9))
        backend.add("home", "Dentist", at(16, 15))
        _ = try run(backend)
        let engine = CalendarSyncEngine(backend: backend, calendar: calendar)

        #expect(try engine.purge(calendarId: "home", from: at(15, 0), to: at(30, 0), dryRun: true) == 1)
        #expect(try engine.purge(calendarId: "home", from: at(15, 0), to: at(30, 0)) == 1)
        #expect(backend.inCalendar("home").map(\.title) == ["Dentist"])
    }

    @Test func markerIsStablePerRule() {
        let a = CalendarSyncEngine.marker(mode: .block, sourceCalendarId: "work", targetCalendarId: "home")
        let b = CalendarSyncEngine.marker(mode: .block, sourceCalendarId: "work", targetCalendarId: "home")
        let reverse = CalendarSyncEngine.marker(mode: .block, sourceCalendarId: "home", targetCalendarId: "work")
        #expect(a == b)
        #expect(a != reverse)
        #expect(a.range(of: #"^\[eventkit-sync:block:[0-9a-f]{8}\]$"#, options: .regularExpression) != nil)
    }
}
