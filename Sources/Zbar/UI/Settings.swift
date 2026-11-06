import AppKit
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case start = "Get Started", general = "General", layout = "Layout", appearance = "Appearance", shortcuts = "Shortcuts", about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .start: "hand.wave.fill"
        case .general: "gearshape.fill"
        case .layout: "rectangle.split.3x1.fill"
        case .appearance: "paintpalette.fill"
        case .shortcuts: "keyboard.fill"
        case .about: "info.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .start: .orange
        case .general: .gray
        case .layout: .blue
        case .appearance: .pink
        case .shortcuts: .purple
        case .about: .teal
        }
    }
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    final class Nav: ObservableObject { @Published var tab: SettingsTab = .general }

    private let nav = Nav()
    private var window: NSWindow?

    func show(tab: SettingsTab? = nil) {
        if let tab { nav.tab = tab }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Zbar"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 700, height: 480)
            w.contentViewController = NSHostingController(rootView: SettingsView(nav: nav)
                .environmentObject(Prefs.shared)
                .environmentObject(MenuBarManager.shared)
                .environmentObject(ItemStore.shared))
            w.setContentSize(NSSize(width: 760, height: 540))
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if MenuBarManager.shared.arranging { MenuBarManager.shared.setArranging(false) }
    }
}

struct SettingsView: View {
    @ObservedObject var nav: SettingsWindow.Nav

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsTab?>(get: { nav.tab }, set: { if let t = $0 { nav.tab = t } })) {
                ForEach(SettingsTab.allCases) { tab in
                    Label {
                        Text(tab.rawValue)
                    } icon: {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(tab.color.gradient, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .tag(tab)
                }
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Group {
                switch nav.tab {
                case .start: GetStartedView()
                case .general: GeneralView()
                case .layout: LayoutView()
                case .appearance: AppearanceView()
                case .shortcuts: ShortcutsView()
                case .about: AboutView()
                }
            }
            .navigationTitle(nav.tab.rawValue)
        }
    }
}

// MARK: - Get Started

private struct GetStartedView: View {
    @State private var ax = Permissions.accessibility
    @State private var screen = Permissions.screenRecording
    @State private var askedScreen = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    AppGlyph(size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Welcome to Zbar").font(.title2.bold())
                        Text("Hide the menu bar icons you don't need, and reach every icon — even the ones stuck behind the notch.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section("How it works") {
                Step(n: 1, text: "Icons to the left of the Zbar divider ( ‹ ) are hidden. Icons to the right of the Zbar icon stay visible.")
                Step(n: 2, text: "Hold ⌘ and drag icons in the menu bar to move them between sections. Use Arrange Menu Bar to show every section while you do.")
                Step(n: 3, text: "Click the Zbar icon, click empty menu bar space, or press ⌃⌥B to show hidden items. ⌃⌥Space searches every icon.")
            }
            Section("Permissions") {
                PermissionRow(title: "Accessibility", badge: "Recommended", granted: ax,
                              detail: "Lets Zbar open hidden items from the Zbar Bar, search them, and tell which app owns each icon.") {
                    Permissions.requestAccessibility()
                }
                PermissionRow(title: "Screen Recording", badge: "Optional", granted: screen,
                              detail: "Shows each icon's real image in the Zbar Bar instead of its app icon. Zbar never records your screen.") {
                    askedScreen = true
                    Permissions.requestScreenRecording()
                }
                if askedScreen && !screen {
                    HStack {
                        Text("macOS applies Screen Recording after Zbar reopens.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Quit & Reopen") { Permissions.relaunch() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            ax = Permissions.accessibility
            screen = Permissions.screenRecording
        }
    }
}

private struct Step: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Color.accentColor, in: Circle())
            Text(text)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let badge: String
    let granted: Bool
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).bold()
                    Text(badge).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: action)
            }
        }
    }
}

// MARK: - General

private struct GeneralView: View {
    @EnvironmentObject var prefs: Prefs
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch Zbar at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
            Section("Show hidden items when I…") {
                Toggle("Click the Zbar icon", isOn: .constant(true)).disabled(true)
                Toggle("Click empty space in the menu bar", isOn: $prefs.showOnClick)
                Toggle("Hover over empty space in the menu bar", isOn: $prefs.showOnHover)
                if prefs.showOnHover {
                    LabeledContent("Hover delay") {
                        HStack {
                            Slider(value: $prefs.hoverDelay, in: 0...1, step: 0.05).frame(width: 180)
                            Text(String(format: "%.2f s", prefs.hoverDelay)).monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                    }
                }
                Toggle("Scroll on the menu bar", isOn: $prefs.showOnScroll)
            }
            Section("Hide them again") {
                Picker("Rehide", selection: $prefs.rehide) {
                    ForEach(RehideStrategy.allCases) { Text($0.title).tag($0) }
                }
                if prefs.rehide == .timed {
                    LabeledContent("Delay") {
                        HStack {
                            Slider(value: $prefs.rehideDelay, in: 3...60, step: 1).frame(width: 180)
                            Text("\(Int(prefs.rehideDelay)) s").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            Section {
                Picker("Use the Zbar Bar", selection: $prefs.barMode) {
                    ForEach(BarMode.allCases) { Text($0.title).tag($0) }
                }
                Text("The Zbar Bar shows hidden items in a bar below the menu bar. On a MacBook with a notch there is often no room to show them in the menu bar itself.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Zbar Bar") }
            Section {
                Toggle("Always-hidden section", isOn: $prefs.alwaysHiddenEnabled)
                Text("Adds a second divider. Icons left of it stay hidden until you ⌥-click the Zbar icon or open the Zbar Bar.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Sections") }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Layout

private struct LayoutView: View {
    @EnvironmentObject var store: ItemStore
    @EnvironmentObject var manager: MenuBarManager
    @EnvironmentObject var prefs: Prefs
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Arrange your menu bar").font(.headline)
                        Text("Hold ⌘ and drag icons in the menu bar. Icons left of the divider ( ‹ ) are hidden; icons right of the Zbar icon stay visible.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Arrange mode", isOn: Binding(get: { manager.arranging }, set: { manager.setArranging($0) }))
                        .toggleStyle(.switch)
                        .help("Shows every section and divider in the menu bar while you rearrange")
                }
                if !Permissions.accessibility {
                    Label("Allow Accessibility in Get Started to see which app owns each icon.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
                ForEach(MenuSection.allCases.filter { $0 != .alwaysHidden || prefs.alwaysHiddenEnabled }) { section in
                    SectionBox(section: section, items: store.items(in: [section]))
                }
                if Geometry.notch(manager.iconScreen ?? NSScreen.main!) != nil {
                    Label("This Mac has a notch. Icons that don't fit beside it are listed under Visible but hidden by macOS — move them to Hidden and open them from the Zbar Bar.",
                          systemImage: "rectangle.topthird.inset.filled")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .task { await store.refresh(images: true) }
        .onReceive(timer) { _ in Task { await store.refresh(images: true) } }
    }
}

private struct SectionBox: View {
    let section: MenuSection
    let items: [MenuBarItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(section.title).font(.subheadline.bold())
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if items.isEmpty {
                        Text("Empty").foregroundStyle(.tertiary).frame(height: 62)
                    }
                    ForEach(items) { item in
                        VStack(spacing: 4) {
                            ItemGlyph(item: item)
                                .frame(minWidth: 34, minHeight: 30)
                                .padding(.horizontal, 6)
                                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                                .environment(\.colorScheme, .dark)
                            Text(item.name).font(.caption2).lineLimit(1).frame(maxWidth: 80)
                        }
                        .help(item.name)
                        .onTapGesture { ItemStore.shared.press(item) }
                    }
                }
                .padding(10)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Appearance

private struct AppearanceView: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var store: ItemStore
    @State private var spacing = Double(ItemSpacing.read() ?? ItemSpacing.defaultValue)
    @State private var customSpacing = ItemSpacing.read() != nil

    var body: some View {
        Form {
            Section("Zbar icon") {
                Picker("Style", selection: $prefs.iconStyle) {
                    ForEach(IconStyle.allCases) { style in
                        Label(style.title, systemImage: style.symbols.0).tag(style)
                    }
                }
                Toggle("Show section dividers while items are shown", isOn: $prefs.showDividers)
            }
            Section {
                Toggle("Tint the menu bar", isOn: $prefs.tintEnabled)
                if prefs.tintEnabled {
                    ColorPicker("Color", selection: Binding(get: { Color(hex: prefs.tintColor) }, set: { prefs.tintColor = $0.hex }), supportsOpacity: false)
                    Toggle("Gradient", isOn: $prefs.tintGradient)
                    if prefs.tintGradient {
                        ColorPicker("Second color", selection: Binding(get: { Color(hex: prefs.tintColor2) }, set: { prefs.tintColor2 = $0.hex }), supportsOpacity: false)
                    }
                    LabeledContent("Strength") {
                        Slider(value: $prefs.tintOpacity, in: 0.05...1).frame(width: 200)
                    }
                    Toggle("Bottom border", isOn: $prefs.tintBorder)
                }
            } header: { Text("Menu bar tint") } footer: {
                Text("Shows through the transparent menu bar. If you turned on System Settings › Menu Bar › Show menu bar background, the tint is covered.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Custom icon spacing", isOn: $customSpacing)
                if customSpacing {
                    LabeledContent("Spacing") {
                        HStack {
                            Slider(value: $spacing, in: 0...16, step: 1).frame(width: 200)
                            Text("\(Int(spacing)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Apply…") { confirmSpacing() }
                }
            } header: { Text("Icon spacing") } footer: {
                Text("Tighter spacing fits more icons beside the notch. Applying restarts the apps that have menu bar icons so they pick it up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func confirmSpacing() {
        Task {
            await store.refresh(images: false)
            let skip: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver", Bundle.main.bundleIdentifier ?? ""]
            var seen = Set<pid_t>()
            let apps = store.items.compactMap { $0.pid }.filter { seen.insert($0).inserted }
                .compactMap(NSRunningApplication.init(processIdentifier:))
                .filter { !skip.contains($0.bundleIdentifier ?? "") && $0.bundleURL != nil }
            let alert = NSAlert()
            alert.messageText = customSpacing ? "Set icon spacing to \(Int(spacing)) pt?" : "Restore default icon spacing?"
            let names = apps.compactMap(\.localizedName).joined(separator: ", ")
            alert.informativeText = "Control Centre and these apps restart so they pick up the change: "
                + (names.isEmpty ? "(none found — other apps update the next time they open)" : names) + ". Zbar restarts too."
            alert.addButton(withTitle: "Apply & Restart Apps")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                ItemSpacing.apply(customSpacing ? Int(spacing) : nil, restarting: apps)
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsView: View {
    @EnvironmentObject var prefs: Prefs
    var body: some View {
        Form {
            Section {
                LabeledContent("Show or hide hidden items") { ShortcutRecorder(combo: $prefs.toggleKey) }
                LabeledContent("Search menu bar items") { ShortcutRecorder(combo: $prefs.searchKey) }
                LabeledContent("Show all items, including always hidden") { ShortcutRecorder(combo: $prefs.allKey) }
            } footer: {
                Text("Shortcuts work in every app. Click a shortcut, then press the new key combination; Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Type shortcut…" : (combo?.display ?? "Record Shortcut"))
                    .frame(minWidth: 120)
                    .foregroundStyle(recording ? Color.accentColor : .primary)
            }
            if combo != nil && !recording {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).help("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let mods = KeyCombo.carbon(e.modifierFlags)
            guard mods != 0 || KeyCombo.functionKeys[e.keyCode] != nil else { NSSound.beep(); return nil }
            combo = KeyCombo(keyCode: Int(e.keyCode), modifiers: mods, key: KeyCombo.keyName(e))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - About

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            AppGlyph(size: 96)
            Text("Zbar").font(.largeTitle.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .foregroundStyle(.secondary)
            Text("A menu bar manager. No subscription, no account, no tracking.")
            Spacer()
            HStack {
                Button("Show Welcome") { SettingsWindow.shared.show(tab: .start) }
                Button("Quit Zbar") { NSApp.terminate(nil) }
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppGlyph: View {
    var size: CGFloat
    var body: some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        }
    }
}
