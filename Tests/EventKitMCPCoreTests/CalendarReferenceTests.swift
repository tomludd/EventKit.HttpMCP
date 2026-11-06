import Foundation
import Testing
@testable import EventKitMCPCore

struct CalendarReferenceTests {
    let work = CalendarReference(id: "work-old", title: "Calendar", account: "me@work.com")
    let home = CalendarReference(id: "home-old", title: "Kalender", account: "me@live.no")

    func rule(_ source: CalendarReference, _ target: CalendarReference, mode: SyncMode = .block) -> SyncRule {
        SyncRule(source: source, target: target, mode: mode)
    }

    @Test func decodesLegacyIdsAndDisplayNames() throws {
        let json = #"""
        {
          "syncRules": [{
            "sourceCalendarId": "A", "sourceCalendarName": "Calendar (me@work.com)",
            "targetCalendarId": "B", "targetCalendarName": "Team (Oslo) (me@live.no)"
          }],
          "mcpCalendarIds": ["A", "B"],
          "countdownCalendarIds": ["A", "C"]
        }
        """#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        let rule = try #require(config.syncRules.first)
        #expect(rule.source == CalendarReference(id: "A", title: "Calendar", account: "me@work.com"))
        #expect(rule.target == CalendarReference(id: "B", title: "Team (Oslo)", account: "me@live.no"))
        #expect(rule.markerKey == nil)
        #expect(rule.marker == CalendarSyncEngine.marker(mode: .block, sourceCalendarId: "A", targetCalendarId: "B"))
        // Bare ids borrow names from the sync rules; unknown ones stay unnamed.
        #expect(config.mcpCalendars == [rule.source, rule.target])
        #expect(config.countdownCalendars == [rule.source, CalendarReference(id: "C")])

        let reencoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(reencoded == config)
    }

    @Test func splitsDisplayNamesWithoutAccount() {
        #expect(CalendarReference(id: "x", displayName: "Holidays") == CalendarReference(id: "x", title: "Holidays"))
        #expect(CalendarReference(id: "x", displayName: "") == CalendarReference(id: "x"))
    }

    @Test func relinksCalendarsWithNewIdsByTitleAndAccount() {
        var config = AppConfig()
        config.syncRules = [rule(work, home), rule(home, work, mode: .copy)]
        config.mcpCalendars = [work, home]
        config.countdownCalendars = [work, CalendarReference(id: "unnamed")]
        let oldMarkers = config.syncRules.map(\.marker)

        let current = [
            CalendarReference(id: "work-new", title: "Calendar", account: "me@work.com"),
            CalendarReference(id: "home-new", title: "kalender", account: "ME@live.no"),
        ]
        let changes = config.reconcileCalendars(with: current)

        #expect(Set(changes.map(\.newId)) == ["work-new", "home-new"])
        #expect(changes.count == 2)
        #expect(config.syncRules[0].sourceCalendarId == "work-new")
        #expect(config.syncRules[0].targetCalendarId == "home-new")
        #expect(config.syncRules[1].sourceCalendarId == "home-new")
        // The rule keeps the marker its existing events carry.
        #expect(config.syncRules.map(\.marker) == oldMarkers)
        #expect(config.mcpCalendarScope == ["work-new", "home-new"])
        // A reference without a name cannot be found again and is left alone.
        #expect(config.countdownCalendarIds == ["work-new", "unnamed"])

        // Running again changes nothing.
        let before = config
        #expect(config.reconcileCalendars(with: current).isEmpty)
        #expect(config == before)
    }

    @Test func refreshesNamesOfRenamedCalendarsWithoutTouchingTheMarker() {
        var config = AppConfig()
        config.syncRules = [rule(work, home)]
        let marker = config.syncRules[0].marker

        let changes = config.reconcileCalendars(with: [
            CalendarReference(id: "work-old", title: "Work", account: "me@work.com"),
            home,
        ])

        #expect(changes.isEmpty)
        #expect(config.syncRules[0].source.title == "Work")
        #expect(config.syncRules[0].markerKey == nil)
        #expect(config.syncRules[0].marker == marker)
    }

    @Test func leavesReferencesAloneWhenNameIsAmbiguousOrNothingIsLoaded() {
        var config = AppConfig()
        config.syncRules = [rule(work, home)]
        config.mcpCalendars = [work]
        let original = config

        #expect(config.reconcileCalendars(with: []).isEmpty)
        #expect(config == original)

        let changes = config.reconcileCalendars(with: [
            CalendarReference(id: "a", title: "Calendar", account: "me@work.com"),
            CalendarReference(id: "b", title: "Calendar", account: "me@work.com"),
        ])
        #expect(changes.isEmpty)
        #expect(config == original)
    }

    @Test func mergesSelectionsThatEndUpOnTheSameCalendar() {
        var config = AppConfig()
        let current = CalendarReference(id: "work-new", title: "Calendar", account: "me@work.com")
        config.mcpCalendars = [current, work]
        config.reconcileCalendars(with: [current])
        #expect(config.mcpCalendars == [current])
    }

    /// Removing and re-adding an account gives every calendar a new id, while the events (and the
    /// sync markers in their notes) come back from the server unchanged.
    @Test func syncKeepsItsEventsAfterAccountsAreAddedAgain() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("eventkit-mcp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let from = Date(timeIntervalSince1970: 1_790_000_000)
        let to = from.addingTimeInterval(14 * 86400)

        let backend = InMemoryBackend(["work-old": ("Calendar (me@work.com)", true), "home-old": ("Kalender (me@live.no)", true)])
        backend.add("work-old", "Standup", from.addingTimeInterval(86400))
        backend.add("work-old", "Review", from.addingTimeInterval(2 * 86400))
        let store = ConfigStore(fileURL: fileURL)
        store.update { $0.syncRules = [rule(work, home, mode: .copy)] }
        let coordinator = SyncCoordinator(backend: backend, configStore: store)
        #expect(coordinator.run(from: from, to: to).first?.summary?.created == 2)

        // Accounts removed and added again.
        backend.calendars = ["work-new": ("Calendar (me@work.com)", true), "home-new": ("Kalender (me@live.no)", true)]
        for index in backend.events.indices {
            backend.events[index].calendarId = backend.events[index].calendarId.replacingOccurrences(of: "-old", with: "-new")
        }

        let result = try #require(coordinator.run(from: from, to: to).first)
        #expect(result.status == "ok")
        #expect(result.summary?.created == 0)
        #expect(result.summary?.skipped == 2)
        #expect(backend.inCalendar("home-new").count == 2)
        #expect(store.config.syncRules[0].sourceCalendarId == "work-new")
        #expect(coordinator.recentLog().filter { $0.status == "RELINK" }.count == 2)

        // Saved to disk with names and the original marker.
        let saved = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: fileURL))
        #expect(saved.syncRules[0].target == CalendarReference(id: "home-new", title: "Kalender", account: "me@live.no"))
        #expect(saved.syncRules[0].marker == CalendarSyncEngine.marker(mode: .copy, sourceCalendarId: "work-old", targetCalendarId: "home-old"))
    }
}
