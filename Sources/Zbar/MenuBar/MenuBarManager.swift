import AppKit
import Combine

/// Owns Zbar's three status items and decides when hidden items are shown.
///
/// Layout, right to left: [visible items] [Zbar icon] [hidden divider] [hidden items] [always-hidden divider] [always-hidden items].
/// A divider "collapses" by growing to 10,000 pt, which pushes every item to its left off the screen.
@MainActor
final class MenuBarManager: NSObject, ObservableObject {
    static let shared = MenuBarManager()
    static let collapsedLength: CGFloat = 10_000

    enum Trigger { case click, hover, scroll, hotkey, menu }

    @Published private(set) var hiddenShown = false
    @Published private(set) var alwaysHiddenShown = false
    @Published private(set) var arranging = false

    private var icon: NSStatusItem!
    private var hiddenDivider: NSStatusItem!
    private var alwaysDivider: NSStatusItem?
    private let prefs = Prefs.shared
    private var bag = Set<AnyCancellable>()
    private var monitors: [Any] = []
    private var hotkeys: [HotKey] = []
    private var rehideTimer: Timer?
    private var tickTimer: Timer?
    private var menuWatch: Timer?
    private var shownBy: Trigger?
    private var hoverStart: Date?
    private var lastInMenuBar = Date.distantPast
    private var lastMenuBarClick = Date.distantPast
    private var temporary: (hidden: Bool, always: Bool)?

    // MARK: Setup

    func start() {
        seedPositions()
        icon = makeItem("ZbarIcon")
        icon.button?.target = self
        icon.button?.action = #selector(iconClicked)
        icon.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        icon.button?.toolTip = "Zbar — click to show hidden items, right-click for options"

        hiddenDivider = makeItem("ZbarHidden")
        configureDivider(hiddenDivider)
        updateAlwaysDivider()

        prefs.$alwaysHiddenEnabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateAlwaysDivider() }
        }.store(in: &bag)
        Publishers.Merge(prefs.$iconStyle.map { _ in () }, prefs.$showDividers.map { _ in () })
            .dropFirst(2).sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }.store(in: &bag)
        Publishers.Merge3(prefs.$toggleKey, prefs.$searchKey, prefs.$allKey)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotkeys() } }.store(in: &bag)

        installMonitors()
        apply()
    }

    /// New status items appear at the far left; give ours a starting spot beside the system items instead.
    private func seedPositions() {
        let d = UserDefaults.standard
        for (name, pos) in [("ZbarIcon", 0.0), ("ZbarHidden", 1.0)] {
            let key = "NSStatusItem Preferred Position \(name)"
            if d.object(forKey: key) == nil { d.set(pos, forKey: key) }
        }
    }

    private func makeItem(_ name: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = name
        item.behavior = [] // can't be dragged out of the menu bar
        item.isVisible = true
        return item
    }

    private func configureDivider(_ item: NSStatusItem) {
        item.button?.target = self
        item.button?.action = #selector(dividerClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "Zbar divider — ⌘-drag icons to the left of this to hide them"
    }

    private func updateAlwaysDivider() {
        if prefs.alwaysHiddenEnabled, alwaysDivider == nil {
            // The first time, start the divider at the far left so nothing becomes always-hidden by surprise.
            let d = UserDefaults.standard
            if !d.bool(forKey: "alwaysHiddenPlaced") {
                d.set(5000.0, forKey: "NSStatusItem Preferred Position ZbarAlwaysHidden")
                d.set(true, forKey: "alwaysHiddenPlaced")
            }
            let item = makeItem("ZbarAlwaysHidden")
            configureDivider(item)
            alwaysDivider = item
        } else if !prefs.alwaysHiddenEnabled, let item = alwaysDivider {
            NSStatusBar.system.removeStatusItem(item)
            alwaysDivider = nil
            alwaysHiddenShown = false
        }
        apply()
    }

    // MARK: Geometry

    var ownWindowIDs: Set<CGWindowID> {
        Set([icon, hiddenDivider, alwaysDivider].compactMap { $0?.button?.window?.windowNumber }.compactMap { CGWindowID(exactly: $0) })
    }

    var ownFrames: [CGRect] {
        [icon, hiddenDivider, alwaysDivider].compactMap { $0?.button?.window?.frame }.map(Geometry.toCG)
    }

    var iconFrame: CGRect? { icon?.button?.window.map { Geometry.toCG($0.frame) } }
    var iconScreen: NSScreen? { icon?.button?.window?.screen ?? NSScreen.screens.first }
    var menuBarAppearance: NSAppearance? { icon?.button?.effectiveAppearance }

    /// Right edge (CG x) of the hidden divider: everything left of it is hidden.
    private var hiddenEdge: CGFloat? { hiddenDivider?.button?.window.map { Geometry.toCG($0.frame).maxX } }
    private var alwaysEdge: CGFloat? { alwaysDivider?.button?.window.map { Geometry.toCG($0.frame).maxX } }

    func section(of frame: CGRect) -> MenuSection {
        if let a = alwaysEdge, frame.midX < a { return .alwaysHidden }
        if let h = hiddenEdge, frame.midX < h { return .hidden }
        return .visible
    }

    /// Writes the current layout to $TMPDIR/zbar-diagnostics.txt (zbar://dump), for troubleshooting.
    func writeDiagnostics() {
        var lines = ["hiddenShown=\(hiddenShown) always=\(alwaysHiddenShown) arranging=\(arranging) iconVisible=\(iconIsOnScreen)",
                     "own ids=\(ownWindowIDs.sorted()) frames=\(ownFrames)",
                     "button=\(icon?.button != nil) num=\(icon?.button?.window?.windowNumber ?? -1) frame=\(String(describing: icon?.button?.window?.frame)) screen=\(String(describing: icon?.button?.window?.screen?.frame))",
                     "divider window=\(String(describing: hiddenDivider?.button?.window?.frame)) length=\(hiddenDivider?.length ?? -1)"]
        for (w, s) in ItemStore.shared.layout() { lines.append("\(w.id) \(s.rawValue) \(w.frame)") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zbar-diagnostics.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// False when macOS has dropped the Zbar icon because the menu bar is full (or it sits behind the notch).
    var iconIsOnScreen: Bool {
        guard let window = icon?.button?.window else { return false }
        let frame = Geometry.toCG(window.frame)
        guard let w = WindowList.statusWindows().first(where: {
            (abs($0.frame.maxX - frame.maxX) < 1.5 && abs($0.frame.width - frame.width) < 1.5)
        }) else { return false }
        if let screen = iconScreen, let notch = Geometry.notch(screen), w.frame.minX < notch.upperBound { return false }
        return w.frame.minX >= (iconScreen?.frame.minX ?? 0)
    }

    // MARK: Showing and hiding

    private func apply() {
        guard icon != nil else { return }
        let dividers = prefs.showDividers || arranging
        let shownLength = dividers ? NSStatusItem.variableLength : 0
        hiddenDivider.length = hiddenShown ? shownLength : Self.collapsedLength
        hiddenDivider.button?.image = hiddenShown && dividers ? Self.dividerImage : nil
        if let a = alwaysDivider {
            a.length = alwaysHiddenShown ? shownLength : Self.collapsedLength
            a.button?.image = alwaysHiddenShown && dividers ? Self.alwaysDividerImage : nil
        }
        let (off, on) = prefs.iconStyle.symbols
        let img = NSImage(systemSymbolName: hiddenShown || ZbarBar.shared.isVisible ? on : off, accessibilityDescription: "Zbar")
        img?.isTemplate = true
        icon.button?.image = img?.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
    }

    func refreshIcon() { apply() }

    private static let dividerImage: NSImage? = {
        let img = NSImage(systemSymbolName: "chevron.compact.left", accessibilityDescription: "Hidden section")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        img?.isTemplate = true
        return img
    }()

    private static let alwaysDividerImage: NSImage? = {
        let img = NSImage(systemSymbolName: "chevron.compact.left", accessibilityDescription: "Always-hidden section")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .ultraLight))
        img?.isTemplate = true
        return img
    }()

    private func setShown(hidden: Bool, always: Bool) {
        hiddenShown = hidden || always
        alwaysHiddenShown = always && alwaysDivider != nil
        apply()
    }

    func toggle(includeAlwaysHidden: Bool = false, trigger: Trigger) {
        if ZbarBar.shared.isVisible { ZbarBar.shared.close(); return }
        if hiddenShown && !(includeAlwaysHidden && !alwaysHiddenShown && alwaysDivider != nil) {
            hide()
        } else {
            reveal(includeAlwaysHidden: includeAlwaysHidden, trigger: trigger)
        }
    }

    func reveal(includeAlwaysHidden: Bool = false, trigger: Trigger) {
        if shouldUseBar(includeAlwaysHidden: includeAlwaysHidden) {
            let sections: Set<MenuSection> = includeAlwaysHidden ? [.hidden, .alwaysHidden] : [.hidden]
            ZbarBar.shared.show(sections: sections, search: false)
            return
        }
        setShown(hidden: true, always: includeAlwaysHidden)
        shownBy = trigger
        scheduleRehide()
        verifyIconStillVisible(includeAlwaysHidden: includeAlwaysHidden)
    }

    /// macOS drops status items that don't fit (the notch makes this common). If revealing pushed the
    /// Zbar icon out, fall back to the Zbar Bar so the user is never left without a way back.
    private func verifyIconStillVisible(includeAlwaysHidden: Bool, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.hiddenShown, !self.arranging, self.temporary == nil, !self.iconIsOnScreen else { return }
            if attempt == 0 { self.verifyIconStillVisible(includeAlwaysHidden: includeAlwaysHidden, attempt: 1); return }
            guard self.prefs.barMode != .never else { return }
            self.setShown(hidden: false, always: false)
            self.shownBy = nil
            ZbarBar.shared.show(sections: includeAlwaysHidden ? [.hidden, .alwaysHidden] : [.hidden], search: false)
        }
    }

    func hide() {
        guard !arranging else { return }
        rehideTimer?.invalidate()
        shownBy = nil
        setShown(hidden: false, always: false)
    }

    func setArranging(_ on: Bool) {
        arranging = on
        if on {
            rehideTimer?.invalidate()
            setShown(hidden: true, always: true)
        } else {
            setShown(hidden: false, always: false)
        }
    }

    /// Whether hidden items should open in the Zbar Bar instead of expanding in place.
    private func shouldUseBar(includeAlwaysHidden: Bool) -> Bool {
        switch prefs.barMode {
        case .always: return true
        case .never: return false
        case .auto:
            let wanted: Set<MenuSection> = includeAlwaysHidden ? [.hidden, .alwaysHidden] : [.hidden]
            let needed = ItemStore.shared.layout().filter { wanted.contains($0.1) }.reduce(0) { $0 + $1.0.frame.width }
            guard needed > 0, let edge = hiddenEdge, let screen = iconScreen else { return false }
            let leftLimit: CGFloat
            if let notch = Geometry.notch(screen) {
                leftLimit = notch.upperBound
            } else if Permissions.accessibility, let menus = AXScanner.appMenusMaxX() {
                leftLimit = menus + 12
            } else {
                leftLimit = screen.frame.minX + screen.frame.width * 0.45
            }
            // macOS keeps a margin beside the notch / app menus, and the shown divider needs room too.
            return needed + 60 > edge - leftLimit
        }
    }

    // MARK: Temporary reveal (opening an item from the Zbar Bar)

    func beginTemporaryReveal(includeAlwaysHidden: Bool) {
        if temporary == nil { temporary = (hiddenShown, alwaysHiddenShown) }
        rehideTimer?.invalidate()
        setShown(hidden: true, always: includeAlwaysHidden || alwaysHiddenShown)
    }

    /// Polls until the item's menu or popover has closed, then restores the previous state.
    func watchMenuThenRehide() {
        menuWatch?.invalidate()
        let started = Date()
        var seen = false
        var closedAt: Date?
        menuWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let open = WindowList.menuIsOpen()
                if open { seen = true; closedAt = nil } else if closedAt == nil { closedAt = Date() }
                let elapsed = Date().timeIntervalSince(started)
                let done = (seen && !open && Date().timeIntervalSince(closedAt ?? Date()) > 0.3)
                    || (!seen && elapsed > 3) || elapsed > 300
                if done {
                    t.invalidate()
                    self.endTemporaryReveal()
                }
            }
        }
    }

    private func endTemporaryReveal() {
        guard let prev = temporary else { return }
        temporary = nil
        if !arranging { setShown(hidden: prev.hidden, always: prev.always) }
    }

    // MARK: Rehide

    private func scheduleRehide() {
        rehideTimer?.invalidate()
        guard !arranging, prefs.rehide == .timed else { return }
        rehideTimer = Timer.scheduledTimer(withTimeInterval: max(2, prefs.rehideDelay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timedRehide() }
        }
    }

    private func timedRehide() {
        guard hiddenShown, temporary == nil else { return }
        if Geometry.isInMenuBar(NSEvent.mouseLocation) || WindowList.menuIsOpen() {
            rehideTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.timedRehide() }
            }
        } else {
            hide()
        }
    }

    private var canAutoHide: Bool { hiddenShown && !arranging && temporary == nil }

    // MARK: Event monitors

    private func installMonitors() {
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.globalMouseDown() }
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            MainActor.assumeIsolated { self?.scrolled(e) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            MainActor.assumeIsolated { self?.scrolled(e) }
            return e
        } as Any)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activeAppChanged(app) }
        }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func isEmptySpace(_ p: NSPoint) -> Bool {
        let cg = Geometry.toCG(p)
        if Permissions.accessibility, let empty = AXScanner.isEmptyMenuBar(at: cg) { return empty }
        // Without Accessibility: right of the notch (or of the screen middle) and not over an icon.
        guard let screen = Geometry.screen(containing: p) else { return false }
        let limit = Geometry.notch(screen)?.upperBound ?? (screen.frame.minX + screen.frame.width * 0.5)
        guard cg.x > limit else { return false }
        let own = ownWindowIDs
        return !WindowList.statusWindows().contains { !own.contains($0.id) && $0.frame.contains(cg) }
    }

    private func globalMouseDown() {
        let p = NSEvent.mouseLocation
        if Geometry.isInMenuBar(p) {
            lastMenuBarClick = Date()
            if prefs.showOnClick, !ZbarBar.shared.isVisible, isEmptySpace(p) { toggle(trigger: .click) }
        } else if prefs.rehide == .smart, canAutoHide {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.canAutoHide else { return }
                self.hide()
            }
        }
    }

    private func scrolled(_ e: NSEvent) {
        guard prefs.showOnScroll, Geometry.isInMenuBar(NSEvent.mouseLocation), abs(e.scrollingDeltaY) > 1.5 else { return }
        if e.scrollingDeltaY > 0, !hiddenShown, !ZbarBar.shared.isVisible {
            reveal(trigger: .scroll)
        } else if e.scrollingDeltaY < 0 {
            if ZbarBar.shared.isVisible { ZbarBar.shared.close() } else if hiddenShown { hide() }
        }
    }

    private func activeAppChanged(_ app: NSRunningApplication?) {
        guard app?.processIdentifier != getpid(), canAutoHide,
              prefs.rehide == .smart || prefs.rehide == .focusedApp else { return }
        // Opening a hidden item's popover often activates its app; don't hide right under it.
        if Date().timeIntervalSince(lastMenuBarClick) < 2 || WindowList.menuIsOpen() { return }
        hide()
    }

    private func tick() {
        let p = NSEvent.mouseLocation
        let inBar = Geometry.isInMenuBar(p)
        if inBar { lastInMenuBar = Date() }

        if prefs.showOnHover, inBar, !hiddenShown, !ZbarBar.shared.isVisible, NSEvent.pressedMouseButtons == 0 {
            if isEmptySpace(p) {
                hoverStart = hoverStart ?? Date()
                if Date().timeIntervalSince(hoverStart!) >= prefs.hoverDelay {
                    hoverStart = nil
                    reveal(trigger: .hover)
                }
            } else {
                hoverStart = nil
            }
        } else {
            hoverStart = nil
        }

        // Shown by hovering: hide again once the pointer has left the menu bar for a moment.
        if shownBy == .hover, prefs.rehide == .smart, canAutoHide, !inBar,
           Date().timeIntervalSince(lastInMenuBar) > 0.7, !WindowList.menuIsOpen() {
            hide()
        }
    }

    // MARK: Hotkeys

    private func registerHotkeys() {
        hotkeys = []
        if let k = prefs.toggleKey {
            hotkeys.append(HotKey(keyCode: k.keyCode, modifiers: k.modifiers) { [weak self] in
                MainActor.assumeIsolated { self?.toggle(trigger: .hotkey) }
            })
        }
        if let k = prefs.allKey {
            hotkeys.append(HotKey(keyCode: k.keyCode, modifiers: k.modifiers) { [weak self] in
                MainActor.assumeIsolated { self?.toggle(includeAlwaysHidden: true, trigger: .hotkey) }
            })
        }
        if let k = prefs.searchKey {
            hotkeys.append(HotKey(keyCode: k.keyCode, modifiers: k.modifiers) {
                MainActor.assumeIsolated {
                    if ZbarBar.shared.isVisible { ZbarBar.shared.close() } else { ZbarBar.shared.show(sections: Set(MenuSection.allCases), search: true) }
                }
            })
        }
    }

    // MARK: Clicks on our own items

    @objc private func iconClicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            showMenu()
            return
        }
        toggle(includeAlwaysHidden: e?.modifierFlags.contains(.option) == true, trigger: .click)
    }

    @objc private func dividerClicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp { showMenu(); return }
        // A collapsed divider fills the empty menu bar space, so a click on it is a click on empty space.
        if hiddenShown { hide() } else if prefs.showOnClick { toggle(trigger: .click) }
    }

    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        add(hiddenShown ? "Hide Items" : "Show Hidden Items", #selector(menuToggle))
        if alwaysDivider != nil { add("Show All Items", #selector(menuShowAll)) }
        add("Open Zbar Bar", #selector(menuBar))
        add("Search Menu Bar Items…", #selector(menuSearch))
        menu.addItem(.separator())
        add(arranging ? "Done Arranging" : "Arrange Menu Bar…", #selector(menuArrange))
        add("Settings…", #selector(menuSettings), ",")
        menu.addItem(.separator())
        add("Quit Zbar", #selector(menuQuit), "q")
        icon.menu = menu
        icon.button?.performClick(nil)
        icon.menu = nil
    }

    @objc private func menuToggle() { hiddenShown ? hide() : reveal(trigger: .menu) }
    @objc private func menuShowAll() { reveal(includeAlwaysHidden: true, trigger: .menu) }
    @objc private func menuBar() { ZbarBar.shared.show(sections: [.hidden, .alwaysHidden], search: false) }
    @objc private func menuSearch() { ZbarBar.shared.show(sections: Set(MenuSection.allCases), search: true) }
    @objc private func menuArrange() {
        setArranging(!arranging)
        if arranging { SettingsWindow.shared.show(tab: .layout) }
    }
    @objc private func menuSettings() { SettingsWindow.shared.show() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}
