import AppKit
import Combine
import SwiftUI

/// Tints the menu bar by placing a click-through window just beneath it
/// (macOS 26's menu bar is transparent, so the tint shows through).
@MainActor
final class MenuBarTint {
    static let shared = MenuBarTint()
    private var windows: [NSWindow] = []
    private var bag = Set<AnyCancellable>()

    func start() {
        Prefs.shared.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.update() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.update() }
            .store(in: &bag)
        update()
    }

    func update() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        let p = Prefs.shared
        guard p.tintEnabled else { return }
        for screen in NSScreen.screens {
            guard Geometry.menuBarHeight(screen) > 0 else { continue } // auto-hidden menu bar
            let h = Geometry.barHeight(screen)
            let w = TintWindow(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.contentView = NSHostingView(rootView: TintView(
                c1: Color(hex: p.tintColor), c2: Color(hex: p.tintColor2),
                gradient: p.tintGradient, opacity: p.tintOpacity, border: p.tintBorder))
            w.orderFrontRegardless()
            windows.append(w)
        }
    }
}

/// AppKit normally pushes windows below the menu bar; the tint has to sit behind it.
private final class TintWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct TintView: View {
    let c1: Color, c2: Color
    let gradient: Bool
    let opacity: Double
    let border: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(gradient ? AnyShapeStyle(LinearGradient(colors: [c1, c2], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(c1))
                .opacity(opacity)
            if border {
                Rectangle().fill(.white.opacity(0.28)).frame(height: 1)
            }
        }
        .ignoresSafeArea()
    }
}

/// Menu bar item spacing (the system-wide NSStatusItemSpacing default). Tighter spacing fits more icons beside the notch.
enum ItemSpacing {
    static let defaultValue = 16

    static func read() -> Int? {
        let r = Shell.run("/usr/bin/defaults", ["-currentHost", "read", "-globalDomain", "NSStatusItemSpacing"])
        return r.ok ? Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    /// Writes the setting (nil restores the default) and restarts apps so they pick it up.
    static func apply(_ value: Int?, restarting apps: [NSRunningApplication]) {
        for key in ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"] {
            if let value {
                let v = key == "NSStatusItemSpacing" ? value : max(2, value / 2 + 2)
                Shell.run("/usr/bin/defaults", ["-currentHost", "write", "-globalDomain", key, "-int", String(v)])
            } else {
                Shell.run("/usr/bin/defaults", ["-currentHost", "delete", "-globalDomain", key])
            }
        }
        // System items restart on their own when killed.
        Shell.run("/usr/bin/killall", ["ControlCenter"])
        Shell.run("/usr/bin/killall", ["SystemUIServer"])
        Task.detached {
            for app in apps {
                guard let url = app.bundleURL else { continue }
                app.terminate()
                for _ in 0..<30 where !app.isTerminated { try? await Task.sleep(nanoseconds: 100_000_000) }
                guard app.isTerminated else { continue }
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            }
            await MainActor.run { Permissions.relaunch() }
        }
    }
}
