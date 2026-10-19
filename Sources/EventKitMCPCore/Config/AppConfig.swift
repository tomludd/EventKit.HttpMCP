import Foundation

public struct SyncRule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    public var sourceCalendarId: String
    public var sourceCalendarName: String
    public var targetCalendarId: String
    public var targetCalendarName: String
    public var mode: SyncMode
    public var outsideWorkHoursOnly: Bool
    public var workDayStartHour: Int
    public var workDayEndHour: Int
    public var blockEventName: String
    public var blockEventLocation: String

    public init(
        id: UUID = UUID(), enabled: Bool = true, sourceCalendarId: String = "", sourceCalendarName: String = "",
        targetCalendarId: String = "", targetCalendarName: String = "", mode: SyncMode = .block,
        outsideWorkHoursOnly: Bool = false, workDayStartHour: Int = 7, workDayEndHour: Int = 18,
        blockEventName: String = "Busy", blockEventLocation: String = ""
    ) {
        self.id = id
        self.enabled = enabled
        self.sourceCalendarId = sourceCalendarId
        self.sourceCalendarName = sourceCalendarName
        self.targetCalendarId = targetCalendarId
        self.targetCalendarName = targetCalendarName
        self.mode = mode
        self.outsideWorkHoursOnly = outsideWorkHoursOnly
        self.workDayStartHour = workDayStartHour
        self.workDayEndHour = workDayEndHour
        self.blockEventName = blockEventName
        self.blockEventLocation = blockEventLocation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SyncRule()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        sourceCalendarId = try c.decodeIfPresent(String.self, forKey: .sourceCalendarId) ?? ""
        sourceCalendarName = try c.decodeIfPresent(String.self, forKey: .sourceCalendarName) ?? ""
        targetCalendarId = try c.decodeIfPresent(String.self, forKey: .targetCalendarId) ?? ""
        targetCalendarName = try c.decodeIfPresent(String.self, forKey: .targetCalendarName) ?? ""
        mode = try c.decodeIfPresent(SyncMode.self, forKey: .mode) ?? defaults.mode
        outsideWorkHoursOnly = try c.decodeIfPresent(Bool.self, forKey: .outsideWorkHoursOnly) ?? defaults.outsideWorkHoursOnly
        workDayStartHour = try c.decodeIfPresent(Int.self, forKey: .workDayStartHour) ?? defaults.workDayStartHour
        workDayEndHour = try c.decodeIfPresent(Int.self, forKey: .workDayEndHour) ?? defaults.workDayEndHour
        blockEventName = try c.decodeIfPresent(String.self, forKey: .blockEventName) ?? defaults.blockEventName
        blockEventLocation = try c.decodeIfPresent(String.self, forKey: .blockEventLocation) ?? defaults.blockEventLocation
    }

    public var options: SyncOptions {
        SyncOptions(
            mode: mode,
            outsideWorkHoursOnly: outsideWorkHoursOnly,
            workDayStartHour: workDayStartHour,
            workDayEndHour: workDayEndHour,
            blockEventName: blockEventName,
            blockEventLocation: blockEventLocation
        )
    }

    public var marker: String {
        CalendarSyncEngine.marker(mode: mode, sourceCalendarId: sourceCalendarId, targetCalendarId: targetCalendarId)
    }

    public var label: String {
        let source = sourceCalendarName.isEmpty ? sourceCalendarId : sourceCalendarName
        let target = targetCalendarName.isEmpty ? targetCalendarId : targetCalendarName
        return "\(source) → \(target) (\(mode.rawValue))"
    }
}

public struct AppConfig: Codable, Sendable, Equatable {
    public static let defaultPort = 8765

    public var port: Int
    public var mcpServerEnabled: Bool
    /// Calendars MCP clients can see and change; nil means all calendars.
    public var mcpCalendarIds: [String]?
    public var autoSyncEnabled: Bool
    public var syncDaysAhead: Int
    public var syncRules: [SyncRule]
    /// Calendars considered for the menu bar countdown; nil means all calendars.
    public var countdownCalendarIds: [String]?
    public var countdownWarningMinutes: Int
    public var countdownCriticalMinutes: Int
    /// Show time to the next meeting even when it is further away than the warning threshold.
    public var alwaysShowNextMeeting: Bool
    public var showMeetingTitleInMenuBar: Bool

    public init() {
        port = Self.defaultPort
        mcpServerEnabled = true
        mcpCalendarIds = nil
        autoSyncEnabled = true
        syncDaysAhead = 90
        syncRules = []
        countdownCalendarIds = nil
        countdownWarningMinutes = 10
        countdownCriticalMinutes = 4
        alwaysShowNextMeeting = false
        showMeetingTitleInMenuBar = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        mcpServerEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpServerEnabled) ?? d.mcpServerEnabled
        mcpCalendarIds = try c.decodeIfPresent([String].self, forKey: .mcpCalendarIds)
        autoSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoSyncEnabled) ?? d.autoSyncEnabled
        syncDaysAhead = try c.decodeIfPresent(Int.self, forKey: .syncDaysAhead) ?? d.syncDaysAhead
        syncRules = try c.decodeIfPresent([SyncRule].self, forKey: .syncRules) ?? d.syncRules
        countdownCalendarIds = try c.decodeIfPresent([String].self, forKey: .countdownCalendarIds)
        countdownWarningMinutes = try c.decodeIfPresent(Int.self, forKey: .countdownWarningMinutes) ?? d.countdownWarningMinutes
        countdownCriticalMinutes = try c.decodeIfPresent(Int.self, forKey: .countdownCriticalMinutes) ?? d.countdownCriticalMinutes
        alwaysShowNextMeeting = try c.decodeIfPresent(Bool.self, forKey: .alwaysShowNextMeeting) ?? d.alwaysShowNextMeeting
        showMeetingTitleInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showMeetingTitleInMenuBar) ?? d.showMeetingTitleInMenuBar
    }

    /// `mcpCalendarIds` as a set for lookups; nil means all calendars.
    public var mcpCalendarScope: Set<String>? { mcpCalendarIds.map(Set.init) }
}

/// Thread-safe JSON persistence of `AppConfig` in ~/Library/Application Support/EventKitMCP/config.json.
public final class ConfigStore: @unchecked Sendable {
    public static let didChangeNotification = Notification.Name("EventKitMCP.ConfigDidChange")

    public let fileURL: URL
    private let lock = NSLock()
    private var current: AppConfig

    public init(fileURL: URL = ConfigStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            current = config
        } else {
            current = AppConfig()
        }
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EventKitMCP", isDirectory: true).appendingPathComponent("config.json")
    }

    public var config: AppConfig {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    @discardableResult
    public func update(_ mutate: (inout AppConfig) -> Void) -> AppConfig {
        lock.lock()
        var copy = current
        mutate(&copy)
        let changed = copy != current
        current = copy
        if changed { save(copy) }
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
        return copy
    }

    private func save(_ config: AppConfig) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("EventKitMCP: failed to save config: \(error)")
        }
    }
}
