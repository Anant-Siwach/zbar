import AppKit
import SwiftUI

/// A floating bar under the menu bar that shows hidden items — the answer to icons lost behind the notch.
@MainActor
final class ZbarBar: NSObject {
    static let shared = ZbarBar()

    final class Model: ObservableObject {
        @Published var sections: Set<MenuSection> = [.hidden]
        @Published var search = false
        @Published var query = ""
    }

    let model = Model()
    private var panel: BarPanel?
    private var hosting: NSHostingView<AnyView>?
    private var monitors: [Any] = []

    var isVisible: Bool { panel?.isVisible == true }

    func show(sections: Set<MenuSection>, search: Bool) {
        model.sections = sections
        model.search = search
        model.query = ""
        let panel = self.panel ?? makePanel()
        // Match the menu bar's look so captured (white or black) icon glyphs stay readable.
        panel.appearance = MenuBarManager.shared.menuBarAppearance
        Task {
            await ItemStore.shared.refresh(images: true)
            self.resize()
        }
        resize()
        if search {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        installMonitors()
        MenuBarManager.shared.refreshIcon()
    }

    func close() {
        panel?.orderOut(nil)
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        MenuBarManager.shared.refreshIcon()
    }

    func press(_ item: MenuBarItem) {
        close()
        ItemStore.shared.press(item)
    }

    private func makePanel() -> BarPanel {
        let p = BarPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        let view = NSHostingView(rootView: AnyView(BarView(model: model, store: ItemStore.shared) { [weak self] in self?.resize() }))
        p.contentView = view
        hosting = view
        panel = p
        return p
    }

    private func resize() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        let screen = MenuBarManager.shared.iconScreen ?? NSScreen.main!
        let top = screen.frame.maxY - Geometry.barHeight(screen) - 6
        // Right-align under the Zbar icon, clamped to the screen.
        let iconMaxX = MenuBarManager.shared.iconFrame?.maxX ?? screen.frame.maxX - 12
        var x = min(iconMaxX + 8, screen.frame.maxX - 8) - size.width
        x = max(screen.frame.minX + 8, x)
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) else { return }
                // Clicking the Zbar icon toggles the bar itself; leave that to the icon.
                if let f = MenuBarManager.shared.iconFrame, f.contains(Geometry.toCG(NSEvent.mouseLocation)) { return }
                self.close()
            }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.close() }; return nil }
            return e
        } as Any)
    }
}

final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct BarView: View {
    @ObservedObject var model: ZbarBar.Model
    @ObservedObject var store: ItemStore
    let relayout: () -> Void
    @FocusState private var focused: Bool

    private var items: [MenuBarItem] {
        if model.search {
            let q = model.query.trimmingCharacters(in: .whitespaces).lowercased()
            return q.isEmpty ? store.items : store.items.filter { $0.name.lowercased().contains(q) }
        }
        return store.items(in: model.sections)
    }

    var body: some View {
        Group {
            if model.search { searchBody } else { barBody }
        }
        .modifier(GlassBackground())
        .fixedSize()
        .onChange(of: store.items.count) { _, _ in DispatchQueue.main.async(execute: relayout) }
        .onChange(of: model.query) { _, _ in DispatchQueue.main.async(execute: relayout) }
    }

    private var barBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                if items.isEmpty {
                    Text(store.loading ? "Loading…" : "No hidden items. ⌘-drag icons left of the Zbar divider to hide them.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                }
                ForEach(items) { item in
                    BarItemButton(item: item) { ZbarBar.shared.press(item) }
                }
            }
            if !Permissions.accessibility {
                PermissionHint()
            }
        }
        .padding(6)
    }

    private var searchBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search menu bar items", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { if let first = items.first { ZbarBar.shared.press(first) } }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(items) { item in
                        SearchRow(item: item) { ZbarBar.shared.press(item) }
                    }
                    if items.isEmpty {
                        Text(store.loading ? "Loading…" : "No matching items").foregroundStyle(.secondary).padding(12)
                    }
                }
                .padding(4)
            }
            .frame(height: min(CGFloat(max(items.count, 1)) * 34 + 10, 340))
            if !Permissions.accessibility { PermissionHint().padding(6) }
        }
        .frame(width: 380)
        .onAppear { focused = true }
    }
}

private struct GlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        }
    }
}

/// The item's captured image when available, else its app icon.
struct ItemGlyph: View {
    let item: MenuBarItem
    var body: some View {
        if let image = item.image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: item.frame.width, height: min(item.frame.height, 24))
        } else if let icon = item.appIcon {
            Image(nsImage: icon).resizable().frame(width: 18, height: 18).padding(.horizontal, 6)
        } else {
            Image(systemName: "questionmark.square.dashed").frame(width: 24, height: 22)
        }
    }
}

private struct BarItemButton: View {
    let item: MenuBarItem
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ItemGlyph(item: item)
                .frame(minWidth: 26, minHeight: 28)
                .padding(.horizontal, 2)
                .background(hover ? Color.primary.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(item.name)
    }
}

private struct SearchRow: View {
    let item: MenuBarItem
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ItemGlyph(item: item).frame(width: 40, height: 24)
                Text(item.name).lineLimit(1)
                Spacer()
                Text(item.section.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.primary.opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(hover ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct PermissionHint: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text("Allow Accessibility so Zbar can open these items.").font(.caption)
            Button("Allow…") { Permissions.requestAccessibility() }.controlSize(.small)
        }
        .padding(.horizontal, 6)
    }
}
