import AppKit
import ApplicationServices
import ScreenCaptureKit

enum MenuSection: String, CaseIterable, Identifiable {
    case visible, hidden, alwaysHidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always Hidden"
        }
    }
}

/// One icon in the menu bar, joined from the window server (position) and Accessibility (owner, title).
struct MenuBarItem: Identifiable {
    let id: CGWindowID
    let frame: CGRect
    let section: MenuSection
    let pid: pid_t?
    let appName: String
    let bundleID: String?
    let title: String
    let appIcon: NSImage?
    let element: AXUIElement?
    var image: NSImage?

    var name: String {
        if title.isEmpty || title == appName { return appName }
        return appName.isEmpty ? title : "\(appName) — \(title)"
    }
}

/// A menu bar extra found through Accessibility.
struct AXItem {
    let pid: pid_t
    let frame: CGRect
    let title: String
    let element: AXUIElement
}

enum AXScanner {
    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func frame(of el: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv: AXValue = attr(el, kAXPositionAttribute), let sv: AXValue = attr(el, kAXSizeAttribute),
              AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Walks each app's "extras" menu bar (its status items). On macOS 26 the window server reports
    /// every item as owned by Control Centre, so this is the only reliable way to find the real owner.
    static func scan(pids: [pid_t]) -> [AXItem] {
        let lock = NSLock()
        var out: [AXItem] = []
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let pid = pids[i]
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            guard let bar: AXUIElement = attr(app, "AXExtrasMenuBar"),
                  let kids: [AXUIElement] = attr(bar, kAXChildrenAttribute) else { return }
            var found: [AXItem] = []
            for k in kids {
                guard let f = frame(of: k) else { continue }
                let title = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXIdentifierAttribute]
                    .lazy.compactMap { (attr(k, $0) as String?)?.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty } ?? ""
                found.append(AXItem(pid: pid, frame: f, title: title, element: k))
            }
            lock.lock(); out += found; lock.unlock()
        }
        return out
    }

    /// Right edge of the frontmost app's menus (used to measure free menu bar space without a notch).
    static func appMenusMaxX() -> CGFloat? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let bar: AXUIElement = attr(app, kAXMenuBarAttribute),
              let kids: [AXUIElement] = attr(bar, kAXChildrenAttribute) else { return nil }
        return kids.compactMap(frame(of:)).map(\.maxX).max()
    }

    /// Whether the (CG) point is empty menu bar space rather than a menu title or an icon.
    static func isEmptyMenuBar(at p: CGPoint) -> Bool? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success,
              let el else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        if pid == getpid() { return true } // our collapsed divider fills the empty space
        let role: String? = attr(el, kAXRoleAttribute)
        return role == (kAXMenuBarRole as String)
    }

    /// Presses an item. AXPress can block until the item's menu closes, so it runs off the main thread.
    static func press(_ el: AXUIElement, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            AXUIElementSetMessagingTimeout(el, 0.6)
            let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
            // A timeout means the app is busy running the menu it just opened.
            let ok = err == .success || err == .cannotComplete
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

enum ItemImager {
    /// Captures menu bar item windows (needs Screen Recording). Blank captures are dropped.
    static func capture(_ items: [(CGWindowID, CGRect)], scale: CGFloat) async -> [CGWindowID: NSImage] {
        guard Permissions.screenRecording, !items.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return [:] }
        var byID: [CGWindowID: SCWindow] = [:]
        for w in content.windows { byID[w.windowID] = w }
        var out: [CGWindowID: NSImage] = [:]
        for (id, frame) in items {
            guard let w = byID[id] else { continue }
            let cfg = SCStreamConfiguration()
            cfg.width = max(1, Int(frame.width * scale))
            cfg.height = max(1, Int(frame.height * scale))
            cfg.showsCursor = false
            cfg.captureResolution = .best
            cfg.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: w)
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg), !isBlank(img) {
                out[id] = NSImage(cgImage: img, size: frame.size)
            }
        }
        return out
    }

    private static func isBlank(_ img: CGImage) -> Bool {
        let w = max(1, img.width / 2), h = max(1, img.height / 2)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return !stride(from: 3, to: px.count, by: 4).contains { px[$0] > 24 }
    }
}

/// The current list of menu bar items, sorted left to right.
@MainActor
final class ItemStore: ObservableObject {
    static let shared = ItemStore()
    @Published private(set) var items: [MenuBarItem] = []
    @Published private(set) var loading = false
    private var imageCache: [CGWindowID: NSImage] = [:]

    func items(in sections: Set<MenuSection>) -> [MenuBarItem] { items.filter { sections.contains($0.section) } }

    /// Window positions and sections only; cheap and needs no permission.
    func layout() -> [(StatusWindow, MenuSection)] {
        let mgr = MenuBarManager.shared
        let own = mgr.ownWindowIDs
        let ownFrames = mgr.ownFrames
        guard let barY = mgr.iconFrame?.minY else { return [] }
        return WindowList.statusWindows()
            .filter { w in
                !own.contains(w.id) && abs(w.frame.minY - barY) < 4
                    && !ownFrames.contains { abs($0.maxX - w.frame.maxX) < 1.5 && abs($0.width - w.frame.width) < 1.5 }
            }
            .map { ($0, mgr.section(of: $0.frame)) }
            .sorted { $0.0.frame.minX < $1.0.frame.minX }
    }

    func refresh(images wantImages: Bool = true) async {
        loading = true
        defer { loading = false }
        let windows = layout()
        var ax: [AXItem] = []
        if Permissions.accessibility {
            let me = getpid()
            let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier).filter { $0 != me }
            ax = await Task.detached { AXScanner.scan(pids: pids) }.value
        }
        var result: [MenuBarItem] = windows.map { w, section in
            let match = ax.first { abs($0.frame.minX - w.frame.minX) < 3 && abs($0.frame.width - w.frame.width) < 3 }
            let app = match.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
            return MenuBarItem(id: w.id, frame: w.frame, section: section, pid: match?.pid,
                               appName: app?.localizedName ?? (match == nil ? "Menu Bar Item" : ""),
                               bundleID: app?.bundleIdentifier, title: match?.title ?? "",
                               appIcon: app?.icon, element: match?.element, image: imageCache[w.id])
        }
        items = result
        guard wantImages, Permissions.screenRecording else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let shots = await ItemImager.capture(result.map { ($0.id, $0.frame) }, scale: scale)
        imageCache = shots.merging(imageCache.filter { k, _ in result.contains { $0.id == k } }) { new, _ in new }
        for i in result.indices { result[i].image = imageCache[result[i].id] }
        items = result
    }

    /// Opens an item: reveals its section for a moment, presses it, then hides again once its menu closes.
    func press(_ item: MenuBarItem) {
        guard Permissions.accessibility else {
            Permissions.requestAccessibility()
            return
        }
        let mgr = MenuBarManager.shared
        mgr.beginTemporaryReveal(includeAlwaysHidden: item.section == .alwaysHidden)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let element = item.element ?? self.findElement(for: item)
            let fallback = { [weak self] in
                if !(self?.click(item) ?? false) { NSSound.beep() }
                mgr.watchMenuThenRehide()
            }
            guard let element else { fallback(); return }
            AXScanner.press(element) { ok in ok ? mgr.watchMenuThenRehide() : fallback() }
        }
    }

    private func findElement(for item: MenuBarItem) -> AXUIElement? {
        guard let pid = item.pid else { return nil }
        return AXScanner.scan(pids: [pid]).first { $0.title == item.title }?.element
    }

    /// Synthesises a click at the item's revealed position (fallback when AXPress isn't supported).
    private func click(_ item: MenuBarItem) -> Bool {
        guard let w = WindowList.statusWindows().first(where: { $0.id == item.id }), w.frame.minX >= 0 else { return false }
        if let screen = NSScreen.screens.first, let notch = Geometry.notch(screen), notch.contains(w.frame.midX) { return false }
        let p = CGPoint(x: w.frame.midX, y: w.frame.midY)
        let src = CGEventSource(stateID: .hidSystemState)
        let saved = CGEvent(source: nil)?.location
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        if let saved { CGWarpMouseCursorPosition(saved) }
        return true
    }
}
