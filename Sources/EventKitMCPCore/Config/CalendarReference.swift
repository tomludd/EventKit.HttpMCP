import Foundation

/// A calendar stored in the config: its EventKit id plus the title and account it had. EventKit hands
/// out new ids when an account is removed and added again; the names let `AppConfig.reconcileCalendars(with:)`
/// find the calendar again.
public struct CalendarReference: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var account: String

    public init(id: String, title: String = "", account: String = "") {
        self.id = id
        self.title = title
        self.account = account
    }

    public init(_ calendar: CalendarInfo) {
        self.init(id: calendar.id, title: calendar.title, account: calendar.account)
    }

    /// Splits a "Title (Account)" display name, as stored by versions that kept only that.
    init(id: String, displayName: String) {
        if displayName.hasSuffix(")"), let open = displayName.range(of: " (", options: .backwards) {
            self.init(
                id: id,
                title: String(displayName[..<open.lowerBound]),
                account: String(displayName[open.upperBound..<displayName.index(before: displayName.endIndex)])
            )
        } else {
            self.init(id: id, title: displayName)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? ""
    }

    /// "Title (Account)", like `CalendarInfo.displayName`.
    public var displayName: String { account.isEmpty ? title : "\(title) (\(account))" }

    /// The calendar this reference points at: the one with its id, otherwise the only one with the
    /// same title and account. nil when the calendar is gone or the name is ambiguous.
    public func resolve(in calendars: [CalendarReference]) -> CalendarReference? {
        if let byId = calendars.first(where: { $0.id == id }) { return byId }
        guard !title.isEmpty else { return nil }
        let byName = calendars.filter { $0.displayName.caseInsensitiveCompare(displayName) == .orderedSame }
        return byName.count == 1 ? byName[0] : nil
    }
}

/// A stored calendar that was found again under a new id.
public struct CalendarReferenceChange: Sendable, Equatable {
    public var calendar: String
    public var oldId: String
    public var newId: String
}

extension AppConfig {
    /// Points references whose calendar id no longer exists at the calendar with the same title and
    /// account, and refreshes the stored names of the others (calendars can be renamed). References
    /// that cannot be resolved are kept as they are, so they recover if the calendar comes back.
    @discardableResult
    public mutating func reconcileCalendars(with calendars: [CalendarReference]) -> [CalendarReferenceChange] {
        // No calendars (no access yet, or accounts still loading) must not look like "every calendar is gone".
        guard !calendars.isEmpty else { return [] }
        var changes: [CalendarReferenceChange] = []

        func reconcile(_ reference: inout CalendarReference) {
            guard let match = reference.resolve(in: calendars) else { return }
            if match.id != reference.id && !changes.contains(where: { $0.oldId == reference.id }) {
                changes.append(CalendarReferenceChange(calendar: match.displayName, oldId: reference.id, newId: match.id))
            }
            reference = match
        }

        func reconcile(_ references: [CalendarReference]?) -> [CalendarReference]? {
            guard let references else { return nil }
            var seen = Set<String>()
            return references
                .map { reference in
                    var reference = reference
                    reconcile(&reference)
                    return reference
                }
                .filter { seen.insert($0.id).inserted }
        }

        for index in syncRules.indices {
            let before = syncRules[index]
            reconcile(&syncRules[index].source)
            reconcile(&syncRules[index].target)
            // The marker in the notes of the events a rule created is derived from the calendar ids.
            // Keep the original one, or the rule would no longer recognize (and would duplicate) them.
            if syncRules[index].markerKey == nil
                && (syncRules[index].sourceCalendarId != before.sourceCalendarId || syncRules[index].targetCalendarId != before.targetCalendarId) {
                syncRules[index].markerKey = before.effectiveMarkerKey
            }
        }
        mcpCalendars = reconcile(mcpCalendars)
        countdownCalendars = reconcile(countdownCalendars)
        return changes
    }
}
