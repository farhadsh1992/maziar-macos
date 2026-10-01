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

/// The Reader window's chrome style — the companion pane and highlight toolbar's own background,
/// not the PDF's own matte (`ThemeRegion.readerPDFBackground`, a separate, already-configurable
/// concern). `.glass` uses a translucent SwiftUI `Material` (blurred, lets whatever's behind the
/// window show through, the same effect already used for the highlight-suggestion popup and the
/// "Copy as LaTeX" status toast); `.normal` is a plain opaque panel.
enum ReaderVisualStyle: String, CaseIterable, Identifiable, Codable {
    case normal
    case glass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .glass: return "Glass"
        }
    }
}

/// Which source powers the Reader window's "AI Chat" companion mode — either Maziar's own in-app
/// chat (using the AI provider/API key already configured for the rest of the app) or an embedded
/// website for a specific hosted chat product, opened the same way a custom page is. Choosing a
/// website source also renames the mode's own tab/button label to match (`buttonLabel`) — the UI
/// never says "AI Chat" while actually showing ChatGPT or Claude.
enum ReaderAIChatSource: String, CaseIterable, Identifiable, Codable {
    case builtIn
    case chatGPT
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .builtIn: return "Built-in AI Chat"
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        }
    }

    /// The Reader companion pane's mode label/tab title for this source.
    var buttonLabel: String {
        switch self {
        case .builtIn: return "AI Chat"
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        }
    }

    /// `nil` for `.builtIn` — it has no website to open, it's Maziar's own chat panel.
    var websiteURLString: String? {
        switch self {
        case .builtIn: return nil
        case .chatGPT: return "https://chatgpt.com"
        case .claude: return "https://claude.ai/new"
        }
    }
}

/// A separately colorable region of the app's UI. `scope` groups them for the Appearance
/// settings UI (a general section, plus one per page that asked for its own colors) — the
/// underlying storage/persistence (`AppSettings.customColors`) doesn't otherwise care about scope.
enum ThemeRegion: String, CaseIterable, Identifiable {
    case windowBackground
    case sidebarBackground
    case panelBackground
    case editorBackground
    case previewBackground
    case buttonColor

    case libraryHeaderBackground
    case libraryGroupsBackground
    case libraryStripBackground
    case libraryListBackground
    case libraryCardBackground
    case libraryButtonColor

    case readerPDFBackground
    case readerCompanionBackground
    /// The highlight toolbar's own background — the strip holding the highlight color circles —
    /// kept independently configurable from `readerCompanionBackground` (which still covers the
    /// companion pane and the PDF pane's own matte) so it can carry a different color and, in Glass
    /// style, a visibly lighter/more transparent material than the rest of the window.
    case readerToolbarBackground
    case readerButtonColor

    enum Scope {
        case general, library, reader
    }

    var id: String { rawValue }

    var scope: Scope {
        switch self {
        case .libraryHeaderBackground, .libraryGroupsBackground, .libraryStripBackground,
             .libraryListBackground, .libraryCardBackground, .libraryButtonColor:
            return .library
        case .readerPDFBackground, .readerCompanionBackground, .readerToolbarBackground, .readerButtonColor:
            return .reader
        case .windowBackground, .sidebarBackground, .panelBackground, .editorBackground,
             .previewBackground, .buttonColor:
            return .general
        }
    }

    var displayName: String {
        switch self {
        case .windowBackground: return "Window Background"
        case .sidebarBackground: return "Sidebar Background"
        case .panelBackground: return "Toolbar / Panel Strips"
        case .editorBackground: return "Editor Background"
        case .previewBackground: return "PDF Preview Background"
        case .buttonColor: return "Button / Accent Color"
        case .libraryHeaderBackground: return "Header"
        case .libraryGroupsBackground: return "Groups Row"
        case .libraryStripBackground: return "Keyword Strip"
        case .libraryListBackground: return "Paper List"
        case .libraryCardBackground: return "Paper Cards"
        case .libraryButtonColor: return "Button / Accent Color"
        case .readerPDFBackground: return "PDF Background"
        case .readerCompanionBackground: return "Panel Background (Normal style)"
        case .readerToolbarBackground: return "Highlight Toolbar Background (Normal style)"
        case .readerButtonColor: return "Button / Accent Color"
        }
    }

    /// Adaptive system default used when the user hasn't overridden this region. For the two
    /// page-specific "Button / Accent Color" cases this is only a last-resort fallback — in
    /// practice `AppSettings.libraryButtonColor()`/`readerButtonColor()` resolve to the app-wide
    /// button color first, so a page's buttons match the rest of the app until explicitly
    /// overridden, the same "inherit unless overridden" pattern as the AI provider overrides.
    var defaultColor: Color {
        switch self {
        case .windowBackground: return Color(nsColor: .windowBackgroundColor)
        case .sidebarBackground: return Color(nsColor: .controlBackgroundColor)
        case .panelBackground: return Color(nsColor: .controlBackgroundColor)
        case .editorBackground: return Color(nsColor: .textBackgroundColor)
        case .previewBackground: return Color(nsColor: .underPageBackgroundColor)
        case .buttonColor: return Color(red: 0.13, green: 0.73, blue: 0.71)
        case .libraryHeaderBackground: return Color(nsColor: .windowBackgroundColor)
        case .libraryGroupsBackground: return Color(nsColor: .windowBackgroundColor)
        case .libraryStripBackground: return Color(nsColor: .windowBackgroundColor)
        case .libraryListBackground: return Color(nsColor: .windowBackgroundColor)
        case .libraryCardBackground: return Color(nsColor: .controlBackgroundColor)
        case .libraryButtonColor: return Color(red: 0.13, green: 0.73, blue: 0.71)
        case .readerPDFBackground: return Color(nsColor: .underPageBackgroundColor)
        case .readerCompanionBackground: return Color(nsColor: .windowBackgroundColor)
        case .readerToolbarBackground: return Color(nsColor: .controlBackgroundColor)
        case .readerButtonColor: return Color(red: 0.13, green: 0.73, blue: 0.71)
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
    @Published var readerVisualStyle: ReaderVisualStyle {
        didSet { UserDefaults.standard.set(readerVisualStyle.rawValue, forKey: Self.readerVisualStyleKey) }
    }
    /// The Reader window's own light/dark/system override — `.system` means "just follow
    /// `appearanceMode` like every other window," the same "inherit unless overridden" pattern
    /// already used for the Reader's button color and background colors, reusing `AppearanceMode`
    /// itself rather than a near-duplicate enum since the three cases and their meaning are
    /// identical.
    @Published var readerAppearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(readerAppearanceMode.rawValue, forKey: Self.readerAppearanceModeKey) }
    }
    /// Which modes get a one-click icon button in the Reader window's left quick-access icon rail
    /// (alongside the full mode dropdown, which always lists every mode regardless). User-editable
    /// in Settings → Appearance → Reader — add or remove any mode, in any order; defaults to the
    /// original hardcoded set (Translator/AI Chat/Notes/Code).
    @Published var readerQuickAccessModes: [ReaderCompanionMode] {
        didSet { UserDefaults.standard.set(readerQuickAccessModes.map { $0.rawValue }, forKey: Self.readerQuickAccessModesKey) }
    }
    /// Which source the Reader's "AI Chat" mode actually shows — Maziar's own in-app chat, or an
    /// embedded ChatGPT/Claude website. Settings → Appearance → Reader.
    @Published var readerAIChatSource: ReaderAIChatSource {
        didSet { UserDefaults.standard.set(readerAIChatSource.rawValue, forKey: Self.readerAIChatSourceKey) }
    }
    /// User-added pages (Settings → Custom Pages) that open some URL directly inside Maziar —
    /// each optionally shown as its own left-sidebar entry, mirroring the built-in Diagrams page.
    @Published var customPages: [CustomWebPage] {
        didSet { persistCustomPages() }
    }
    /// Built-in `AppSection` pages (Projects, Editor, Conferences, Journals, Library, Diagrams)
    /// hidden from the left sidebar — same "hide without deleting" idea as `CustomWebPage
    /// .showInSidebar`, just inverted (a set of what's hidden, since built-in sections always
    /// exist and can't be "removed" the way a custom page can).
    @Published var hiddenSections: Set<AppSection> {
        didSet { UserDefaults.standard.set(hiddenSections.map { $0.rawValue }, forKey: Self.hiddenSectionsKey) }
    }
    /// Per-`AppSection` SF Symbol override — same "customize a built-in page's look" idea as
    /// `CustomWebPage.iconSystemName`, just keyed on the fixed `AppSection` enum instead of a
    /// user-created page, since a built-in section has no model of its own to carry the field.
    /// Missing entry means "use `AppSection.icon`'s own default."
    @Published var sectionIconOverrides: [AppSection: String] {
        didSet { persistSectionIconOverrides() }
    }
    /// Per-`AppSection` color override, same "inherit unless set" pattern as `CustomWebPage
    /// .iconColorHex` — missing entry means "use the sidebar's normal selected/unselected coloring."
    @Published var sectionIconColors: [AppSection: Color] {
        didSet { persistSectionIconColors() }
    }

    private static let appearanceKey = "maziar.appearanceMode"
    private static let colorsKey = "maziar.customColors"
    private static let syntaxColorsKey = "maziar.syntaxColors"
    private static let readerVisualStyleKey = "maziar.readerVisualStyle"
    private static let readerAppearanceModeKey = "maziar.readerAppearanceMode"
    private static let readerQuickAccessModesKey = "maziar.readerQuickAccessModes"
    private static let readerAIChatSourceKey = "maziar.readerAIChatSource"
    private static let customPagesKey = "maziar.customPages"
    private static let hiddenSectionsKey = "maziar.hiddenSections"
    private static let sectionIconOverridesKey = "maziar.sectionIconOverrides"
    private static let sectionIconColorsKey = "maziar.sectionIconColors"

    init() {
        appearanceMode = Self.loadAppearanceMode()
        customColors = Self.loadColorDict(key: Self.colorsKey)
        syntaxColors = Self.loadColorDict(key: Self.syntaxColorsKey)
        readerVisualStyle = Self.loadReaderVisualStyle()
        readerAppearanceMode = Self.loadReaderAppearanceMode()
        readerQuickAccessModes = Self.loadReaderQuickAccessModes()
        readerAIChatSource = Self.loadReaderAIChatSource()
        customPages = Self.loadCustomPages()
        hiddenSections = Self.loadHiddenSections()
        sectionIconOverrides = Self.loadSectionIconOverrides()
        sectionIconColors = Self.loadColorDict(key: Self.sectionIconColorsKey)
    }

    /// Re-reads everything from UserDefaults — used after a settings backup is imported, so the
    /// already-running app reflects it immediately instead of needing a restart.
    func reloadFromDefaults() {
        appearanceMode = Self.loadAppearanceMode()
        customColors = Self.loadColorDict(key: Self.colorsKey)
        syntaxColors = Self.loadColorDict(key: Self.syntaxColorsKey)
        readerVisualStyle = Self.loadReaderVisualStyle()
        readerAppearanceMode = Self.loadReaderAppearanceMode()
        readerQuickAccessModes = Self.loadReaderQuickAccessModes()
        readerAIChatSource = Self.loadReaderAIChatSource()
        customPages = Self.loadCustomPages()
        hiddenSections = Self.loadHiddenSections()
        sectionIconOverrides = Self.loadSectionIconOverrides()
        sectionIconColors = Self.loadColorDict(key: Self.sectionIconColorsKey)
    }

    private static func loadCustomPages() -> [CustomWebPage] {
        guard let data = UserDefaults.standard.data(forKey: customPagesKey),
              let decoded = try? JSONDecoder().decode([CustomWebPage].self, from: data) else { return [] }
        return decoded
    }

    private func persistCustomPages() {
        guard let data = try? JSONEncoder().encode(customPages) else { return }
        UserDefaults.standard.set(data, forKey: Self.customPagesKey)
    }

    private static func loadHiddenSections() -> Set<AppSection> {
        guard let raw = UserDefaults.standard.array(forKey: hiddenSectionsKey) as? [String] else { return [] }
        return Set(raw.compactMap { AppSection(rawValue: $0) })
    }

    private static func loadSectionIconOverrides() -> [AppSection: String] {
        guard let dict = UserDefaults.standard.dictionary(forKey: sectionIconOverridesKey) as? [String: String] else { return [:] }
        var result: [AppSection: String] = [:]
        for (rawKey, icon) in dict {
            if let section = AppSection(rawValue: rawKey) { result[section] = icon }
        }
        return result
    }

    private func persistSectionIconOverrides() {
        var dict: [String: String] = [:]
        for (section, icon) in sectionIconOverrides { dict[section.rawValue] = icon }
        UserDefaults.standard.set(dict, forKey: Self.sectionIconOverridesKey)
    }

    private func persistSectionIconColors() {
        var dict: [String: String] = [:]
        for (section, color) in sectionIconColors {
            if let hex = color.toHex() { dict[section.rawValue] = hex }
        }
        UserDefaults.standard.set(dict, forKey: Self.sectionIconColorsKey)
    }

    /// The sidebar icon actually shown for a built-in section — its own override when set, else
    /// `AppSection.icon`'s default.
    func icon(for section: AppSection) -> String {
        sectionIconOverrides[section] ?? section.icon
    }

    func setSectionIcon(_ section: AppSection, iconSystemName: String) {
        sectionIconOverrides[section] = iconSystemName
    }

    func sectionIconColor(_ section: AppSection) -> Color? {
        sectionIconColors[section]
    }

    func setSectionIconColor(_ section: AppSection, color: Color?) {
        sectionIconColors[section] = color
    }

    /// Clears both overrides for a section, back to its original built-in icon/coloring — the
    /// picker only offers `CustomWebPage.suggestedIcons`, which doesn't include every built-in
    /// section's actual default symbol, so this is the only way back once one's been changed away.
    func resetSectionIconAndColor(_ section: AppSection) {
        sectionIconOverrides[section] = nil
        sectionIconColors[section] = nil
    }

    @discardableResult
    func addCustomPage(name: String, urlString: String, iconSystemName: String = "globe", iconColorHex: String? = nil, iconImageData: Data? = nil, allowMultipleTabs: Bool = false, showCVAutofillTool: Bool = false) -> CustomWebPage {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = CustomWebPage(
            name: trimmedName.isEmpty ? "Page" : trimmedName, urlString: urlString,
            iconSystemName: iconSystemName, iconColorHex: iconColorHex, iconImageData: iconImageData,
            allowMultipleTabs: allowMultipleTabs, showCVAutofillTool: showCVAutofillTool
        )
        customPages.append(page)
        return page
    }

    func removeCustomPage(_ page: CustomWebPage) {
        customPages.removeAll { $0.id == page.id }
    }

    func setCustomPage(_ page: CustomWebPage, showInSidebar: Bool) {
        guard let index = customPages.firstIndex(where: { $0.id == page.id }) else { return }
        customPages[index].showInSidebar = showInSidebar
    }

    func setCustomPage(_ page: CustomWebPage, name: String) {
        guard let index = customPages.firstIndex(where: { $0.id == page.id }) else { return }
        customPages[index].name = name
    }

    /// Silently keeps the previous URL when the new text doesn't normalize to a valid one, rather
    /// than leaving the page pointed at something broken — same validation `addCustomPage`'s own
    /// caller already does via `CustomWebPage.normalizedURLString` before calling in.
    func setCustomPage(_ page: CustomWebPage, urlString: String) {
        guard let index = customPages.firstIndex(where: { $0.id == page.id }),
              let normalized = CustomWebPage.normalizedURLString(urlString) else { return }
        customPages[index].urlString = normalized
    }

    /// Also clears any custom image — a picked SF Symbol and a picked image are mutually exclusive
    /// in the sidebar (the image takes priority when both would otherwise be set), so choosing a
    /// symbol is how the user backs out of a previously-picked image.
    func setCustomPage(_ page: CustomWebPage, iconSystemName: String) {
        guard let index = customPages.firstIndex(where: { $0.id == page.id }) else { return }
        customPages[index].iconSystemName = iconSystemName
        customPages[index].iconImageData = nil
    }

    func setCustomPage(_ page: CustomWebPage, iconColorHex: String?) {
        guard let index = customPages.firstIndex(where: { $0.id == page.id }) else { return }
        customPages[index].iconColorHex = iconColorHex
    }

    func setCustomPage(_ page: CustomWebPage, iconImageData: Data?) {
        guard let index = customPages.firstIndex(where: { $0.id == page.id }) else { return }
        customPages[index].iconImageData = iconImageData
    }

    func setCustomPage(_ page: CustomWebPage, allowMultipleTabs: Bool) {
        guard let index = customPages.firstIndex(where: { $0.id == page.id }) else { return }
        customPages[index].allowMultipleTabs = allowMultipleTabs
    }

    func setCustomPage(_ page: CustomWebPage, showCVAutofillTool: Bool) {
        guard let index = customPages.firstIndex(where: { $0.id == page.id }) else { return }
        customPages[index].showCVAutofillTool = showCVAutofillTool
    }

    private static func loadAppearanceMode() -> AppearanceMode {
        if let raw = UserDefaults.standard.string(forKey: Self.appearanceKey), let mode = AppearanceMode(rawValue: raw) {
            return mode
        }
        return .system
    }

    private static func loadReaderVisualStyle() -> ReaderVisualStyle {
        if let raw = UserDefaults.standard.string(forKey: Self.readerVisualStyleKey), let style = ReaderVisualStyle(rawValue: raw) {
            return style
        }
        return .normal
    }

    private static func loadReaderAppearanceMode() -> AppearanceMode {
        if let raw = UserDefaults.standard.string(forKey: Self.readerAppearanceModeKey), let mode = AppearanceMode(rawValue: raw) {
            return mode
        }
        return .system
    }

    private static func loadReaderQuickAccessModes() -> [ReaderCompanionMode] {
        if let raw = UserDefaults.standard.array(forKey: Self.readerQuickAccessModesKey) as? [String] {
            return raw.compactMap { ReaderCompanionMode(rawValue: $0) }
        }
        return [.translator, .chat, .notes, .code]
    }

    private static func loadReaderAIChatSource() -> ReaderAIChatSource {
        if let raw = UserDefaults.standard.string(forKey: Self.readerAIChatSourceKey), let source = ReaderAIChatSource(rawValue: raw) {
            return source
        }
        return .builtIn
    }

    /// The Reader window's effective color scheme — its own override when set, else whatever the
    /// rest of the app is using.
    func readerColorScheme() -> ColorScheme? {
        readerAppearanceMode.colorScheme ?? appearanceMode.colorScheme
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

    /// The Library page's button/accent color — the app-wide button color until explicitly
    /// overridden, same "inherit unless set" pattern as the AI provider overrides.
    func libraryButtonColor() -> Color {
        customColors[.libraryButtonColor] ?? color(for: .buttonColor)
    }

    /// The Reader window's button/accent color — same inheritance as `libraryButtonColor()`.
    func readerButtonColor() -> Color {
        customColors[.readerButtonColor] ?? color(for: .buttonColor)
    }

    /// The Reader window's companion pane/toolbar background, styled per `readerVisualStyle` —
    /// a translucent blurred `Material` for `.glass`, or the (possibly user-overridden) opaque
    /// `readerCompanionBackground` color for `.normal`. Erased to `AnyShapeStyle` since `Material`
    /// and `Color` are different concrete types that both conform to `ShapeStyle`.
    func readerCompanionBackground() -> AnyShapeStyle {
        switch readerVisualStyle {
        case .glass: return AnyShapeStyle(.regularMaterial)
        case .normal: return AnyShapeStyle(color(for: .readerCompanionBackground))
        }
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
