import AppKit
import Combine
import EventKitMCPCore

/// The menu bar item: calendar icon + countdown to the next meeting, and the dropdown menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var tickTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var headerItem: NSMenuItem?
    private var isMenuOpen = false
    private var lastIconName = ""

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        super.init()

        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        updateButton()
    }

    private func tick() {
        updateButton()
        if isMenuOpen { headerItem?.attributedTitle = headerTitle() }
    }

    // MARK: - Button

    private func currentDisplay(now: Date = Date()) -> CountdownDisplay {
        MeetingCountdown.display(
            meetings: model.meetings,
            now: now,
            warningMinutes: model.config.countdownWarningMinutes,
            criticalMinutes: model.config.countdownCriticalMinutes,
            alwaysShow: model.config.alwaysShowNextMeeting,
            showTitle: model.config.showMeetingTitleInMenuBar
        )
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let display = currentDisplay()

        let iconName: String
        if !model.hasAccess {
            iconName = "calendar.badge.exclamationmark"
        } else if model.isSyncing {
            iconName = "arrow.triangle.2.circlepath"
        } else if case .failed = model.serverStatus {
            iconName = "calendar.badge.exclamationmark"
        } else {
            iconName = "calendar"
        }
        if iconName != lastIconName {
            let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "EventKit MCP")
            image?.isTemplate = true
            button.image = image
            lastIconName = iconName
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: display.level == .critical ? .semibold : .regular)
        switch display.level {
        case .hidden:
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        case .critical:
            button.attributedTitle = NSAttributedString(
                string: " \(display.text)",
                attributes: [.font: font, .foregroundColor: NSColor.systemRed]
            )
            button.imagePosition = .imageLeading
        case .normal, .warning:
            button.attributedTitle = NSAttributedString(string: "")
            button.font = font
            button.title = " \(display.text)"
            button.imagePosition = .imageLeading
        }

        if let meeting = display.meeting {
            button.toolTip = "Next: \(meeting.title) at \(Self.timeFormatter.string(from: meeting.start))"
        } else {
            button.toolTip = "EventKit MCP — no upcoming meetings"
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        model.refreshMeetings()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()

        if !model.hasAccess {
            menu.addItem(item("Grant Calendar Access…", #selector(grantAccess), symbol: "exclamationmark.triangle"))
            menu.addItem(.separator())
        }

        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.attributedTitle = headerTitle(now: now)
        header.isEnabled = false
        headerItem = header
        menu.addItem(header)

        addMeetingSections(to: menu, now: now)

        menu.addItem(.separator())
        let syncItem = item(model.isSyncing ? "Syncing…" : "Sync Calendars Now", #selector(syncNow), key: "s", symbol: "arrow.triangle.2.circlepath")
        syncItem.isEnabled = !model.isSyncing
        menu.addItem(syncItem)
        menu.addItem(disabled(syncStatusText(), symbol: nil, small: true))

        menu.addItem(.separator())
        let serverRunning: Bool
        if case .running = model.serverStatus { serverRunning = true } else { serverRunning = false }
        menu.addItem(disabled("MCP server: \(serverRunning ? "Running" : "Not running")", symbol: "server.rack", small: false))

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ",", symbol: "gearshape"))
        menu.addItem(item("Quit EventKit MCP", #selector(quit), key: "q", symbol: nil))
    }

    private func headerTitle(now: Date = Date()) -> NSAttributedString {
        let bold = NSFont.menuFont(ofSize: 0).withWeight(.semibold)
        guard model.hasAccess else {
            return NSAttributedString(string: "No calendar access", attributes: [.font: bold])
        }
        guard let next = MeetingCountdown.nextMeeting(in: model.meetings, now: now) else {
            return NSAttributedString(string: "No upcoming meetings", attributes: [.font: bold])
        }
        let remaining = next.start.timeIntervalSince(now)
        let withSeconds = remaining < TimeInterval(model.config.countdownWarningMinutes * 60)
        let text = NSMutableAttributedString(string: "Next: \(next.title) — in ", attributes: [.font: bold])
        var countdownAttributes: [NSAttributedString.Key: Any] = [.font: bold]
        if remaining < TimeInterval(model.config.countdownCriticalMinutes * 60) {
            countdownAttributes[.foregroundColor] = NSColor.systemRed
        }
        text.append(NSAttributedString(string: MeetingCountdown.format(remaining: remaining, withSeconds: withSeconds), attributes: countdownAttributes))
        return text
    }

    private func addMeetingSections(to menu: NSMenu, now: Date) {
        let calendar = Calendar.current
        let visible = model.meetings.filter { !$0.isCanceled && !$0.isSyncedBlock && $0.end > now }
        let today = visible.filter { calendar.isDateInToday($0.start) || ($0.start < now) }
        let tomorrow = visible.filter { calendar.isDateInTomorrow($0.start) }

        for (title, meetings, max) in [("Today", today, 12), ("Tomorrow", tomorrow, 6)] where !meetings.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: title))
            for meeting in meetings.prefix(max) {
                menu.addItem(meetingItem(meeting, now: now))
            }
            if meetings.count > max {
                menu.addItem(disabled("…and \(meetings.count - max) more", symbol: nil, small: true))
            }
        }
    }

    private func meetingItem(_ meeting: MeetingSnapshot, now: Date) -> NSMenuItem {
        let time = meeting.isAllDay
            ? "All day"
            : "\(Self.timeFormatter.string(from: meeting.start))–\(Self.timeFormatter.string(from: meeting.end))"
        let item = NSMenuItem(title: "", action: #selector(openMeeting(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = meeting

        let ongoing = meeting.isOngoing(at: now) && !meeting.isAllDay
        let font = ongoing ? NSFont.menuFont(ofSize: 0).withWeight(.semibold) : NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(
            string: "\(time)  ",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        )
        var titleAttributes: [NSAttributedString.Key: Any] = [.font: font]
        if meeting.isDeclined {
            titleAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            titleAttributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        title.append(NSAttributedString(string: meeting.title.isEmpty ? "(No title)" : meeting.title, attributes: titleAttributes))
        if ongoing {
            title.append(NSAttributedString(string: "  now", attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.systemGreen]))
        }
        item.attributedTitle = title
        item.image = calendarDot(hex: meeting.calendarColorHex, video: meeting.joinURL != nil)
        item.toolTip = [meeting.calendarTitle, meeting.location, meeting.joinURL.map { "Click to join: \($0.host ?? "")" }]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return item
    }

    private func syncStatusText() -> String {
        if model.config.syncRules.filter(\.enabled).isEmpty {
            return "No sync rules — add one in Settings"
        }
        var parts: [String] = []
        if let last = model.syncLog.last {
            parts.append("Last: \(Self.timeFormatter.string(from: last.timestamp)) \(last.status) \(last.message)")
        }
        if let next = model.nextSyncAt {
            parts.append("Next: \(Self.timeFormatter.string(from: next))")
        }
        return parts.isEmpty ? "Not synced yet" : parts.joined(separator: " · ")
    }

    // MARK: - Actions

    @objc private func grantAccess() {
        Task { await model.requestAccess() }
    }

    @objc private func syncNow() {
        model.syncNow()
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openMeeting(_ sender: NSMenuItem) {
        guard let meeting = sender.representedObject as? MeetingSnapshot else { return }
        model.open(meeting)
    }

    // MARK: - Helpers

    private func item(_ title: String, _ action: Selector, key: String = "", symbol: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func disabled(_ title: String, symbol: String?, small: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if small {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
            )
        }
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    /// A small dot in the calendar's color, or a video icon in that color for meetings with a join link.
    private func calendarDot(hex: String?, video: Bool) -> NSImage? {
        let color = NSColor(hex: hex) ?? .secondaryLabelColor
        if video, let symbol = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Online meeting") {
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                .applying(.init(paletteColors: [color]))
            return symbol.withSymbolConfiguration(configuration)
        }
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 4, y: rect.midY - 4, width: 8, height: 8)).fill()
            return true
        }
    }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

extension NSColor {
    convenience init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
