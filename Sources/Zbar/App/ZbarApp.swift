import AppKit

@main
enum ZbarMain {
    static func main() {
        let app = NSApplication.shared
        app.delegate = AppDelegate.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    private var launched = false
    private var pendingURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// zbar://show | hide | toggle | all | bar | search | arrange | settings[/layout…] — for Shortcuts and scripts.
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        // Links can arrive while launching, before the status items exist.
        if launched { perform(url) } else { pendingURLs.append(url) }
    }

    private func perform(_ url: URL) {
        guard let action = url.host else { return }
        let mgr = MenuBarManager.shared
        switch action {
        case "show": mgr.reveal(trigger: .menu)
        case "hide": ZbarBar.shared.close(); mgr.hide()
        case "toggle": mgr.toggle(trigger: .menu)
        case "all": mgr.reveal(includeAlwaysHidden: true, trigger: .menu)
        case "bar": ZbarBar.shared.show(sections: [.hidden, .alwaysHidden], search: false)
        case "search": ZbarBar.shared.show(sections: Set(MenuSection.allCases), search: true)
        case "arrange": mgr.setArranging(!mgr.arranging)
        case "settings":
            let tab = SettingsTab.allCases.first { $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "") == url.lastPathComponent }
            SettingsWindow.shared.show(tab: tab)
        case "dump": mgr.writeDiagnostics()
        default: NSSound.beep()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarManager.shared.start()
        MenuBarTint.shared.start()
        launched = true
        pendingURLs.forEach(perform)
        pendingURLs = []
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            SettingsWindow.shared.show(tab: .start)
        }
    }

    /// Opening Zbar again (Finder, Spotlight) shows its settings, since it has no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }
}
