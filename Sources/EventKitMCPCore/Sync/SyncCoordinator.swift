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
            _ = performRun(rules: configStore.config.syncRules.filter(\.enabled), trigger: trigger)
        }
        return true
    }

    /// Runs rules synchronously (waiting for an in-progress run to finish first).
    public func run(ruleIds: [UUID]? = nil, from: Date? = nil, to: Date? = nil) -> [SyncRuleResult] {
        runQueue.sync {
            locked { running = true }
            notify()
            let rules = configStore.config.syncRules.filter { rule in
                if let ruleIds { return ruleIds.contains(rule.id) }
                return rule.enabled
            }
            return performRun(rules: rules, trigger: "mcp", from: from, to: to)
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

    public func purge(calendarId: String, from: Date, to: Date, marker: String?, dryRun: Bool) throws -> Int {
        try runQueue.sync {
            let count = try CalendarSyncEngine(backend: backend).purge(
                calendarId: calendarId, from: from, to: to, marker: marker, dryRun: dryRun
            )
            if !dryRun {
                let name = backend.calendarDisplayName(calendarId) ?? calendarId
                addLog(SyncLogEntry(timestamp: Date(), rule: name, status: "PURGE", message: "\(count) synced events deleted"))
            }
            return count
        }
    }

    private func performRun(rules: [SyncRule], trigger: String, from: Date? = nil, to: Date? = nil) -> [SyncRuleResult] {
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
                    options: rule.options
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
        let source = backend.calendarDisplayName(rule.sourceCalendarId) ?? rule.sourceCalendarName
        let target = backend.calendarDisplayName(rule.targetCalendarId) ?? rule.targetCalendarName
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
