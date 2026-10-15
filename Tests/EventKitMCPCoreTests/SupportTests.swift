import Foundation
import Testing
@testable import EventKitMCPCore

struct DateInputTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return calendar
    }()
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 13, minute: 20))! }

    func local(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func parsesKeywordsAndDateOnly() {
        #expect(DateInput.parse("now", now: now, calendar: calendar) == now)
        #expect(DateInput.parse("today", now: now, calendar: calendar) == local(15))
        #expect(DateInput.parse("tomorrow", now: now, calendar: calendar) == local(16))
        #expect(DateInput.parse("2026-10-20", now: now, calendar: calendar) == local(20))
        #expect(DateInput.parse("2026-10-20", now: now, endOfDayIfDateOnly: true, calendar: calendar) == local(21))
        #expect(DateInput.parse("today", now: now, endOfDayIfDateOnly: true, calendar: calendar) == local(16))
    }

    @Test func parsesLocalAndOffsetTimes() {
        #expect(DateInput.parse("2026-10-20 14:30", now: now, calendar: calendar) == local(20, 14, 30))
        #expect(DateInput.parse("2026-10-20T14:30", now: now, calendar: calendar) == local(20, 14, 30))
        #expect(DateInput.parse("2026-10-20T14:30:00+02:00", now: now, calendar: calendar) == local(20, 14, 30))
        #expect(DateInput.parse("2026-10-20T12:30:00Z", now: now, calendar: calendar) == local(20, 14, 30))
        #expect(DateInput.parse("2026-10-20T12:30:00.000Z", now: now, calendar: calendar) == local(20, 14, 30))
        #expect(DateInput.parse("next blursday", now: now, calendar: calendar) == nil)
    }
}

struct JoinLinkResolverTests {
    @Test func findsTeamsZoomAndMeetLinks() {
        let teams = "Join: <https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d>"
        #expect(JoinLinkResolver.resolve(url: nil, location: nil, notes: teams)
            == "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d")
        #expect(JoinLinkResolver.resolve(url: nil, location: "https://acme.zoom.us/j/123456789?pwd=abc", notes: nil)
            == "https://acme.zoom.us/j/123456789?pwd=abc")
        #expect(JoinLinkResolver.resolve(url: "https://meet.google.com/abc-defg-hij", location: nil, notes: nil)
            == "https://meet.google.com/abc-defg-hij")
        #expect(JoinLinkResolver.resolve(url: "https://example.com", location: "Room 1", notes: "No link") == nil)
    }

    @Test func unwrapsSafeLinks() {
        let notes = "https://eur02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_x%2F0&data=1"
        #expect(JoinLinkResolver.resolve(url: nil, location: nil, notes: notes)?.hasPrefix("https://teams.microsoft.com/l/meetup-join/") == true)
    }
}

struct MeetingCountdownTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func meeting(_ minutesFromNow: Double, _ title: String = "Standup", allDay: Bool = false, declined: Bool = false, synced: Bool = false) -> MeetingSnapshot {
        let start = now.addingTimeInterval(minutesFromNow * 60)
        return MeetingSnapshot(id: title, eventIdentifier: title, title: title, start: start, end: start.addingTimeInterval(1800),
                               isAllDay: allDay, isDeclined: declined, isSyncedBlock: synced)
    }

    func display(_ meetings: [MeetingSnapshot], alwaysShow: Bool = false, showTitle: Bool = false) -> CountdownDisplay {
        MeetingCountdown.display(meetings: meetings, now: now, warningMinutes: 10, criticalMinutes: 4, alwaysShow: alwaysShow, showTitle: showTitle)
    }

    @Test func hiddenUntilTenMinutesBefore() {
        #expect(display([meeting(25)]).level == .hidden)
        #expect(display([meeting(10)]).level == .hidden)
        let soon = display([meeting(9.5)])
        #expect(soon.level == .warning)
        #expect(soon.text == "9:30")
    }

    @Test func redUnderFourMinutes() {
        #expect(display([meeting(4)]).level == .warning)
        var soon = meeting(0)
        soon.start = now.addingTimeInterval(239)
        let critical = display([soon])
        #expect(critical.level == .critical)
        #expect(critical.text == "3:59")
    }

    @Test func alwaysShowUsesCoarseFormat() {
        let later = display([meeting(95)], alwaysShow: true)
        #expect(later.level == .normal)
        #expect(later.text == "1h 35m")
        #expect(display([meeting(42)], alwaysShow: true).text == "42m")
    }

    @Test func ignoresStartedAllDayDeclinedAndSyncedEvents() {
        let meetings = [
            meeting(-5, "Ongoing"), meeting(2, "Holiday", allDay: true), meeting(3, "Declined", declined: true),
            meeting(4, "Blocked", synced: true), meeting(8, "Real"),
        ]
        let result = display(meetings, showTitle: true)
        #expect(result.meeting?.title == "Real")
        #expect(result.text == "Real · 8:00")
    }
}

struct FreeSlotFinderTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return calendar
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func findsGapsInsideWorkingHours() {
        // Thursday 2026-10-15
        let busy = [
            BusyInterval(start: at(15, 9), end: at(15, 10)),
            BusyInterval(start: at(15, 9, 30), end: at(15, 11)),
            BusyInterval(start: at(15, 11, 15), end: at(15, 16, 30)),
        ]
        let slots = FreeSlotFinder.find(busy: busy, from: at(15, 0), to: at(16, 0), durationMinutes: 30, workStartHour: 9,
                                        workEndHour: 17, includeWeekends: false, now: at(1, 0), calendar: calendar)
        #expect(slots.map(\.minutes) == [30])
    }

    @Test func skipsWeekendsAndPastTime() {
        // Saturday 17th and Sunday 18th are skipped; Monday 19th is fully free.
        let slots = FreeSlotFinder.find(busy: [], from: at(17, 0), to: at(20, 0), durationMinutes: 60, workStartHour: 9,
                                        workEndHour: 17, includeWeekends: false, now: at(1, 0), calendar: calendar)
        #expect(slots.count == 1)
        #expect(slots[0].minutes == 480)

        let today = FreeSlotFinder.find(busy: [], from: at(15, 0), to: at(16, 0), durationMinutes: 30, workStartHour: 9,
                                        workEndHour: 17, includeWeekends: false, now: at(15, 13, 2), calendar: calendar)
        #expect(today.first?.minutes == 235) // 13:05–17:00
    }
}

struct ConfigTests {
    @Test func decodesOldOrPartialConfigWithDefaults() throws {
        let json = #"{"port": 9000, "syncRules": [{"sourceCalendarId": "a", "targetCalendarId": "b"}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.port == 9000)
        #expect(config.countdownWarningMinutes == 10)
        #expect(config.countdownCriticalMinutes == 4)
        #expect(config.syncRules.first?.mode == .block)
        #expect(config.syncRules.first?.blockEventName == "Busy")
        #expect(config.syncRules.first?.enabled == true)
    }

    @Test func scheduleRunsAtTheOutlookMinutes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        let at = { (h: Int, m: Int) in calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: h, minute: m))! }
        #expect(SyncCoordinator.nextRun(after: at(10, 0), calendar: calendar) == at(10, 12))
        #expect(SyncCoordinator.nextRun(after: at(10, 12), calendar: calendar) == at(10, 27))
        #expect(SyncCoordinator.nextRun(after: at(10, 58), calendar: calendar) == at(11, 12))
    }
}
