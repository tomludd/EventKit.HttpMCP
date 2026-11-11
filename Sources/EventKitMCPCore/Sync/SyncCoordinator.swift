import Foundation

public struct SyncLogEntry: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var timestamp: Date
    public var rule: String
    public var status: String
    public var message: String

    public var line: String {
        let time = DateFormatter.localizedString(from: timestamp, dateStyle: .none, timeStyle: .medium)
        let rulePart = rule.isEmpty ? "" : " [\(rule)]"
        return "\(time) \(status)\(rulePart) — \(message)"
    }
}

public struct SyncRuleResult: Codable, Sendable {
    public var ruleId: String?
    public var rule: String
    public var status: String
    public var summary: SyncSummary?
    public var error: String?
}

/// Runs sync rules on a schedule (minutes 12, 27, 42 and 57 of every hour, like outlook-cli's
/// reminder app) or on demand from the menu bar and MCP. Runs are serialized.
public final class SyncCoordinator: @unchecked Sendable {
    public static let didChangeNotification = Notification.Name("EventKitMCP.SyncDidChange")
    public static let scheduleMinutes = [12, 27, 42, 57]
    /// Longest range a rule syncs ahead; runs over the configured range clean up events up to this far.
    public static let maxDaysAhead = 365

    private let backend: CalendarBackend
    private let configStore: ConfigStore
    private let runQueue = DispatchQueue(label: "eventkit-mcp.sync")
    private let timerQueue = DispatchQueue(label: "eventkit-mcp.sync-timer")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var nextScheduledRun: Date?
    private var log: [SyncLogEntry] = []
    private var running = false
    private var lastRun: Date?
    private var lastError: String?

    public init(backend: CalendarBackend, configStore: ConfigStore) {
        self.backend = backend
        self.configStore = configStore
    }

    // MARK: - State

    public var isRunning: Bool { locked { running } }
    public var lastRunAt: Date? { locked { lastRun } }
    public var lastErrorMessage: String? { locked { lastError } }
    public var nextRunAt: Date? { locked { configStore.config.autoSyncEnabled ? nextScheduledRun : nil } }

    public func recentLog(limit: Int = 50) -> [SyncLogEntry] {
        locked { Array(log.suffix(limit)) }
    }

    // MARK: - Scheduling

    public func startScheduler() {
        locked { nextScheduledRun = Self.nextRun(after: Date()) }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        // Checking every 20 s (instead of sleeping until the next slot) also catches up after the Mac wakes.
        timer.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        locked { self.timer = timer }
    }

    public func stopScheduler() {
        locked {
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        let now = Date()
        let due: Bool = locked {
            guard let next = nextScheduledRun, now >= next else { return false }
            nextScheduledRun = Self.nextRun(after: now)
            return true
        }
        guard due, configStore.config.autoSyncEnabled else { return }
        runInBackground(trigger: "schedule")
    }

    public static func nextRun(after date: Date, calendar: Calendar = .current) -> Date {
        let hourStart = calendar.dateInterval(of: .hour, for: date)!.start
        for hourOffset in 0...1 {
            for minute in scheduleMinutes {
                let candidate = hourStart.addingTimeInterval(TimeInterval(hourOffset * 3600 + minute * 60))
                if candidate > date { return candidate }
            }
        }
        return hourStart.addingTimeInterval(3600 + TimeInterval(scheduleMinutes[0] * 60))
    }

    // MARK: - Running

    /// Starts a run of all enabled rules unless one is already in progress. Returns false when skipped.
    @discardableResult
    public func runInBackground(trigger: String) -> Bool {
        let started: Bool = locked {
            if running { return false }
            running = true
            return true
        }
        guard started else { return false }
        notify()
        runQueue.async { [self] in
            reconcileCalendars()
            _ = performRun(rules: configStore.config.syncRules.filter(\.enabled), trigger: trigger, cleanUpBeyondRange: true)
        }
        return true
    }

    /// Applies a saved rule right away. Events the previous version created where the new one will not
    /// find them (another target calendar or mode) are deleted; then the rule runs when `run` is true,
    /// which deletes its events that no longer match its days, hours or range.
    public func applyRuleChange(from previous: SyncRule?, to saved: SyncRule, run: Bool) {
        runQueue.async { [self] in applyRuleChangeNow(from: previous, to: saved, run: run) }
    }

    func applyRuleChangeNow(from previous: SyncRule?, to saved: SyncRule, run: Bool) {
        if let previous, previous.marker != saved.marker || previous.targetCalendarId != saved.targetCalendarId {
            let from = Calendar.current.startOfDay(for: Date())
            let to = Calendar.current.date(byAdding: .day, value: Self.maxDaysAhead + 1, to: from)!
            do {
                let count = try purgeNow(calendarId: previous.targetCalendarId, from: from, to: to, marker: previous.marker)
                addLog(SyncLogEntry(
                    timestamp: Date(), rule: currentLabel(for: previous), status: "PURGE",
                    message: "\(count) events deleted after the rule changed calendar or mode"
                ))
            } catch {
                addLog(SyncLogEntry(timestamp: Date(), rule: currentLabel(for: previous), status: "ERROR", message: error.localizedDescription))
            }
        }
        guard run, saved.enabled else { return }
        locked { running = true }
        notify()
        _ = performRun(rules: [saved], trigger: "rule saved", cleanUpBeyondRange: true)
    }

    /// Runs rules synchronously (waiting for an in-progress run to finish first).
    public func run(ruleIds: [UUID]? = nil, from: Date? = nil, to: Date? = nil) -> [SyncRuleResult] {
        runQueue.sync {
            locked { running = true }
            notify()
            reconcileCalendars()
            let rules = configStore.config.syncRules.filter { rule in
                if let ruleIds { return ruleIds.contains(rule.id) }
                return rule.enabled
            }
            return performRun(rules: rules, trigger: "mcp", from: from, to: to, cleanUpBeyondRange: to == nil)
        }
    }

    /// Runs a one-off sync that is not stored as a rule.
    public func runAdHoc(_ rule: SyncRule, from: Date? = nil, to: Date? = nil) -> SyncRuleResult {
        runQueue.sync {
            locked { running = true }
            notify()
            return performRun(rules: [rule], trigger: "mcp", from: from, to: to).first!
        }
    }

    /// Points stored calendars that got a new id (e.g. after their account was removed and added
    /// again) at the calendar with the same title and account, and logs what was relinked.
    @discardableResult
    public func reconcileCalendars() -> [CalendarReferenceChange] {
        let changes = configStore.reconcileCalendars(with: backend.calendarReferences())
        for change in changes {
            NSLog("EventKitMCP: calendar \(change.calendar) moved from id \(change.oldId) to \(change.newId)")
            addLog(SyncLogEntry(
                timestamp: Date(), rule: change.calendar, status: "RELINK",
                message: "Calendar has a new id; settings now point at it"
            ))
        }
        return changes
    }

    public func purge(calendarId: String, from: Date, to: Date, marker: String?, dryRun: Bool) throws -> Int {
        try runQueue.sync {
            let count = try dryRun
                ? CalendarSyncEngine(backend: backend).purge(calendarId: calendarId, from: from, to: to, marker: marker, dryRun: true)
                : purgeNow(calendarId: calendarId, from: from, to: to, marker: marker)
            if !dryRun {
                let name = backend.calendarDisplayName(calendarId) ?? calendarId
                addLog(SyncLogEntry(timestamp: Date(), rule: name, status: "PURGE", message: "\(count) synced events deleted"))
            }
            return count
        }
    }

    /// Must run on `runQueue`.
    private func purgeNow(calendarId: String, from: Date, to: Date, marker: String?) throws -> Int {
        try CalendarSyncEngine(backend: backend).purge(calendarId: calendarId, from: from, to: to, marker: marker, dryRun: false)
    }

    /// `cleanUpBeyondRange` also deletes the rules' events after the range, up to `maxDaysAhead`, so
    /// shortening the configured range removes what lies beyond it. Only for runs over that range:
    /// a run over a custom range must not touch events outside it.
    private func performRun(
        rules: [SyncRule], trigger: String, from: Date? = nil, to: Date? = nil, cleanUpBeyondRange: Bool = false
    ) -> [SyncRuleResult] {
        defer {
            locked {
                running = false
                lastRun = Date()
            }
            notify()
        }

        let config = configStore.config
        let start = from ?? Calendar.current.startOfDay(for: Date())
        let end = to ?? Calendar.current.date(byAdding: .day, value: max(1, config.syncDaysAhead), to: start)!
        let engine = CalendarSyncEngine(backend: backend)
        let cleanUpUntil = cleanUpBeyondRange ? Calendar.current.date(byAdding: .day, value: Self.maxDaysAhead + 1, to: start) : nil

        if rules.isEmpty {
            addLog(SyncLogEntry(timestamp: Date(), rule: "", status: "SKIP", message: "No enabled rules to run (\(trigger))"))
            return []
        }

        var results: [SyncRuleResult] = []
        for rule in rules {
            let label = currentLabel(for: rule)
            do {
                let summary = try engine.run(
                    sourceCalendarId: rule.sourceCalendarId,
                    targetCalendarId: rule.targetCalendarId,
                    from: start,
                    to: end,
                    options: rule.options,
                    marker: rule.marker,
                    cleanUpUntil: cleanUpUntil
                )
                results.append(SyncRuleResult(ruleId: rule.id.uuidString, rule: label, status: "ok", summary: summary))
                addLog(SyncLogEntry(timestamp: Date(), rule: label, status: summary.errors > 0 ? "WARN" : "OK", message: summary.description))
            } catch {
                let message = error.localizedDescription
                locked { lastError = message }
                results.append(SyncRuleResult(ruleId: rule.id.uuidString, rule: label, status: "error", error: message))
                addLog(SyncLogEntry(timestamp: Date(), rule: label, status: "ERROR", message: message))
            }
        }
        return results
    }

    public func currentLabel(for rule: SyncRule) -> String {
        let source = backend.calendarDisplayName(rule.sourceCalendarId) ?? rule.source.displayName
        let target = backend.calendarDisplayName(rule.targetCalendarId) ?? rule.target.displayName
        return "\(source) → \(target) (\(rule.mode.rawValue))"
    }

    private func addLog(_ entry: SyncLogEntry) {
        locked {
            log.append(entry)
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            log.removeAll { $0.timestamp < cutoff }
            if log.count > 200 { log.removeFirst(log.count - 200) }
        }
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
