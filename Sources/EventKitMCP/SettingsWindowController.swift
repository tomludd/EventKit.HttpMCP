import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "EventKit MCP"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 700, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        model.reloadCalendars()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
