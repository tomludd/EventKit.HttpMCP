import AppKit
import Combine
import EventKit
import EventKitMCPCore
import SwiftUI

/// Shared state for the menu bar item and the settings window.
@MainActor
final class AppModel: ObservableObject {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    let configStore = ConfigStore()
    let store = EventKitCalendarStore()
    let sync: SyncCoordinator
    let mcp: MCPService
    private var httpServer: LocalHTTPServer?
    private var observers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?

    @Published private(set) var config: AppConfig
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var hasAccess = EventKitCalendarStore.hasFullAccess
    @Published private(set) var accessDescription = EventKitCalendarStore.authorizationDescription
    @Published private(set) var serverStatus: LocalHTTPServer.Status = .stopped
    @Published private(set) var serverPort: Int
    @Published private(set) var meetings: [MeetingSnapshot] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var syncLog: [SyncLogEntry] = []
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var nextSyncAt: Date?

    init() {
        config = configStore.config
        serverPort = configStore.config.port
        sync = SyncCoordinator(backend: store, configStore: configStore)
        mcp = MCPService(store: store, sync: sync, config: configStore, version: Self.version)
    }

    var endpointURL: String { MCPService.endpointURL(port: serverPort) }
    var claudeCommand: String { MCPService.claudeCodeCommand(port: serverPort) }

    var serverStatusText: String {
        switch serverStatus {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running(let port): return "Running on 127.0.0.1:\(port)"
        case .failed(let message): return "Error: \(message)"
        }
    }

    // MARK: - Lifecycle

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ConfigStore.didChangeNotification, object: configStore, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configDidChange() }
        })
        observers.append(center.addObserver(forName: SyncCoordinator.didChangeNotification, object: sync, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSyncState() }
        })
        observers.append(center.addObserver(forName: .EKEventStoreChanged, object: store.store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMeetings()
                self?.reloadCalendars()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMeetings() }
        })

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMeetings() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        startServer()
        sync.startScheduler()
        refreshSyncState()

        if EventKitCalendarStore.authorizationStatus == .notDetermined {
            Task { await requestAccess() }
        } else {
            accessDidChange()
        }
    }

    func stop() {
        sync.stopScheduler()
        httpServer?.stop()
        refreshTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Config

    func updateConfig(_ mutate: (inout AppConfig) -> Void) {
        config = configStore.update(mutate)
    }

    func binding<Value>(_ keyPath: WritableKeyPath<AppConfig, Value>) -> Binding<Value> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { value in self.updateConfig { $0[keyPath: keyPath] = value } }
        )
    }

    private func configDidChange() {
        let previous = config
        config = configStore.config
        if config.port != serverPort { restartServer() }
        if config.countdownCalendarIds != previous.countdownCalendarIds { refreshMeetings() }
        refreshSyncState()
    }

    // MARK: - Calendar access

    func requestAccess() async {
        switch EventKitCalendarStore.authorizationStatus {
        case .notDetermined:
            NSApp.activate()
            _ = await store.requestAccess()
            accessDidChange()
        case .fullAccess:
            accessDidChange()
        default:
            openPrivacySettings()
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func accessDidChange() {
        hasAccess = EventKitCalendarStore.hasFullAccess
        accessDescription = EventKitCalendarStore.authorizationDescription
        reloadCalendars()
        refreshMeetings()
    }

    func reloadCalendars() {
        guard EventKitCalendarStore.hasFullAccess else { return }
        let store = self.store
        Task.detached {
            let calendars = (try? store.calendars()) ?? []
            await MainActor.run { self.calendars = calendars }
        }
    }

    func refreshMeetings() {
        if hasAccess != EventKitCalendarStore.hasFullAccess {
            hasAccess = EventKitCalendarStore.hasFullAccess
            accessDescription = EventKitCalendarStore.authorizationDescription
        }
        let store = self.store
        let calendarIds = config.countdownCalendarIds
        Task.detached {
            let meetings = store.upcomingMeetings(from: Date(), hours: 48, calendarIds: calendarIds)
            await MainActor.run { self.meetings = meetings }
        }
    }

    // MARK: - MCP server

    func startServer() {
        let port = config.port
        serverPort = port
        guard let portNumber = UInt16(exactly: port) else {
            serverStatus = .failed("Invalid port \(port)")
            return
        }
        let handler = mcp.httpHandler
        let server = LocalHTTPServer(port: portNumber) { request in handler.handle(request) }
        server.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.serverStatus = status }
        }
        httpServer = server
        server.start()
    }

    func restartServer() {
        httpServer?.stop()
        httpServer = nil
        startServer()
    }

    // MARK: - Sync

    func syncNow() {
        sync.runInBackground(trigger: "menu")
    }

    func saveRule(_ rule: SyncRule) {
        updateConfig { config in
            if let index = config.syncRules.firstIndex(where: { $0.id == rule.id }) {
                config.syncRules[index] = rule
            } else {
                config.syncRules.append(rule)
            }
        }
    }

    func deleteRule(_ rule: SyncRule) {
        updateConfig { $0.syncRules.removeAll { $0.id == rule.id } }
    }

    func runRule(_ rule: SyncRule) {
        let sync = self.sync
        Task.detached { _ = sync.run(ruleIds: [rule.id]) }
    }

    /// Deletes the events a rule created from today to the configured days ahead.
    func purgeRule(_ rule: SyncRule) {
        let sync = self.sync
        let days = config.syncDaysAhead
        Task.detached {
            let from = Calendar.current.startOfDay(for: Date())
            let to = Calendar.current.date(byAdding: .day, value: days, to: from)!
            _ = try? sync.purge(calendarId: rule.targetCalendarId, from: from, to: to, marker: rule.marker, dryRun: false)
        }
    }

    private func refreshSyncState() {
        let wasSyncing = isSyncing
        isSyncing = sync.isRunning
        syncLog = sync.recentLog(limit: 200)
        lastSyncAt = sync.lastRunAt
        nextSyncAt = sync.nextRunAt
        if wasSyncing && !isSyncing { refreshMeetings() }
    }

    // MARK: - Meetings

    func open(_ meeting: MeetingSnapshot) {
        if let url = meeting.joinURL {
            NSWorkspace.shared.open(url)
        } else if let encoded = meeting.eventIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        }
    }
}
