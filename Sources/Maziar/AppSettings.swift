import SwiftUI
import AppKit

enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// A separately colorable region of the app's UI.
enum ThemeRegion: String, CaseIterable, Identifiable {
    case windowBackground
    case sidebarBackground
    case panelBackground
    case editorBackground
    case previewBackground
    case buttonColor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .windowBackground: return "Window Background"
        case .sidebarBackground: return "Sidebar Background"
        case .panelBackground: return "Toolbar / Panel Strips"
        case .editorBackground: return "Editor Background"
        case .previewBackground: return "PDF Preview Background"
        case .buttonColor: return "Button / Accent Color"
        }
    }

    /// Adaptive system default used when the user hasn't overridden this region.
    var defaultColor: Color {
        switch self {
        case .windowBackground: return Color(nsColor: .windowBackgroundColor)
        case .sidebarBackground: return Color(nsColor: .controlBackgroundColor)
        case .panelBackground: return Color(nsColor: .controlBackgroundColor)
        case .editorBackground: return Color(nsColor: .textBackgroundColor)
        case .previewBackground: return Color(nsColor: .underPageBackgroundColor)
        case .buttonColor: return Color(red: 0.13, green: 0.73, blue: 0.71)
        }
    }
}

/// A separately colorable syntax-highlighting role in the code editor's text.
enum SyntaxColorRole: String, CaseIterable, Identifiable {
    case mainText
    case command
    case comment
    case math
    case brace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mainText: return "Main Text"
        case .command: return "LaTeX Commands"
        case .comment: return "Comments"
        case .math: return "Math"
        case .brace: return "Braces / Brackets"
        }
    }

    var defaultColor: Color {
        switch self {
        case .mainText: return Color(nsColor: .labelColor)
        case .command: return Color(red: 0.15, green: 0.4, blue: 0.85)
        case .comment: return Color(nsColor: .secondaryLabelColor)
        case .math: return Color(red: 0.20, green: 0.55, blue: 0.32)
        case .brace: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceKey) }
    }
    @Published var customColors: [ThemeRegion: Color] {
        didSet { persistColors() }
    }
    @Published var syntaxColors: [SyntaxColorRole: Color] {
        didSet { persistSyntaxColors() }
    }

    private static let appearanceKey = "maziar.appearanceMode"
    private static let colorsKey = "maziar.customColors"
    private static let syntaxColorsKey = "maziar.syntaxColors"

    init() {
        appearanceMode = Self.loadAppearanceMode()
        customColors = Self.loadColorDict(key: Self.colorsKey)
        syntaxColors = Self.loadColorDict(key: Self.syntaxColorsKey)
    }

    /// Re-reads everything from UserDefaults — used after a settings backup is imported, so the
    /// already-running app reflects it immediately instead of needing a restart.
    func reloadFromDefaults() {
        appearanceMode = Self.loadAppearanceMode()
        customColors = Self.loadColorDict(key: Self.colorsKey)
        syntaxColors = Self.loadColorDict(key: Self.syntaxColorsKey)
    }

    private static func loadAppearanceMode() -> AppearanceMode {
        if let raw = UserDefaults.standard.string(forKey: Self.appearanceKey), let mode = AppearanceMode(rawValue: raw) {
            return mode
        }
        return .system
    }

    private static func loadColorDict<Key: RawRepresentable & Hashable>(key: String) -> [Key: Color] where Key.RawValue == String {
        var loaded: [Key: Color] = [:]
        if let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] {
            for (rawKey, hex) in dict {
                if let region = Key(rawValue: rawKey), let color = Color(hex: hex) {
                    loaded[region] = color
                }
            }
        }
        return loaded
    }

    func color(for region: ThemeRegion) -> Color {
        customColors[region] ?? region.defaultColor
    }

    func setColor(_ color: Color, for region: ThemeRegion) {
        customColors[region] = color
    }

    func resetColor(for region: ThemeRegion) {
        customColors[region] = nil
    }

    func resetAllColors() {
        customColors.removeAll()
    }

    func syntaxColor(for role: SyntaxColorRole) -> Color {
        syntaxColors[role] ?? role.defaultColor
    }

    func setSyntaxColor(_ color: Color, for role: SyntaxColorRole) {
        syntaxColors[role] = color
    }

    func resetSyntaxColor(for role: SyntaxColorRole) {
        syntaxColors[role] = nil
    }

    func resetAllSyntaxColors() {
        syntaxColors.removeAll()
    }

    private func persistColors() {
        var dict: [String: String] = [:]
        for (region, color) in customColors {
            if let hex = color.toHex() { dict[region.rawValue] = hex }
        }
        UserDefaults.standard.set(dict, forKey: Self.colorsKey)
    }

    private func persistSyntaxColors() {
        var dict: [String: String] = [:]
        for (role, color) in syntaxColors {
            if let hex = color.toHex() { dict[role.rawValue] = hex }
        }
        UserDefaults.standard.set(dict, forKey: Self.syntaxColorsKey)
    }
}

extension Color {
    init?(hex: String) {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        guard Scanner(string: sanitized).scanHexInt64(&value), sanitized.count == 8 else { return nil }
        let r = Double((value & 0xFF00_0000) >> 24) / 255
        let g = Double((value & 0x00FF_0000) >> 16) / 255
        let b = Double((value & 0x0000_FF00) >> 8) / 255
        let a = Double(value & 0x0000_00FF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    func toHex() -> String? {
        guard let converted = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((converted.redComponent * 255).rounded())
        let g = Int((converted.greenComponent * 255).rounded())
        let b = Int((converted.blueComponent * 255).rounded())
        let a = Int((converted.alphaComponent * 255).rounded())
        return String(format: "%02X%02X%02X%02X", r, g, b, a)
    }
}
