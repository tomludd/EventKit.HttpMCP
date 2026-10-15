import EventKitMCPCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
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
    @State private var portText = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("MCP server") {
                LabeledContent("Endpoint") {
                    HStack {
                        Text(model.endpointURL).font(.body.monospaced()).textSelection(.enabled)
                        CopyButton(text: model.endpointURL)
                    }
                }
                LabeledContent("Status") {
                    Text(model.serverStatusText).foregroundStyle(serverStatusColor)
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
                Text("Only reachable from this Mac: the server listens on 127.0.0.1 and ::1 only and rejects requests whose Host or Origin is not localhost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                if model.calendars.isEmpty {
                    Text("No calendars available.").foregroundStyle(.secondary)
                }
                ForEach(model.calendars) { calendar in
                    Toggle(isOn: countdownBinding(calendar.id)) {
                        CalendarLabel(calendar: calendar)
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
            }
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

    /// nil in the config means "all calendars"; it is materialized on the first change.
    private func countdownBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.config.countdownCalendarIds?.contains(id) ?? true },
            set: { included in
                let all = model.calendars.map(\.id)
                var selected = Set(model.config.countdownCalendarIds ?? all)
                if included { selected.insert(id) } else { selected.remove(id) }
                let value: [String]? = Set(all).isSubset(of: selected) ? nil : all.filter(selected.contains)
                model.updateConfig { $0.countdownCalendarIds = value }
            }
        )
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
                Stepper("Sync \(model.config.syncDaysAhead) days ahead", value: model.binding(\.syncDaysAhead), in: 1...365)
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

            Section {
                if model.config.syncRules.isEmpty {
                    Text("No rules yet. A rule blocks time in one calendar whenever you are busy in another, e.g. your work calendar → your personal calendar.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.config.syncRules) { rule in
                    RuleRow(
                        rule: rule,
                        onEdit: { editingRule = rule },
                        onRun: { model.runRule(rule) },
                        onPurge: { ruleToPurge = rule },
                        onDelete: { ruleToDelete = rule }
                    )
                }
                HStack {
                    Spacer()
                    Button {
                        editingRule = SyncRule()
                    } label: {
                        Label("Add Rule…", systemImage: "plus")
                    }
                    .disabled(model.calendars.isEmpty)
                }
            } header: {
                Text("Rules")
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
                Text(name(rule.sourceCalendarId, fallback: rule.sourceCalendarName))
                    + Text("  →  ").foregroundStyle(.secondary)
                    + Text(name(rule.targetCalendarId, fallback: rule.targetCalendarName))
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

    private func name(_ id: String, fallback: String) -> String {
        model.calendars.first { $0.id == id }?.displayName ?? (fallback.isEmpty ? "Missing calendar" : fallback)
    }

    private var details: String {
        var parts: [String] = []
        switch rule.mode {
        case .block:
            parts.append("Block as “\(rule.blockEventName)”")
            if !rule.blockEventLocation.isEmpty { parts.append("at \(rule.blockEventLocation)") }
        case .copy:
            parts.append("Copy title and notes")
        }
        if rule.outsideWorkHoursOnly {
            parts.append("only outside \(rule.workDayStartHour):00–\(rule.workDayEndHour):00")
        }
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
                Picker("Copy busy time from", selection: $rule.sourceCalendarId) {
                    Text("Choose a calendar…").tag("")
                    ForEach(model.calendars) { calendar in
                        Text(calendar.displayName).tag(calendar.id)
                    }
                }
                Picker("Into calendar", selection: $rule.targetCalendarId) {
                    Text("Choose a calendar…").tag("")
                    ForEach(model.calendars.filter(\.writable)) { calendar in
                        Text(calendar.displayName).tag(calendar.id)
                    }
                }
                Picker("Mode", selection: $rule.mode) {
                    Text("Block — anonymous busy events").tag(SyncMode.block)
                    Text("Copy — title and notes, shown as free").tag(SyncMode.copy)
                }
                if rule.mode == .block {
                    TextField("Block title", text: $rule.blockEventName, prompt: Text("Busy"))
                    TextField("Block location", text: $rule.blockEventLocation, prompt: Text("None"))
                }
                Toggle("Only events outside working hours", isOn: $rule.outsideWorkHoursOnly)
                if rule.outsideWorkHoursOnly {
                    Stepper("Working day starts \(rule.workDayStartHour):00", value: $rule.workDayStartHour, in: 0...23)
                    Stepper("Working day ends \(rule.workDayEndHour):00", value: $rule.workDayEndHour, in: 1...24)
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
                    saved.sourceCalendarName = model.calendars.first { $0.id == saved.sourceCalendarId }?.displayName ?? saved.sourceCalendarName
                    saved.targetCalendarName = model.calendars.first { $0.id == saved.targetCalendarId }?.displayName ?? saved.targetCalendarName
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
        if rule.outsideWorkHoursOnly && rule.workDayEndHour <= rule.workDayStartHour { return "Working day must end after it starts." }
        return nil
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

private struct CalendarLabel: View {
    let calendar: CalendarInfo

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: NSColor(hex: calendar.color) ?? .secondaryLabelColor))
                .frame(width: 10, height: 10)
            Text(calendar.title)
            Text(calendar.account).foregroundStyle(.secondary)
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
