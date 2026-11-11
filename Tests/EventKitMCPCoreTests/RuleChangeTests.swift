import Foundation
import Testing
@testable import EventKitMCPCore

/// Changing a rule or the sync range removes the events that no longer belong.
struct RuleChangeTests {
    let today = Calendar.current.startOfDay(for: Date())

    func day(_ offset: Int, hour: Int = 10) -> Date {
        Calendar.current.date(byAdding: .hour, value: offset * 24 + hour, to: today)!
    }

    func makeBackend() -> InMemoryBackend {
        InMemoryBackend(["work": ("Work (Exchange)", true), "home": ("Home (iCloud)", true), "other": ("Other (iCloud)", true)])
    }

    func makeStore(_ rules: [SyncRule], daysAhead: Int = 90) -> (ConfigStore, URL) {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("eventkit-mcp-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        store.update {
            $0.syncRules = rules
            $0.syncDaysAhead = daysAhead
        }
        return (store, fileURL)
    }

    func rule(target: String = "home", mode: SyncMode = .block) -> SyncRule {
        SyncRule(source: CalendarReference(id: "work"), target: CalendarReference(id: target), mode: mode)
    }

    @Test func changedHoursRemoveBlocksThatNoLongerMatch() throws {
        let backend = makeBackend()
        backend.add("work", "Morning", day(1, hour: 9))
        backend.add("work", "Afternoon", day(1, hour: 14))
        let engine = CalendarSyncEngine(backend: backend)
        func run(_ options: SyncOptions) throws -> SyncSummary {
            try engine.run(sourceCalendarId: "work", targetCalendarId: "home", from: today, to: day(30), options: options)
        }
        _ = try run(SyncOptions(hoursFilter: .within, workDayStartHour: 8, workDayEndHour: 16))
        #expect(backend.inCalendar("home").count == 2)

        let summary = try run(SyncOptions(hoursFilter: .within, workDayStartHour: 12, workDayEndHour: 16))
        #expect(summary.deleted == 1)
        #expect(backend.inCalendar("home").map(\.start) == [day(1, hour: 14)])
    }

    @Test func shorterRangeRemovesBlocksBeyondIt() throws {
        let backend = makeBackend()
        backend.add("work", "Soon", day(5))
        backend.add("work", "Later", day(60))
        let (store, fileURL) = makeStore([rule()], daysAhead: 90)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let coordinator = SyncCoordinator(backend: backend, configStore: store)
        _ = coordinator.run()
        #expect(backend.inCalendar("home").count == 2)

        // A run over a custom range leaves events outside it alone.
        _ = coordinator.run(from: today, to: day(30))
        #expect(backend.inCalendar("home").count == 2)

        store.update { $0.syncDaysAhead = 30 }
        #expect(coordinator.run().first?.summary?.deleted == 1)
        #expect(backend.inCalendar("home").map(\.start) == [day(5)])
    }

    @Test func changedTargetOrModeRemovesWhatThePreviousRuleCreated() throws {
        let backend = makeBackend()
        backend.add("work", "Meeting", day(2))
        let original = rule()
        let (store, fileURL) = makeStore([original])
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let coordinator = SyncCoordinator(backend: backend, configStore: store)
        _ = coordinator.run()
        #expect(backend.inCalendar("home").count == 1)

        var moved = original
        moved.target = CalendarReference(id: "other")
        store.update { $0.syncRules = [moved] }
        coordinator.applyRuleChangeNow(from: original, to: moved, run: true)
        #expect(backend.inCalendar("home").isEmpty)
        #expect(backend.inCalendar("other").map(\.title) == ["Busy"])

        var copying = moved
        copying.mode = .copy
        store.update { $0.syncRules = [copying] }
        coordinator.applyRuleChangeNow(from: moved, to: copying, run: true)
        #expect(backend.inCalendar("other").map(\.title) == ["Meeting"])
    }

    @Test func savingWithoutRunningStillRemovesTheOldTargetsEvents() throws {
        let backend = makeBackend()
        backend.add("work", "Meeting", day(2))
        let original = rule()
        let (store, fileURL) = makeStore([original])
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let coordinator = SyncCoordinator(backend: backend, configStore: store)
        _ = coordinator.run()

        var moved = original
        moved.target = CalendarReference(id: "other")
        coordinator.applyRuleChangeNow(from: original, to: moved, run: false)
        #expect(backend.inCalendar("home").isEmpty)
        #expect(backend.inCalendar("other").isEmpty)
    }
}
