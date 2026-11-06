import AppKit
import ApplicationServices

enum Permissions {
    /// Needed to click hidden items, search them and tell which app owns each icon.
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { openSettings("Privacy_Accessibility") }
    }

    /// Optional: lets the Zbar Bar show the real icon images.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { openSettings("Privacy_ScreenCapture") }
    }

    static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

enum Shell {
    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (false, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}

/// Coordinate helpers. AppKit uses bottom-left origin; CoreGraphics / Accessibility use top-left.
enum Geometry {
    static var primaryMaxY: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func toCG(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }

    static func toCG(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryMaxY - p.y) }

    static func screen(containing p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    /// Height of the menu bar on `screen` (0 when it is auto-hidden).
    static func menuBarHeight(_ screen: NSScreen) -> CGFloat {
        screen.frame.maxY - screen.visibleFrame.maxY
    }

    static func barHeight(_ screen: NSScreen) -> CGFloat {
        // On notched screens the bar is one point taller than the safe area / visible-frame gap.
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top + 1 }
        let h = menuBarHeight(screen)
        return h > 0 ? h : NSStatusBar.system.thickness
    }

    /// True when the (AppKit) point is inside the menu bar strip of its screen.
    static func isInMenuBar(_ p: NSPoint) -> Bool {
        guard let s = screen(containing: p) else { return false }
        return p.y >= s.frame.maxY - barHeight(s)
    }

    /// The notch's horizontal extent in global x, if the screen has one.
    static func notch(_ screen: NSScreen) -> ClosedRange<CGFloat>? {
        guard let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else { return nil }
        let offset = l.minX < screen.frame.minX ? screen.frame.minX : 0
        return (l.maxX + offset)...(r.minX + offset)
    }
}

/// A menu bar item window as reported by the window server.
struct StatusWindow {
    let id: CGWindowID
    let frame: CGRect // CG coordinates
}

enum WindowList {
    static let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
    static let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

    private static func list(_ options: CGWindowListOption) -> [[String: Any]] {
        (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private static func frame(_ w: [String: Any]) -> CGRect? {
        guard let b = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: b)
    }

    /// Every menu bar item window, including ones pushed off screen by a collapsed divider.
    static func statusWindows() -> [StatusWindow] {
        list([.optionAll, .excludeDesktopElements]).compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == statusLevel, let f = frame(w),
                  f.width > 0, f.width < 600, f.height > 10, f.height < 60,
                  let id = w[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return StatusWindow(id: id, frame: f)
        }
    }

    /// True while a menu or popover hangs below the menu bar (e.g. an item's menu is open).
    static func menuIsOpen() -> Bool {
        let barH = NSScreen.screens.first.map(Geometry.barHeight) ?? 24
        for w in list([.optionOnScreenOnly, .excludeDesktopElements]) {
            guard let layer = w[kCGWindowLayer as String] as? Int, let f = frame(w) else { continue }
            if (w[kCGWindowOwnerPID as String] as? pid_t) == getpid() { continue }
            if layer == popUpLevel { return true }
            // Popovers and Control Centre modules start just below the menu bar.
            if layer >= statusLevel, layer < 1000, f.height > 40, f.minY >= barH - 2, f.minY <= barH + 14 { return true }
        }
        return false
    }
}
