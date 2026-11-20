import EventKitMCPCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            MCPSettingsTab()
                .tabItem { Label("MCP", systemImage: "server.rack") }
            SyncSettingsTab()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            SyncLogTab()
                .tabItem { Label("Sync Log", systemImage: "list.bullet.rectangle") }
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 520)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Calendar access") {
                LabeledContent("Status") {
                    Text(model.accessDescription.capitalized)
                        .foregroundStyle(model.hasAccess ? Color.secondary : Color.red)
                }
                if !model.hasAccess {
                    Button("Grant Calendar Access…") { Task { await model.requestAccess() } }
                }
            }

            Section("Menu bar countdown") {
                Stepper(
                    "Show countdown \(model.config.countdownWarningMinutes) min before a meeting",
                    value: model.binding(\.countdownWarningMinutes),
                    in: 1...120
                )
                Stepper(
                    "Turn red \(model.config.countdownCriticalMinutes) min before",
                    value: model.binding(\.countdownCriticalMinutes),
                    in: 1...60
                )
                Toggle("Always show time to the next meeting", isOn: model.binding(\.alwaysShowNextMeeting))
                Toggle("Show meeting title in the menu bar", isOn: model.binding(\.showMeetingTitleInMenuBar))
            }

            Section("Calendars in the menu") {
                CalendarSelectionSummary(selection: \.countdownCalendars)
            }
            CalendarSelectionSections(selection: \.countdownCalendars)

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not change login item: \(error.localizedDescription). Run the app from ~/Applications."
        }
    }
}

// MARK: - MCP

private struct MCPSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var portText = ""

    var body: some View {
        Form {
            Section {
                Toggle("Enable MCP server", isOn: model.binding(\.mcpServerEnabled))
                LabeledContent("Status") {
                    Text(model.serverStatusText).foregroundStyle(serverStatusColor)
                }
                LabeledContent("Endpoint") {
                    HStack {
                        Text(model.endpointURL).font(.body.monospaced()).textSelection(.enabled)
                        CopyButton(text: model.endpointURL)
                    }
                }
                LabeledContent("Port") {
                    HStack {
                        TextField("Port", text: $portText)
                            .frame(width: 80)
                            .onSubmit(applyPort)
                        Button("Apply", action: applyPort).disabled(parsedPort == nil || parsedPort == model.config.port)
                    }
                }
                LabeledContent("Claude Code") {
                    HStack(alignment: .top) {
                        Text(model.claudeCommand).font(.caption.monospaced()).textSelection(.enabled)
                        CopyButton(text: model.claudeCommand)
                    }
                }
            } header: {
                Text("MCP server")
            } footer: {
                Text(model.config.allowsNetworkClients
                     ? "Reachable from the networks allowed below as well as from this Mac. Calendar sync and the menu bar keep working while the server is disabled."
                     : "Only reachable from this Mac: the server listens on 127.0.0.1 and ::1 only and rejects requests whose Host or Origin is not localhost. Calendar sync and the menu bar keep working while the server is disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            NetworkAccessSection()

            Section {
                CalendarSelectionSummary(selection: \.mcpCalendars)
            } header: {
                Text("Calendars available to MCP clients")
            } footer: {
                Text("MCP clients can only list, search, create and change events in the selected calendars, and only see sync rules between them. While all calendars are selected, new calendars are included automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            CalendarSelectionSections(selection: \.mcpCalendars)
        }
        .formStyle(.grouped)
        .onAppear { portText = String(model.config.port) }
    }

    private var parsedPort: Int? {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(port) else { return nil }
        return port
    }

    private var serverStatusColor: Color {
        switch model.serverStatus {
        case .running: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private func applyPort() {
        guard let port = parsedPort else { return }
        model.updateConfig { $0.port = port }
    }
}

/// Allowed client networks (CIDR) and the API key other machines must send.
private struct NetworkAccessSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var newEntry = ""
    @State private var entryError: String?
    @State private var showKey = false
    @State private var confirmRegenerate = false

    var body: some View {
        Section {
            if model.config.allowsNetworkClients {
                Label(networkBanner, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Only this Mac can connect.", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }

            ForEach(model.config.allowedClientCIDRs, id: \.self) { entry in
                HStack {
                    Text(entry).font(.body.monospaced())
                    if let range = CIDRRange(entry) {
                        if range.matchesEverything {
                            Text("every \(range.network.isIPv4 ? "IPv4" : "IPv6") address").font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Text("invalid, ignored").font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button { remove(entry) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove")
                }
            }

            LabeledContent("Allow network") {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack {
                        TextField("", text: $newEntry, prompt: Text("192.168.1.0/24 or fd00::/8"))
                            .font(.body.monospaced())
                            .frame(width: 220)
                            .onSubmit(add)
                            .onChange(of: newEntry) { _, _ in entryError = nil }
                        Button("Add", action: add)
                            .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let entryError {
                        Text(entryError).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            LabeledContent("API key") {
                if let key = model.config.apiKey, !key.isEmpty {
                    HStack {
                        Text(showKey ? key : String(repeating: "•", count: 16))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless)
                            .help(showKey ? "Hide" : "Show")
                        CopyButton(text: key)
                        Button("Regenerate…") { confirmRegenerate = true }
                    }
                } else {
                    HStack {
                        Text("Created when you allow a network").foregroundStyle(.secondary)
                        Button("Generate Now") { model.regenerateAPIKey() }
                    }
                }
            }

            if model.config.allowsNetworkClients, let key = model.config.apiKey {
                // A few addresses of this Mac; IPv6 privacy addresses would otherwise fill the list.
                let addresses = Array(InternetAddress.localInterfaceAddresses().prefix(4))
                ForEach(Array(addresses.enumerated()), id: \.element) { index, address in
                    let url = remoteURL(address)
                    LabeledContent(index == 0 ? "From other machines" : "") {
                        HStack {
                            Text(url).font(.caption.monospaced()).textSelection(.enabled)
                            CopyButton(text: url)
                        }
                    }
                }
                LabeledContent("Claude Code (remote)") {
                    let command = remoteCommand(key: key, address: addresses.first)
                    HStack(alignment: .top) {
                        Text(command.replacingOccurrences(of: key, with: "<key>")).font(.caption.monospaced())
                        CopyButton(text: command)
                    }
                }
            }
        } header: {
            Text("Network access")
        } footer: {
            Text("Add networks in CIDR notation (a bare address is one host) to let other machines connect. The server then listens on all interfaces and refuses connections from anywhere else. Clients on other machines must send the API key as \"Authorization: Bearer <key>\" or \"X-API-Key: <key>\"; clients on this Mac never need it. Traffic is plain HTTP, so only allow networks you trust. IPv4 networks also match IPv4-mapped IPv6 peers; ::/0 does not include IPv4.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Regenerate the API key?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { model.regenerateAPIKey() }
        } message: {
            Text("Clients on other machines stop working until they use the new key.")
        }
    }

    private var networkBanner: String {
        if case .running = model.serverStatus, !model.isReachableFromNetwork {
            return "Network access is on, but the server has not restarted yet."
        }
        return "Reachable from the network: clients in the networks below can connect with the API key."
    }

    private func add() {
        let text = newEntry.trimmingCharacters(in: .whitespaces)
        guard let range = CIDRRange(text) else {
            entryError = "Not a valid IPv4 or IPv6 network, e.g. 192.168.1.0/24, 10.0.0.5/32 or fd00::/8."
            return
        }
        let entry = range.description
        guard !model.config.allowedClientCIDRs.contains(where: { CIDRRange($0) == range }) else {
            entryError = "\(entry) is already allowed."
            return
        }
        model.updateConfig { $0.allowedClientCIDRs.append(entry) }
        newEntry = ""
        entryError = nil
    }

    private func remove(_ entry: String) {
        model.updateConfig { $0.allowedClientCIDRs.removeAll { $0 == entry } }
    }

    private func remoteURL(_ address: InternetAddress) -> String {
        let host = address.isIPv4 ? address.description : "[\(address)]"
        return "http://\(host):\(model.config.port)\(MCPHTTPHandler.endpointPath)"
    }

    private func remoteCommand(key: String, address: InternetAddress?) -> String {
        let url = address.map(remoteURL) ?? "http://<this-mac>:\(model.config.port)\(MCPHTTPHandler.endpointPath)"
        return "claude mcp add --transport http --scope user eventkit \(url) --header \"Authorization: Bearer \(key)\""
    }
}

// MARK: - Sync

private struct SyncSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingRule: SyncRule?
    @State private var ruleToDelete: SyncRule?
    @State private var ruleToPurge: SyncRule?

    var body: some View {
        Form {
            Section {
                Toggle("Sync automatically every hour at :12, :27, :42 and :57", isOn: model.binding(\.autoSyncEnabled))
                Stepper("Sync \(model.config.syncDaysAhead) days ahead", value: model.binding(\.syncDaysAhead), in: 1...SyncCoordinator.maxDaysAhead)
                HStack {
                    Button("Sync Now") { model.syncNow() }
                        .disabled(model.isSyncing || model.config.syncRules.isEmpty)
                    if model.isSyncing { ProgressView().controlSize(.small) }
                    Spacer()
                    if let last = model.lastSyncAt {
                        Text("Last run \(last.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if model.config.syncRules.isEmpty {
                Section("Rules") {
                    Text("No rules yet. A rule blocks time in one calendar whenever you are busy in another, e.g. your work calendar → your personal calendar.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(ruleGroups, id: \.source.id) { group in
                Section {
                    ForEach(group.rules) { rule in
                        RuleRow(
                            rule: rule,
                            onEdit: { editingRule = rule },
                            onRun: { model.runRule(rule) },
                            onPurge: { ruleToPurge = rule },
                            onDelete: { ruleToDelete = rule }
                        )
                    }
                } header: {
                    SourceHeader(source: group.source)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button {
                        editingRule = SyncRule()
                    } label: {
                        Label("Add Rule…", systemImage: "plus")
                    }
                    .disabled(model.calendars.isEmpty)
                }
            } footer: {
                Text("Block mode creates anonymous events (Out of Office stays Out of Office). Copy mode copies title and notes as Free. Created events are tagged [eventkit-sync:…] in their notes and are never synced again, so two-way rules are safe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingRule) { rule in
            RuleEditor(rule: rule, isNew: !model.config.syncRules.contains { $0.id == rule.id }) { saved in
                model.saveRule(saved)
            }
            .environmentObject(model)
        }
        .confirmationDialog(
            "Delete this rule?",
            isPresented: Binding(get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } }),
            presenting: ruleToDelete
        ) { rule in
            Button("Delete Rule and Its Events", role: .destructive) {
                model.purgeRule(rule)
                model.deleteRule(rule)
            }
            Button("Delete Rule Only", role: .destructive) { model.deleteRule(rule) }
        } message: { rule in
            Text(rule.label)
        }
        .confirmationDialog(
            "Delete the events this rule created?",
            isPresented: Binding(get: { ruleToPurge != nil }, set: { if !$0 { ruleToPurge = nil } }),
            presenting: ruleToPurge
        ) { rule in
            Button("Purge Events", role: .destructive) { model.purgeRule(rule) }
        } message: { rule in
            Text("Removes \(rule.mode == .block ? "block" : "copied") events created by “\(rule.label)” from today and \(model.config.syncDaysAhead) days ahead. They are recreated on the next run if the rule is still enabled.")
        }
    }

    /// Rules grouped by source calendar, groups and rules in the order they were added.
    private var ruleGroups: [(source: CalendarReference, rules: [SyncRule])] {
        var groups: [(source: CalendarReference, rules: [SyncRule])] = []
        for rule in model.config.syncRules {
            if let index = groups.firstIndex(where: { $0.source.id == rule.source.id }) {
                groups[index].rules.append(rule)
            } else {
                groups.append((rule.source, [rule]))
            }
        }
        return groups
    }
}

private struct SourceHeader: View {
    @EnvironmentObject private var model: AppModel
    let source: CalendarReference

    var body: some View {
        if let calendar = model.calendars.first(where: { $0.id == source.id }) {
            CalendarLabel(calendar: calendar)
        } else {
            Text(source.title.isEmpty ? "Missing calendar" : "\(source.displayName) (missing)")
        }
    }
}

private struct RuleRow: View {
    @EnvironmentObject private var model: AppModel
    let rule: SyncRule
    let onEdit: () -> Void
    let onRun: () -> Void
    let onPurge: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { enabled in
                    var updated = rule
                    updated.enabled = enabled
                    model.saveRule(updated)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text("→  ").foregroundStyle(.secondary) + Text(name(rule.target))
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit…", action: onEdit)
            Menu {
                Button("Run Now", action: onRun)
                Button("Purge Created Events…", action: onPurge)
                Divider()
                Button("Delete Rule…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .opacity(rule.enabled ? 1 : 0.6)
    }

    private func name(_ reference: CalendarReference) -> String {
        if let calendar = model.calendars.first(where: { $0.id == reference.id }) { return calendar.displayName }
        return reference.title.isEmpty ? "Missing calendar" : "\(reference.displayName) (missing)"
    }

    private var hours: String {
        "\(rule.workDayStartHour):00–\(rule.workDayEndHour):00"
    }

    private var details: String {
        var parts: [String] = []
        switch rule.mode {
        case .block:
            parts.append("Block as “\(rule.blockEventName)”" + (rule.blockAsOutOfOffice ? " (Out of Office)" : ""))
            if !rule.blockEventLocation.isEmpty { parts.append("at \(rule.blockEventLocation)") }
        case .copy:
            parts.append("Copy title and notes")
        }
        switch rule.hoursFilter {
        case .any: break
        case .outside: parts.append("only outside \(hours)")
        case .within: parts.append("only between \(hours)")
        }
        if let days = rule.days { parts.append("on \(Weekday.describe(days))") }
        if rule.availabilities != SyncOptions.defaultAvailabilities {
            parts.append("shown as \(EventAvailability.describe(rule.availabilities))")
        }
        if rule.onlyResponded { parts.append("only answered invitations") }
        return parts.joined(separator: " · ")
    }
}

private struct RuleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var rule: SyncRule
    let isNew: Bool
    let onSave: (SyncRule) -> Void

    init(rule: SyncRule, isNew: Bool, onSave: @escaping (SyncRule) -> Void) {
        _rule = State(initialValue: rule)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Sync Rule" : "Edit Sync Rule").font(.title3.bold())
            Form {
                Toggle("Enabled", isOn: $rule.enabled)
                CalendarMenuPicker(title: "Copy events from", calendars: model.calendars, reference: $rule.source)
                CalendarMenuPicker(title: "Into calendar", calendars: model.calendars.filter(\.writable), reference: $rule.target)
                Picker("Mode", selection: $rule.mode) {
                    Text("Block — anonymous busy events").tag(SyncMode.block)
                    Text("Copy — title and notes, shown as free").tag(SyncMode.copy)
                }
                if rule.mode == .block {
                    Picker("Show as", selection: $rule.blockAsOutOfOffice) {
                        Text("Busy").tag(false)
                        Text("Out of Office").tag(true)
                    }
                    TextField("Block title", text: $rule.blockEventName, prompt: Text("Busy"))
                    TextField("Block location", text: $rule.blockEventLocation, prompt: Text("None"))
                }
                AvailabilityPicker(availabilities: $rule.availabilities)
                Toggle("Only events I have responded to", isOn: $rule.onlyResponded)
                    .help("Skips invitations you have not accepted or tentatively accepted, including ones sent to a group you are in. Your own events and meetings you organize still sync.")
                WeekdayPicker(days: $rule.days)
                Picker("Sync events", selection: $rule.hoursFilter) {
                    Text("At any time").tag(HoursFilter.any)
                    Text("Only outside these hours").tag(HoursFilter.outside)
                    Text("Only between these hours").tag(HoursFilter.within)
                }
                if rule.hoursFilter != .any {
                    Stepper("From \(rule.workDayStartHour):00", value: $rule.workDayStartHour, in: 0...23)
                    Stepper("To \(rule.workDayEndHour):00", value: $rule.workDayEndHour, in: 1...24)
                }
            }
            .formStyle(.grouped)

            if let validationMessage {
                Text(validationMessage).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = rule
                    if saved.blockEventName.trimmingCharacters(in: .whitespaces).isEmpty { saved.blockEventName = "Busy" }
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }


    private var validationMessage: String? {
        if rule.sourceCalendarId.isEmpty { return "Choose the calendar to copy busy time from." }
        if rule.targetCalendarId.isEmpty { return "Choose the calendar to create events in." }
        if rule.sourceCalendarId == rule.targetCalendarId { return "Source and target must be different calendars." }
        if rule.availabilities.isEmpty { return "Choose at least one of Busy, Free, Tentative, Out of Office or Working Elsewhere." }
        if rule.days?.isEmpty == true { return "Choose at least one day." }
        if rule.hoursFilter != .any && rule.workDayEndHour <= rule.workDayStartHour { return "The hours must end after they start." }
        return nil
    }
}

/// Calendar picker whose menu is grouped by account and sorted by title. A Menu rather than a Picker,
/// so the menu items can show just the title while the button still shows "Title (Account)".
private struct CalendarMenuPicker: View {
    let title: String
    let calendars: [CalendarInfo]
    @Binding var reference: CalendarReference

    var body: some View {
        LabeledContent(title) {
            Menu(selectedName) {
                ForEach(calendarsByAccount(calendars), id: \.account) { group in
                    Section(group.account) {
                        ForEach(group.calendars) { calendar in
                            Toggle(calendar.title, isOn: Binding(
                                get: { reference.id == calendar.id },
                                set: { if $0 { reference = CalendarReference(calendar) } }
                            ))
                        }
                    }
                }
            }
            .fixedSize()
        }
    }

    private var selectedName: String {
        if reference.id.isEmpty { return "Choose a calendar…" }
        if let calendar = calendars.first(where: { $0.id == reference.id }) { return calendar.displayName }
        return reference.title.isEmpty ? "Missing calendar" : "\(reference.displayName) (missing)"
    }

}

/// One toggle button per day of the week, in the order the user's calendar starts its week.
/// Which source events sync, by how they are shown (busy, free, ...).
private struct AvailabilityPicker: View {
    @Binding var availabilities: Set<EventAvailability>

    var body: some View {
        LabeledContent("Events shown as") {
            HStack(spacing: 4) {
                ForEach(SyncOptions.selectableAvailabilities, id: \.self) { availability in
                    Toggle(availability.displayName, isOn: Binding(
                        get: { availabilities.contains(availability) },
                        set: { on in
                            if on { availabilities.insert(availability) } else { availabilities.remove(availability) }
                        }
                    ))
                    .toggleStyle(.button)
                }
            }
        }
    }
}

extension EventAvailability {
    var displayName: String {
        switch self {
        case .busy: return "Busy"
        case .free: return "Free"
        case .tentative: return "Tentative"
        case .unavailable: return "Out of Office"
        case .workingElsewhere: return "Working Elsewhere"
        case .notSupported: return "Not Supported"
        }
    }

    /// "busy, free" in the order the picker shows them.
    static func describe(_ availabilities: Set<EventAvailability>) -> String {
        SyncOptions.selectableAvailabilities.filter(availabilities.contains).map { $0.displayName.lowercased() }
            .joined(separator: ", ")
    }
}

private struct WeekdayPicker: View {
    @Binding var days: Set<Weekday>?

    var body: some View {
        LabeledContent("Days") {
            HStack(spacing: 4) {
                ForEach(Weekday.localOrder, id: \.self) { day in
                    Toggle(day.shortName, isOn: Binding(
                        get: { days?.contains(day) ?? true },
                        set: { on in
                            var selected = days ?? Set(Weekday.allCases)
                            if on { selected.insert(day) } else { selected.remove(day) }
                            days = selected.count == Weekday.allCases.count ? nil : selected
                        }
                    ))
                    .toggleStyle(.button)
                }
            }
        }
    }
}

extension Weekday {
    /// Every day, starting at the user's first day of the week.
    static var localOrder: [Weekday] {
        let first = Calendar.current.firstWeekday
        return (0..<7).compactMap { Weekday(number: (first - 1 + $0) % 7 + 1) }
    }

    var shortName: String { Calendar.current.shortStandaloneWeekdaySymbols[number - 1] }

    /// "weekdays", "weekends" or the days listed in the user's week order.
    static func describe(_ days: Set<Weekday>) -> String {
        if days == workdays { return "weekdays" }
        if days == [.sat, .sun] { return "weekends" }
        if days.isEmpty { return "no days" }
        return localOrder.filter(days.contains).map(\.shortName).joined(separator: ", ")
    }
}

// MARK: - Log

private struct SyncLogTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sync runs from the last 24 hours").foregroundStyle(.secondary)
                Spacer()
                if model.isSyncing { ProgressView().controlSize(.small) }
                Button("Sync Now") { model.syncNow() }.disabled(model.isSyncing)
            }
            List(model.syncLog.reversed()) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(entry.status)
                        .font(.caption.bold())
                        .foregroundStyle(statusColor(entry.status))
                        .frame(width: 48, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        if !entry.rule.isEmpty { Text(entry.rule) }
                        Text(entry.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if model.syncLog.isEmpty {
                    Text("No sync runs yet").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "OK": return .green
        case "ERROR": return .red
        case "WARN": return .orange
        default: return .secondary
        }
    }
}

// MARK: - Shared views

/// Accounts in the order EventKit lists them, calendars within each sorted by title.
private func calendarsByAccount(_ calendars: [CalendarInfo]) -> [(account: String, calendars: [CalendarInfo])] {
    var groups: [(account: String, calendars: [CalendarInfo])] = []
    for calendar in calendars {
        let account = calendar.account.isEmpty ? "No account" : calendar.account
        if let index = groups.firstIndex(where: { $0.account == account }) {
            groups[index].calendars.append(calendar)
        } else {
            groups.append((account, [calendar]))
        }
    }
    return groups.map { group in
        (group.account, group.calendars.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }
}

/// "N of M calendars" with Select All / Select None, for a selection where nil means all calendars.
private struct CalendarSelectionSummary: View {
    @EnvironmentObject private var model: AppModel
    let selection: WritableKeyPath<AppConfig, [CalendarReference]?>

    var body: some View {
        if model.calendars.isEmpty {
            Text("No calendars available.").foregroundStyle(.secondary)
        } else {
            HStack {
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                Button("Select All") { model.updateConfig { $0[keyPath: selection] = nil } }
                    .disabled(model.config[keyPath: selection] == nil)
                Button("Select None") { model.updateConfig { $0[keyPath: selection] = [] } }
                    .disabled(model.config[keyPath: selection]?.isEmpty == true)
            }
        }
    }

    private var summary: String {
        guard let selected = model.config[keyPath: selection] else { return "All calendars" }
        let ids = Set(selected.map(\.id))
        return "\(model.calendars.filter { ids.contains($0.id) }.count) of \(model.calendars.count) calendars"
    }
}

/// One section of calendar toggles per account.
private struct CalendarSelectionSections: View {
    @EnvironmentObject private var model: AppModel
    let selection: WritableKeyPath<AppConfig, [CalendarReference]?>

    var body: some View {
        ForEach(calendarsByAccount(model.calendars), id: \.account) { group in
            Section(group.account) {
                ForEach(group.calendars) { calendar in
                    Toggle(isOn: model.calendarSelection(selection, contains: calendar)) {
                        CalendarLabel(calendar: calendar, showsAccount: false)
                    }
                }
            }
        }
    }
}

private struct CalendarLabel: View {
    let calendar: CalendarInfo
    var showsAccount = true

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: NSColor(hex: calendar.color) ?? .secondaryLabelColor))
                .frame(width: 10, height: 10)
            Text(calendar.title)
            if showsAccount { Text(calendar.account).foregroundStyle(.secondary) }
        }
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}
