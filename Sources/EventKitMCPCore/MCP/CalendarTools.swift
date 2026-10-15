import Foundation

/// The MCP tools: calendar CRUD (modelled on the `ical` CLI) plus calendar sync/blocking (from outlook-cli).
public enum CalendarTools {
    static let dateHelp = "ISO 8601 (2026-10-15T09:00:00+02:00), 'YYYY-MM-DD HH:mm' or 'YYYY-MM-DD' in local time, or today/tomorrow/yesterday/now"

    public static func register(on server: MCPServer, store: EventKitCalendarStore, sync: SyncCoordinator, config: ConfigStore) {
        registerTimeAndCalendars(server, store)
        registerEventQueries(server, store)
        registerEventEditing(server, store)
        registerSync(server, store, sync, config)
    }

    public static func instructions() -> String {
        let tz = TimeZone.autoupdatingCurrent
        let offset = DateInput.format(Date()).suffix(6)
        return """
        Access to the user's macOS calendars through EventKit: every account configured in Calendar.app \
        (iCloud, Exchange/Microsoft 365, Google, CalDAV, local). Local time zone: \(tz.identifier) (UTC\(offset)).
        - Date/time arguments accept ISO 8601; values without an offset are local time. A date-only `to` covers that whole day.
        - Call get_current_time if you need today's date. Event ids are opaque; pass them back unchanged.
        - Calendar arguments accept a calendar id, a title, or "Title (Account)" from list_calendars.
        - Sync rules mirror busy time from a source calendar into a target calendar: `block` mode creates anonymous \
        "Busy" events (Out of Office is kept), `copy` mode copies title and notes as Free. Sync-created events carry an \
        [eventkit-sync:…] marker in their notes and are never synced again. Event list/search tools hide them unless `include_synced` is true. Rules run automatically at minutes 12, 27, 42 and 57.
        """
    }

    // MARK: - Time & calendars

    struct TimeInfo: Encodable {
        let now: String
        let date: String
        let weekday: String
        let timeZone: String
        let utcOffset: String
    }

    private static func registerTimeAndCalendars(_ server: MCPServer, _ store: EventKitCalendarStore) {
        server.register(MCPTool(
            name: "get_current_time",
            title: "Current time",
            description: "Current local date, time, weekday and time zone.",
            inputSchema: schema([:]),
            readOnly: true
        ) { _ in
            let now = Date()
            let weekday = DateFormatter()
            weekday.locale = Locale(identifier: "en_US_POSIX")
            weekday.dateFormat = "EEEE"
            let iso = DateInput.format(now)
            return TimeInfo(
                now: iso,
                date: DateInput.formatDay(now),
                weekday: weekday.string(from: now),
                timeZone: TimeZone.autoupdatingCurrent.identifier,
                utcOffset: String(iso.suffix(6))
            )
        })

        server.register(MCPTool(
            name: "list_calendars",
            title: "List calendars",
            description: "Lists all calendars with id, title, account, type, color and whether they are writable.",
            inputSchema: schema([:]),
            readOnly: true
        ) { _ in
            try store.calendars()
        })
    }

    // MARK: - Event queries

    struct EventList: Encodable {
        let from: String
        let to: String
        let count: Int
        let truncated: Bool?
        let events: [EventInfo]
    }

    private static func registerEventQueries(_ server: MCPServer, _ store: EventKitCalendarStore) {
        server.register(MCPTool(
            name: "list_events",
            title: "List events",
            description: "Lists events (expanded recurring occurrences) in a date range, sorted by start. Defaults to today.",
            inputSchema: schema([
                "from": string("Range start. \(dateHelp). Default: start of today."),
                "to": string("Range end (exclusive; a date-only value includes that day). Default: end of the `from` day."),
                "calendars": stringArray("Calendar ids or names to include. Default: all calendars."),
                "query": string("Only events whose title, location or notes contain this text (case-insensitive)."),
                "include_notes": boolean("Include event notes/description. Default false."),
                "include_all_day": boolean("Include all-day events. Default true."),
                "include_synced": boolean("Include blocking/copied events created by sync rules. Default false."),
                "limit": integer("Maximum events to return. Default 200."),
            ]),
            readOnly: true
        ) { args in
            let now = Date()
            let from = try args.date("from", now: now) ?? Calendar.current.startOfDay(for: now)
            let to = try args.date("to", endOfDayIfDateOnly: true, now: now) ?? endOfDay(from)
            return try listEvents(store, args, from: from, to: to, defaultLimit: 200, now: now)
        })

        server.register(MCPTool(
            name: "search_events",
            title: "Search events",
            description: "Finds events whose title, location or notes contain the query. Searches 30 days back to 180 days ahead unless from/to are given.",
            inputSchema: schema([
                "query": string("Text to search for (case-insensitive)."),
                "from": string("Range start. \(dateHelp). Default: 30 days ago."),
                "to": string("Range end. Default: 180 days ahead."),
                "calendars": stringArray("Calendar ids or names to search. Default: all calendars."),
                "include_notes": boolean("Include event notes in the result. Default false."),
                "include_synced": boolean("Include blocking/copied events created by sync rules. Default false."),
                "limit": integer("Maximum events to return. Default 50."),
            ], required: ["query"]),
            readOnly: true
        ) { args in
            _ = try args.requiredString("query")
            let now = Date()
            let today = Calendar.current.startOfDay(for: now)
            let from = try args.date("from", now: now) ?? Calendar.current.date(byAdding: .day, value: -30, to: today)!
            let to = try args.date("to", endOfDayIfDateOnly: true, now: now) ?? Calendar.current.date(byAdding: .day, value: 181, to: today)!
            return try listEvents(store, args, from: from, to: to, defaultLimit: 50, now: now)
        })

        server.register(MCPTool(
            name: "upcoming_events",
            title: "Upcoming events",
            description: "Ongoing and upcoming events from now, with minutesUntilStart and join links. Skips all-day, declined, canceled and sync-created (blocking/copied) events by default.",
            inputSchema: schema([
                "days": integer("How many days ahead to look. Default 7."),
                "limit": integer("Maximum events to return. Default 10."),
                "calendars": stringArray("Calendar ids or names. Default: all calendars."),
                "include_all_day": boolean("Include all-day events. Default false."),
                "include_declined": boolean("Include declined and canceled events. Default false."),
                "include_synced": boolean("Include blocking/copied events created by sync rules. Default false."),
            ]),
            readOnly: true
        ) { args in
            let now = Date()
            let days = max(1, try args.int("days") ?? 7)
            let limit = max(1, try args.int("limit") ?? 10)
            let includeAllDay = try args.bool("include_all_day") ?? false
            let includeDeclined = try args.bool("include_declined") ?? false
            let includeSynced = try args.bool("include_synced") ?? false
            let to = now.addingTimeInterval(TimeInterval(days * 86400))
            let events = try store.events(from: now, to: to, calendars: args.stringArray("calendars"), includeNotes: false, now: now)
                .filter { includeAllDay || !$0.allDay }
                .filter { includeSynced || $0.synced != true }
                .filter { includeDeclined || ($0.myStatus != "declined" && $0.status != "canceled") }
            return EventList(
                from: DateInput.format(now),
                to: DateInput.format(to),
                count: min(events.count, limit),
                truncated: events.count > limit ? true : nil,
                events: Array(events.prefix(limit))
            )
        })

        server.register(MCPTool(
            name: "get_event",
            title: "Get event",
            description: "Full details of one event: notes, attendees with response status, organizer, recurrence, alerts and join link.",
            inputSchema: schema(["id": string("Event id from a list/search result.")], required: ["id"]),
            readOnly: true
        ) { args in
            try store.event(id: args.requiredString("id"))
        })

        server.register(MCPTool(
            name: "find_free_slots",
            title: "Find free time",
            description: "Finds free time slots of at least `duration_minutes` within working hours, treating busy, tentative and out-of-office events as blocked.",
            inputSchema: schema([
                "from": string("First day to search. \(dateHelp). Default: now."),
                "to": string("Last day to search (inclusive when date-only). Default: 5 days after `from`."),
                "duration_minutes": integer("Minimum slot length in minutes. Default 30."),
                "work_start_hour": integer("Working day start hour (0-23). Default 9."),
                "work_end_hour": integer("Working day end hour (1-24). Default 17."),
                "calendars": stringArray("Calendars that count as busy. Default: all calendars."),
                "include_weekends": boolean("Also search Saturdays and Sundays. Default false."),
            ]),
            readOnly: true
        ) { args in
            let now = Date()
            let from = try args.date("from", now: now) ?? now
            let to = try args.date("to", endOfDayIfDateOnly: true, now: now)
                ?? Calendar.current.date(byAdding: .day, value: 5, to: Calendar.current.startOfDay(for: from))!
            let duration = max(5, try args.int("duration_minutes") ?? 30)
            let workStart = min(max(try args.int("work_start_hour") ?? 9, 0), 23)
            let workEnd = min(max(try args.int("work_end_hour") ?? 17, workStart + 1), 24)
            let busy = try store.busyIntervals(from: from, to: to, calendars: args.stringArray("calendars"))
            let slots = FreeSlotFinder.find(
                busy: busy, from: from, to: to, durationMinutes: duration, workStartHour: workStart,
                workEndHour: workEnd, includeWeekends: try args.bool("include_weekends") ?? false, now: now
            )
            return FreeSlotResult(durationMinutes: duration, from: DateInput.format(from), to: DateInput.format(to), slots: slots)
        })
    }

    struct FreeSlotResult: Encodable {
        let durationMinutes: Int
        let from: String
        let to: String
        let slots: [FreeSlot]
    }

    private static func listEvents(
        _ store: EventKitCalendarStore, _ args: ToolArguments, from: Date, to: Date, defaultLimit: Int, now: Date
    ) throws -> EventList {
        let query = args.string("query")
        let includeNotes = try args.bool("include_notes") ?? false
        let includeAllDay = try args.bool("include_all_day") ?? true
        let includeSynced = try args.bool("include_synced") ?? false
        let limit = max(1, try args.int("limit") ?? defaultLimit)

        var events = try store.events(
            from: from, to: to, calendars: args.stringArray("calendars"), includeNotes: includeNotes || query != nil, now: now
        )
        if let query {
            events = events.filter { event in
                [event.title, event.location, event.notes].contains { $0?.localizedCaseInsensitiveContains(query) == true }
            }
        }
        if !includeAllDay { events = events.filter { !$0.allDay } }
        if !includeSynced { events = events.filter { $0.synced != true } }
        if !includeNotes { events = events.map { var event = $0; event.notes = nil; return event } }

        return EventList(
            from: DateInput.format(from),
            to: DateInput.format(to),
            count: min(events.count, limit),
            truncated: events.count > limit ? true : nil,
            events: Array(events.prefix(limit))
        )
    }

    // MARK: - Event editing

    struct DeleteResult: Encodable {
        let deleted: EventInfo
        let span: String
    }

    private static func registerEventEditing(_ server: MCPServer, _ store: EventKitCalendarStore) {
        let availabilityProperty = enumString(["busy", "free", "tentative", "unavailable"], "Free/busy status. `unavailable` = Out of Office.")
        let alertsProperty: JSONValue = [
            "type": "array",
            "items": ["type": "integer"],
            "description": "Alerts as minutes before start, e.g. [15, 60]. [] removes all alerts. Omit to use the calendar default.",
        ]
        let recurrenceProperty: JSONValue = [
            "type": "object",
            "description": "Makes the event repeat.",
            "properties": [
                "frequency": enumString(["daily", "weekly", "monthly", "yearly"], "Repeat frequency."),
                "interval": integer("Every N periods. Default 1."),
                "days_of_week": [
                    "type": "array",
                    "items": ["type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]],
                    "description": "For weekly recurrence: which weekdays.",
                ],
                "until": string("Last date of the series. \(dateHelp)."),
                "count": integer("Number of occurrences (alternative to `until`)."),
            ],
            "required": ["frequency"],
        ]
        let spanProperty = enumString(["this", "future"], "For recurring events: only this occurrence (default) or this and all future occurrences.")

        server.register(MCPTool(
            name: "create_event",
            title: "Create event",
            description: "Creates an event. Without `calendar` the default calendar is used. Attendees cannot be added through EventKit.",
            inputSchema: schema([
                "title": string("Event title."),
                "start": string("Start. \(dateHelp)."),
                "end": string("End. Default: start + duration_minutes."),
                "duration_minutes": integer("Length when `end` is omitted. Default 60."),
                "all_day": boolean("All-day event (start/end are dates; end is the last day, inclusive). Default false."),
                "calendar": string("Calendar id or name. Default: the default calendar."),
                "location": string("Location."),
                "notes": string("Notes / description."),
                "url": string("URL attached to the event."),
                "availability": availabilityProperty,
                "alerts": alertsProperty,
                "recurrence": recurrenceProperty,
            ], required: ["title", "start"]),
            readOnly: false
        ) { args in
            var changes = EventKitCalendarStore.EventChanges()
            changes.title = try args.requiredString("title")
            let isAllDay = try args.bool("all_day") ?? false
            guard let start = try args.date("start") else { throw ToolError("Missing required argument `start`.") }
            changes.isAllDay = isAllDay
            if isAllDay {
                changes.start = Calendar.current.startOfDay(for: start)
                changes.end = Calendar.current.startOfDay(for: try args.date("end") ?? start)
            } else {
                changes.start = start
                let duration = try args.int("duration_minutes") ?? 60
                changes.end = try args.date("end") ?? start.addingTimeInterval(TimeInterval(max(1, duration) * 60))
            }
            changes.calendar = args.string("calendar")
            changes.location = args.string("location").map { .some($0) }
            changes.notes = args.string("notes").map { .some($0) }
            changes.url = args.string("url").map { .some($0) }
            changes.availability = try availability(args)
            changes.alertMinutesBefore = try args.intArray("alerts")
            changes.recurrence = try recurrence(args)
            return try store.createEvent(changes)
        })

        server.register(MCPTool(
            name: "update_event",
            title: "Update event",
            description: "Updates fields of an event. Only the fields you pass change; pass an empty string to clear location/notes/url. Changing only `start` keeps the duration.",
            inputSchema: schema([
                "id": string("Event id."),
                "title": string("New title."),
                "start": string("New start. \(dateHelp)."),
                "end": string("New end."),
                "all_day": boolean("Make the event all-day or timed."),
                "calendar": string("Move to this calendar (id or name)."),
                "location": string("New location ('' clears)."),
                "notes": string("New notes ('' clears)."),
                "url": string("New URL ('' clears)."),
                "availability": availabilityProperty,
                "alerts": alertsProperty,
                "recurrence": recurrenceProperty,
                "span": spanProperty,
            ], required: ["id"]),
            readOnly: false
        ) { args in
            var changes = EventKitCalendarStore.EventChanges()
            changes.title = args.string("title")
            changes.isAllDay = try args.bool("all_day")
            changes.start = try args.date("start")
            changes.end = try args.date("end")
            if changes.isAllDay == true {
                changes.start = changes.start.map { Calendar.current.startOfDay(for: $0) }
                changes.end = changes.end.map { Calendar.current.startOfDay(for: $0) }
            }
            changes.calendar = args.string("calendar")
            changes.location = args.clearableString("location")
            changes.notes = args.clearableString("notes")
            changes.url = args.clearableString("url")
            changes.availability = try availability(args)
            changes.alertMinutesBefore = try args.intArray("alerts")
            changes.recurrence = try recurrence(args)
            return try store.updateEvent(id: args.requiredString("id"), changes: changes, futureEvents: try span(args))
        })

        server.register(MCPTool(
            name: "delete_event",
            title: "Delete event",
            description: "Deletes an event (or, with span=future, this and all future occurrences of a recurring event).",
            inputSchema: schema(["id": string("Event id."), "span": spanProperty], required: ["id"]),
            readOnly: false,
            destructive: true
        ) { args in
            let future = try span(args)
            let deleted = try store.deleteEvent(id: args.requiredString("id"), futureEvents: future)
            return DeleteResult(deleted: deleted, span: future ? "future" : "this")
        })
    }

    private static func availability(_ args: ToolArguments) throws -> EventAvailability? {
        guard let value = args.string("availability") else { return nil }
        guard let availability = EventAvailability(rawValue: value.lowercased()), availability != .notSupported else {
            throw ToolError("`availability` must be busy, free, tentative or unavailable.")
        }
        return availability
    }

    private static func span(_ args: ToolArguments) throws -> Bool {
        switch args.string("span")?.lowercased() {
        case nil, "this": return false
        case "future": return true
        default: throw ToolError("`span` must be 'this' or 'future'.")
        }
    }

    private static func recurrence(_ args: ToolArguments) throws -> EventKitCalendarStore.RecurrenceInput? {
        guard let recurrence = args.object("recurrence") else { return nil }
        return EventKitCalendarStore.RecurrenceInput(
            frequency: try recurrence.requiredString("frequency"),
            interval: try recurrence.int("interval") ?? 1,
            daysOfWeek: recurrence.stringArray("days_of_week"),
            until: try recurrence.date("until", endOfDayIfDateOnly: true),
            count: try recurrence.int("count")
        )
    }

    // MARK: - Sync

    struct RuleInfo: Encodable {
        let id: String
        let enabled: Bool
        let label: String
        let sourceCalendarId: String
        let targetCalendarId: String
        let mode: String
        let outsideWorkHoursOnly: Bool
        let workDayStartHour: Int
        let workDayEndHour: Int
        let blockEventName: String
        let blockEventLocation: String
        let marker: String
    }

    struct SyncStatus: Encodable {
        let autoSync: Bool
        let schedule: String
        let daysAhead: Int
        let running: Bool
        let lastRunAt: String?
        let nextRunAt: String?
        let lastError: String?
        let rules: [RuleInfo]
        let recentLog: [String]
    }

    struct RunResult: Encodable {
        let from: String
        let to: String
        let results: [SyncRuleResult]
    }

    struct PurgeResult: Encodable {
        let calendar: String
        let from: String
        let to: String
        let dryRun: Bool
        let count: Int
    }

    struct DeleteRuleResult: Encodable {
        let deleted: RuleInfo
        let purgedEvents: Int?
    }

    private static func registerSync(_ server: MCPServer, _ store: EventKitCalendarStore, _ sync: SyncCoordinator, _ config: ConfigStore) {
        func ruleInfo(_ rule: SyncRule) -> RuleInfo {
            RuleInfo(
                id: rule.id.uuidString,
                enabled: rule.enabled,
                label: sync.currentLabel(for: rule),
                sourceCalendarId: rule.sourceCalendarId,
                targetCalendarId: rule.targetCalendarId,
                mode: rule.mode.rawValue,
                outsideWorkHoursOnly: rule.outsideWorkHoursOnly,
                workDayStartHour: rule.workDayStartHour,
                workDayEndHour: rule.workDayEndHour,
                blockEventName: rule.blockEventName,
                blockEventLocation: rule.blockEventLocation,
                marker: rule.marker
            )
        }

        func findRule(_ reference: String) throws -> SyncRule {
            let rules = config.config.syncRules
            if let uuid = UUID(uuidString: reference), let rule = rules.first(where: { $0.id == uuid }) { return rule }
            let matches = rules.filter { $0.id.uuidString.lowercased().hasPrefix(reference.lowercased()) }
            if matches.count == 1 { return matches[0] }
            throw ToolError("Sync rule not found: \(reference). Use get_sync_status to list rule ids.")
        }

        func range(_ args: ToolArguments) throws -> (Date, Date) {
            let today = Calendar.current.startOfDay(for: Date())
            let from = try args.date("from") ?? today
            let days = max(1, config.config.syncDaysAhead)
            let to = try args.date("to", endOfDayIfDateOnly: true) ?? Calendar.current.date(byAdding: .day, value: days, to: from)!
            return (from, to)
        }

        let modeProperty = enumString(["block", "copy"], "block = anonymous Busy events (default); copy = copy title and notes, shown as Free.")
        let ruleOptionProperties: [String: JSONValue] = [
            "mode": modeProperty,
            "outside_work_hours_only": boolean("Only sync events outside working hours. Default false."),
            "work_day_start_hour": integer("Working day start hour for outside_work_hours_only. Default 7."),
            "work_day_end_hour": integer("Working day end hour for outside_work_hours_only. Default 18."),
            "block_event_name": string("Title of block events. Default 'Busy' (Out of Office events keep 'Out of Office')."),
            "block_event_location": string("Location of block events. Default none."),
        ]

        func applyOptions(_ args: ToolArguments, to rule: inout SyncRule) throws {
            if let mode = args.string("mode") {
                guard let parsed = SyncMode(rawValue: mode.lowercased()) else { throw ToolError("`mode` must be block or copy.") }
                rule.mode = parsed
            }
            if let value = try args.bool("outside_work_hours_only") { rule.outsideWorkHoursOnly = value }
            if let value = try args.int("work_day_start_hour") { rule.workDayStartHour = min(max(value, 0), 23) }
            if let value = try args.int("work_day_end_hour") { rule.workDayEndHour = min(max(value, 1), 24) }
            if let value = args.raw["block_event_name"]?.stringValue {
                rule.blockEventName = value.trimmingCharacters(in: .whitespaces).isEmpty ? "Busy" : value
            }
            if let value = args.raw["block_event_location"]?.stringValue { rule.blockEventLocation = value }
        }

        func applyCalendars(_ args: ToolArguments, to rule: inout SyncRule) throws {
            if let source = args.string("source_calendar") {
                let info = try store.calendarInfo(reference: source)
                rule.sourceCalendarId = info.id
                rule.sourceCalendarName = info.displayName
            }
            if let target = args.string("target_calendar") {
                let info = try store.calendarInfo(reference: target)
                guard info.writable else { throw ToolError("Target calendar is read-only: \(info.displayName)") }
                rule.targetCalendarId = info.id
                rule.targetCalendarName = info.displayName
            }
            guard !rule.sourceCalendarId.isEmpty, !rule.targetCalendarId.isEmpty else {
                throw ToolError("Both `source_calendar` and `target_calendar` are required.")
            }
            guard rule.sourceCalendarId != rule.targetCalendarId else {
                throw ToolError("Source and target calendar must differ.")
            }
        }

        server.register(MCPTool(
            name: "get_sync_status",
            title: "Sync status",
            description: "Lists calendar sync rules with ids, the schedule, last/next run and the recent sync log.",
            inputSchema: schema([:]),
            readOnly: true
        ) { _ in
            let current = config.config
            return SyncStatus(
                autoSync: current.autoSyncEnabled,
                schedule: "Every hour at minutes 12, 27, 42 and 57",
                daysAhead: current.syncDaysAhead,
                running: sync.isRunning,
                lastRunAt: sync.lastRunAt.map(DateInput.format),
                nextRunAt: sync.nextRunAt.map(DateInput.format),
                lastError: sync.lastErrorMessage,
                rules: current.syncRules.map(ruleInfo),
                recentLog: sync.recentLog(limit: 25).map(\.line)
            )
        })

        server.register(MCPTool(
            name: "run_sync",
            title: "Run calendar sync",
            description: "Runs calendar sync now. With `rule_id` runs that rule; with `source_calendar` + `target_calendar` runs a one-off sync (not saved); otherwise runs all enabled rules. Default range: today to the configured days ahead.",
            inputSchema: schema([
                "rule_id": string("Id (or id prefix) of a saved rule."),
                "source_calendar": string("One-off sync: calendar to copy busy time from."),
                "target_calendar": string("One-off sync: calendar to create block/copy events in."),
                "from": string("Range start. \(dateHelp). Default: today."),
                "to": string("Range end. Default: today + configured days ahead (90)."),
            ].merging(ruleOptionProperties) { a, _ in a }),
            readOnly: false
        ) { args in
            let (from, to) = try range(args)
            let results: [SyncRuleResult]
            if let reference = args.string("rule_id") {
                results = sync.run(ruleIds: [try findRule(reference).id], from: from, to: to)
            } else if args.has("source_calendar") || args.has("target_calendar") {
                var rule = SyncRule()
                try applyCalendars(args, to: &rule)
                try applyOptions(args, to: &rule)
                results = [sync.runAdHoc(rule, from: from, to: to)]
            } else {
                results = sync.run(from: from, to: to)
            }
            return RunResult(from: DateInput.format(from), to: DateInput.format(to), results: results)
        })

        server.register(MCPTool(
            name: "save_sync_rule",
            title: "Save sync rule",
            description: "Creates a sync rule, or updates the rule with `id`. Saved rules run on the automatic schedule and from the menu bar.",
            inputSchema: schema([
                "id": string("Rule id to update. Omit to create a new rule."),
                "source_calendar": string("Calendar to copy busy time from (id or name). Required for new rules."),
                "target_calendar": string("Writable calendar to create events in (id or name). Required for new rules."),
                "enabled": boolean("Whether the rule runs. Default true."),
            ].merging(ruleOptionProperties) { a, _ in a }),
            readOnly: false
        ) { args in
            var rule = try args.string("id").map(findRule) ?? SyncRule()
            try applyCalendars(args, to: &rule)
            try applyOptions(args, to: &rule)
            if let enabled = try args.bool("enabled") { rule.enabled = enabled }
            let saved = rule
            config.update { config in
                if let index = config.syncRules.firstIndex(where: { $0.id == saved.id }) {
                    config.syncRules[index] = saved
                } else {
                    config.syncRules.append(saved)
                }
            }
            return ruleInfo(saved)
        })

        server.register(MCPTool(
            name: "delete_sync_rule",
            title: "Delete sync rule",
            description: "Deletes a sync rule. With purge_events=true also deletes the events it created (today to the configured days ahead).",
            inputSchema: schema([
                "id": string("Rule id (or id prefix)."),
                "purge_events": boolean("Also delete the events this rule created. Default false."),
            ], required: ["id"]),
            readOnly: false,
            destructive: true
        ) { args in
            let rule = try findRule(try args.requiredString("id"))
            var purged: Int?
            if try args.bool("purge_events") == true {
                let (from, to) = try range(ToolArguments([:]))
                purged = try sync.purge(calendarId: rule.targetCalendarId, from: from, to: to, marker: rule.marker, dryRun: false)
            }
            config.update { $0.syncRules.removeAll { $0.id == rule.id } }
            return DeleteRuleResult(deleted: ruleInfo(rule), purgedEvents: purged)
        })

        server.register(MCPTool(
            name: "purge_synced_events",
            title: "Purge synced events",
            description: "Deletes events created by calendar sync from a calendar (all rules, or only `rule_id`). Use dry_run to count first.",
            inputSchema: schema([
                "calendar": string("Calendar to clean (id or name)."),
                "rule_id": string("Only remove events created by this rule."),
                "from": string("Range start. \(dateHelp). Default: today."),
                "to": string("Range end. Default: today + configured days ahead (90)."),
                "dry_run": boolean("Only count matching events. Default false."),
            ], required: ["calendar"]),
            readOnly: false,
            destructive: true
        ) { args in
            let calendar = try store.calendarInfo(reference: try args.requiredString("calendar"))
            let marker = try args.string("rule_id").map { try findRule($0).marker }
            let (from, to) = try range(args)
            let dryRun = try args.bool("dry_run") ?? false
            let count = try sync.purge(calendarId: calendar.id, from: from, to: to, marker: marker, dryRun: dryRun)
            return PurgeResult(calendar: calendar.displayName, from: DateInput.format(from), to: DateInput.format(to), dryRun: dryRun, count: count)
        })
    }

    // MARK: - Schema helpers

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var object: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
        return .object(object)
    }

    private static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    private static func integer(_ description: String) -> JSONValue {
        ["type": "integer", "description": .string(description)]
    }

    private static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    private static func stringArray(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    private static func enumString(_ values: [String], _ description: String) -> JSONValue {
        ["type": "string", "enum": .array(values.map(JSONValue.string)), "description": .string(description)]
    }

    private static func endOfDay(_ date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))!
    }
}
