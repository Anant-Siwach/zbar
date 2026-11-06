import AppKit
import Carbon
import SwiftUI

enum RehideStrategy: String, CaseIterable, Identifiable {
    case smart, timed, focusedApp, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: "Smart (click elsewhere or move away)"
        case .timed: "After a delay"
        case .focusedApp: "When the active app changes"
        case .never: "Never"
        }
    }
}

enum BarMode: String, CaseIterable, Identifiable {
    case auto, always, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "When items don't fit"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

enum IconStyle: String, CaseIterable, Identifiable {
    case z, dots, chevron, stack, filter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .z: "Zbar"
        case .dots: "Dots"
        case .chevron: "Chevron"
        case .stack: "Stack"
        case .filter: "Lines"
        }
    }
    /// (hidden, shown) symbol names.
    var symbols: (String, String) {
        switch self {
        case .z: ("z.circle", "z.circle.fill")
        case .dots: ("ellipsis.circle", "ellipsis.circle.fill")
        case .chevron: ("chevron.left", "chevron.right")
        case .stack: ("square.stack.3d.up", "square.stack.3d.up.fill")
        case .filter: ("line.3.horizontal.decrease.circle", "line.3.horizontal.decrease.circle.fill")
        }
    }
}

/// A global keyboard shortcut, stored with Carbon key code and modifiers.
struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    var key: String

    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + key
    }

    static func carbon(_ flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return m
    }

    static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]

    static func keyName(_ event: NSEvent) -> String {
        if let f = functionKeys[event.keyCode] { return f }
        switch event.keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// App settings, persisted in UserDefaults and observable from SwiftUI.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var showOnClick: Bool { didSet { d.set(showOnClick, forKey: "showOnClick") } }
    @Published var showOnHover: Bool { didSet { d.set(showOnHover, forKey: "showOnHover") } }
    @Published var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var showOnScroll: Bool { didSet { d.set(showOnScroll, forKey: "showOnScroll") } }
    @Published var rehide: RehideStrategy { didSet { d.set(rehide.rawValue, forKey: "rehide") } }
    @Published var rehideDelay: Double { didSet { d.set(rehideDelay, forKey: "rehideDelay") } }
    @Published var barMode: BarMode { didSet { d.set(barMode.rawValue, forKey: "barMode") } }
    @Published var alwaysHiddenEnabled: Bool { didSet { d.set(alwaysHiddenEnabled, forKey: "alwaysHiddenEnabled") } }
    @Published var iconStyle: IconStyle { didSet { d.set(iconStyle.rawValue, forKey: "iconStyle") } }
    @Published var showDividers: Bool { didSet { d.set(showDividers, forKey: "showDividers") } }

    @Published var tintEnabled: Bool { didSet { d.set(tintEnabled, forKey: "tintEnabled") } }
    @Published var tintColor: String { didSet { d.set(tintColor, forKey: "tintColor") } }
    @Published var tintColor2: String { didSet { d.set(tintColor2, forKey: "tintColor2") } }
    @Published var tintGradient: Bool { didSet { d.set(tintGradient, forKey: "tintGradient") } }
    @Published var tintOpacity: Double { didSet { d.set(tintOpacity, forKey: "tintOpacity") } }
    @Published var tintBorder: Bool { didSet { d.set(tintBorder, forKey: "tintBorder") } }

    @Published var toggleKey: KeyCombo? { didSet { save(toggleKey, "toggleKey") } }
    @Published var searchKey: KeyCombo? { didSet { save(searchKey, "searchKey") } }
    @Published var allKey: KeyCombo? { didSet { save(allKey, "allKey") } }

    private init() {
        d.register(defaults: [
            "showOnClick": true, "showOnHover": false, "hoverDelay": 0.25, "showOnScroll": false,
            "rehide": RehideStrategy.smart.rawValue, "rehideDelay": 15.0, "barMode": BarMode.auto.rawValue,
            "alwaysHiddenEnabled": false, "iconStyle": IconStyle.z.rawValue, "showDividers": true,
            "tintEnabled": false, "tintColor": "#5B6CFF", "tintColor2": "#22D3EE", "tintGradient": true,
            "tintOpacity": 0.35, "tintBorder": false,
        ])
        showOnClick = d.bool(forKey: "showOnClick")
        showOnHover = d.bool(forKey: "showOnHover")
        hoverDelay = d.double(forKey: "hoverDelay")
        showOnScroll = d.bool(forKey: "showOnScroll")
        rehide = RehideStrategy(rawValue: d.string(forKey: "rehide") ?? "") ?? .smart
        rehideDelay = d.double(forKey: "rehideDelay")
        barMode = BarMode(rawValue: d.string(forKey: "barMode") ?? "") ?? .auto
        alwaysHiddenEnabled = d.bool(forKey: "alwaysHiddenEnabled")
        iconStyle = IconStyle(rawValue: d.string(forKey: "iconStyle") ?? "") ?? .z
        showDividers = d.bool(forKey: "showDividers")
        tintEnabled = d.bool(forKey: "tintEnabled")
        tintColor = d.string(forKey: "tintColor") ?? "#5B6CFF"
        tintColor2 = d.string(forKey: "tintColor2") ?? "#22D3EE"
        tintGradient = d.bool(forKey: "tintGradient")
        tintOpacity = d.double(forKey: "tintOpacity")
        tintBorder = d.bool(forKey: "tintBorder")

        let firstRun = d.object(forKey: "toggleKey") == nil
        toggleKey = Self.load("toggleKey")
        searchKey = Self.load("searchKey")
        allKey = Self.load("allKey")
        if firstRun {
            // ⌃⌥B toggles hidden items, ⌃⌥Space searches every menu bar item.
            toggleKey = KeyCombo(keyCode: kVK_ANSI_B, modifiers: controlKey | optionKey, key: "B")
            searchKey = KeyCombo(keyCode: kVK_Space, modifiers: controlKey | optionKey, key: "Space")
        }
    }

    private func save(_ combo: KeyCombo?, _ key: String) {
        // An explicit empty Data marks "no shortcut" so first-run defaults aren't re-applied.
        d.set(combo.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }

    private static func load(_ key: String) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
