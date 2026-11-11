import Foundation

public struct SyncRule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    public var source: CalendarReference
    public var target: CalendarReference
    /// Hash used in this rule's sync marker. nil derives it from the calendar ids; set when the ids
    /// change so the events the rule created before keep matching.
    public var markerKey: String?
    public var mode: SyncMode
    public var hoursFilter: HoursFilter
    /// Days of the week whose events sync; nil means every day.
    public var days: Set<Weekday>?
    /// Start and end of the hours `hoursFilter` uses. Named after the working day they first meant.
    public var workDayStartHour: Int
    public var workDayEndHour: Int
    public var blockEventName: String
    public var blockEventLocation: String
    /// Block events show as Out of Office instead of Busy.
    public var blockAsOutOfOffice: Bool

    public init(
        id: UUID = UUID(), enabled: Bool = true, source: CalendarReference = CalendarReference(id: ""),
        target: CalendarReference = CalendarReference(id: ""), markerKey: String? = nil, mode: SyncMode = .block,
        hoursFilter: HoursFilter = .any, days: Set<Weekday>? = nil, workDayStartHour: Int = 7, workDayEndHour: Int = 18,
        blockEventName: String = "Busy", blockEventLocation: String = "", blockAsOutOfOffice: Bool = false
    ) {
        self.id = id
        self.enabled = enabled
        self.source = source
        self.target = target
        self.markerKey = markerKey
        self.mode = mode
        self.hoursFilter = hoursFilter
        self.days = days
        self.workDayStartHour = workDayStartHour
        self.workDayEndHour = workDayEndHour
        self.blockEventName = blockEventName
        self.blockEventLocation = blockEventLocation
        self.blockAsOutOfOffice = blockAsOutOfOffice
    }

    private enum CodingKeys: String, CodingKey {
        case id, enabled, source, target, markerKey, mode, hoursFilter, days, workDayStartHour, workDayEndHour
        case blockEventName, blockEventLocation, blockAsOutOfOffice
    }

    /// Keys of configs written before calendars were stored with their title and account, and before
    /// the hours filter could be "within".
    private enum LegacyKeys: String, CodingKey {
        case sourceCalendarId, sourceCalendarName, targetCalendarId, targetCalendarName, outsideWorkHoursOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let defaults = SyncRule()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        source = try c.decodeIfPresent(CalendarReference.self, forKey: .source) ?? CalendarReference(
            id: try legacy.decodeIfPresent(String.self, forKey: .sourceCalendarId) ?? "",
            displayName: try legacy.decodeIfPresent(String.self, forKey: .sourceCalendarName) ?? ""
        )
        target = try c.decodeIfPresent(CalendarReference.self, forKey: .target) ?? CalendarReference(
            id: try legacy.decodeIfPresent(String.self, forKey: .targetCalendarId) ?? "",
            displayName: try legacy.decodeIfPresent(String.self, forKey: .targetCalendarName) ?? ""
        )
        markerKey = try c.decodeIfPresent(String.self, forKey: .markerKey)
        mode = try c.decodeIfPresent(SyncMode.self, forKey: .mode) ?? defaults.mode
        hoursFilter = try c.decodeIfPresent(HoursFilter.self, forKey: .hoursFilter)
            ?? (try legacy.decodeIfPresent(Bool.self, forKey: .outsideWorkHoursOnly) == true ? .outside : defaults.hoursFilter)
        days = try c.decodeIfPresent([Weekday].self, forKey: .days).map(Set.init)
        workDayStartHour = try c.decodeIfPresent(Int.self, forKey: .workDayStartHour) ?? defaults.workDayStartHour
        workDayEndHour = try c.decodeIfPresent(Int.self, forKey: .workDayEndHour) ?? defaults.workDayEndHour
        blockEventName = try c.decodeIfPresent(String.self, forKey: .blockEventName) ?? defaults.blockEventName
        blockEventLocation = try c.decodeIfPresent(String.self, forKey: .blockEventLocation) ?? defaults.blockEventLocation
        blockAsOutOfOffice = try c.decodeIfPresent(Bool.self, forKey: .blockAsOutOfOffice) ?? defaults.blockAsOutOfOffice
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(source, forKey: .source)
        try c.encode(target, forKey: .target)
        try c.encodeIfPresent(markerKey, forKey: .markerKey)
        try c.encode(mode, forKey: .mode)
        try c.encode(hoursFilter, forKey: .hoursFilter)
        try c.encodeIfPresent(days?.sorted { $0.number < $1.number }, forKey: .days)
        try c.encode(workDayStartHour, forKey: .workDayStartHour)
        try c.encode(workDayEndHour, forKey: .workDayEndHour)
        try c.encode(blockEventName, forKey: .blockEventName)
        try c.encode(blockEventLocation, forKey: .blockEventLocation)
        try c.encode(blockAsOutOfOffice, forKey: .blockAsOutOfOffice)
        // Read by versions before `hoursFilter`, so "outside" rules survive a downgrade.
        var legacy = encoder.container(keyedBy: LegacyKeys.self)
        try legacy.encode(hoursFilter == .outside, forKey: .outsideWorkHoursOnly)
    }

    public var sourceCalendarId: String { source.id }
    public var targetCalendarId: String { target.id }

    public var options: SyncOptions {
        SyncOptions(
            mode: mode,
            hoursFilter: hoursFilter,
            days: days,
            workDayStartHour: workDayStartHour,
            workDayEndHour: workDayEndHour,
            blockEventName: blockEventName,
            blockEventLocation: blockEventLocation,
            blockAsOutOfOffice: blockAsOutOfOffice
        )
    }

    var effectiveMarkerKey: String {
        markerKey ?? CalendarSyncEngine.ruleHash(sourceCalendarId, targetCalendarId)
    }

    public var marker: String {
        CalendarSyncEngine.marker(mode: mode, key: effectiveMarkerKey)
    }

    public var label: String {
        let source = source.title.isEmpty ? sourceCalendarId : source.displayName
        let target = target.title.isEmpty ? targetCalendarId : target.displayName
        return "\(source) → \(target) (\(mode.rawValue))"
    }
}

public struct AppConfig: Codable, Sendable, Equatable {
    public static let defaultPort = 8765

    public var port: Int
    public var mcpServerEnabled: Bool
    /// Calendars MCP clients can see and change; nil means all calendars.
    public var mcpCalendars: [CalendarReference]?
    public var autoSyncEnabled: Bool
    public var syncDaysAhead: Int
    public var syncRules: [SyncRule]
    /// Calendars considered for the menu bar countdown; nil means all calendars.
    public var countdownCalendars: [CalendarReference]?
    public var countdownWarningMinutes: Int
    public var countdownCriticalMinutes: Int
    /// Show time to the next meeting even when it is further away than the warning threshold.
    public var alwaysShowNextMeeting: Bool
    public var showMeetingTitleInMenuBar: Bool

    public init() {
        port = Self.defaultPort
        mcpServerEnabled = true
        mcpCalendars = nil
        autoSyncEnabled = true
        syncDaysAhead = 90
        syncRules = []
        countdownCalendars = nil
        countdownWarningMinutes = 10
        countdownCriticalMinutes = 4
        alwaysShowNextMeeting = false
        showMeetingTitleInMenuBar = false
    }

    /// Keys of configs written before calendars were stored with their title and account.
    private enum LegacyKeys: String, CodingKey {
        case mcpCalendarIds, countdownCalendarIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let d = AppConfig()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        mcpServerEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpServerEnabled) ?? d.mcpServerEnabled
        autoSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoSyncEnabled) ?? d.autoSyncEnabled
        syncDaysAhead = try c.decodeIfPresent(Int.self, forKey: .syncDaysAhead) ?? d.syncDaysAhead
        syncRules = try c.decodeIfPresent([SyncRule].self, forKey: .syncRules) ?? d.syncRules
        countdownWarningMinutes = try c.decodeIfPresent(Int.self, forKey: .countdownWarningMinutes) ?? d.countdownWarningMinutes
        countdownCriticalMinutes = try c.decodeIfPresent(Int.self, forKey: .countdownCriticalMinutes) ?? d.countdownCriticalMinutes
        alwaysShowNextMeeting = try c.decodeIfPresent(Bool.self, forKey: .alwaysShowNextMeeting) ?? d.alwaysShowNextMeeting
        showMeetingTitleInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showMeetingTitleInMenuBar) ?? d.showMeetingTitleInMenuBar

        // Old configs stored bare ids; borrow names from sync rules that use the same calendars.
        var known: [String: CalendarReference] = [:]
        for reference in syncRules.flatMap({ [$0.source, $0.target] }) where !reference.title.isEmpty {
            known[reference.id] = known[reference.id] ?? reference
        }
        func references(_ key: CodingKeys, legacy legacyKey: LegacyKeys) throws -> [CalendarReference]? {
            if let references = try c.decodeIfPresent([CalendarReference].self, forKey: key) { return references }
            return try legacy.decodeIfPresent([String].self, forKey: legacyKey)?.map { known[$0] ?? CalendarReference(id: $0) }
        }
        mcpCalendars = try references(.mcpCalendars, legacy: .mcpCalendarIds)
        countdownCalendars = try references(.countdownCalendars, legacy: .countdownCalendarIds)
    }

    /// Ids of `mcpCalendars` as a set for lookups; nil means all calendars.
    public var mcpCalendarScope: Set<String>? { mcpCalendars.map { Set($0.map(\.id)) } }

    /// Ids of `countdownCalendars`; nil means all calendars.
    public var countdownCalendarIds: [String]? { countdownCalendars?.map(\.id) }
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

    /// Applies `AppConfig.reconcileCalendars(with:)`, saving when anything changed.
    @discardableResult
    public func reconcileCalendars(with calendars: [CalendarReference]) -> [CalendarReferenceChange] {
        var changes: [CalendarReferenceChange] = []
        update { changes = $0.reconcileCalendars(with: calendars) }
        return changes
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
