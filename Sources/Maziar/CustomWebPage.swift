import Foundation

/// A user-added page (Settings → Custom Pages) that opens some URL directly inside Maziar, the
/// same embedded-browser shape the built-in Diagrams page already uses — just generalized so the
/// user can add any page themselves instead of needing one hand-built per site.
struct CustomWebPage: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var urlString: String
    /// Whether this page shows as its own entry in the left sidebar. Turning this off keeps the
    /// page defined (still listed in Settings, still reachable by turning it back on) without it
    /// cluttering the sidebar — a lighter-weight option than deleting it outright.
    var showInSidebar: Bool = true
    /// SF Symbol name shown in the sidebar — one of `suggestedIcons`, though any valid SF Symbol
    /// name works since this is just a plain string, not an enum tied to the suggested list.
    var iconSystemName: String = "globe"
    /// Hex-encoded via the same `Color.toHex()`/`init?(hex:)` the rest of the app's custom colors
    /// already use (`AppSettings.swift`); nil means "use the sidebar's normal selected/unselected
    /// coloring," the same "inherit unless overridden" pattern as `LibraryGroup.iconColorHex`.
    var iconColorHex: String?
    /// A user-picked image (PNG, pre-resized to a small square before being stored — see
    /// `SettingsView`'s icon-image picker) shown instead of `iconSystemName` when set. Persisted
    /// inline as part of this page's own JSON in `AppSettings.customPages` rather than a separate
    /// file on disk, the same "one self-contained value" simplicity as everything else here — pages
    /// are few and the images are small, so this doesn't need its own storage mechanism.
    var iconImageData: Data?
    /// When true, this page shows its own tab bar (add/close tabs) instead of one fixed session,
    /// each tab an independent embedded browser session all starting at `urlString` — the same
    /// multi-session shape the built-in Diagrams page already has, generalized to any custom page.
    var allowMultipleTabs: Bool = false
    /// Shows a persistent icon rail down the page's left side with a launcher for the real "Farhad's
    /// CV AutoFill" Mac app (a separate, already-built companion app — see `CustomWebPageView`'s own
    /// doc comment for why this launches the real app rather than reimplementing it here). Meant for
    /// pages like LinkedIn's job feed, where having a one-click way to open it while browsing is
    /// useful without needing autofill logic embedded in the page itself.
    var showCVAutofillTool: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, urlString, showInSidebar, iconSystemName, iconColorHex, iconImageData, allowMultipleTabs, showCVAutofillTool
    }

    init(
        id: UUID = UUID(), name: String, urlString: String, showInSidebar: Bool = true,
        iconSystemName: String = "globe", iconColorHex: String? = nil, iconImageData: Data? = nil,
        allowMultipleTabs: Bool = false, showCVAutofillTool: Bool = false
    ) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.showInSidebar = showInSidebar
        self.iconSystemName = iconSystemName
        self.iconColorHex = iconColorHex
        self.iconImageData = iconImageData
        self.allowMultipleTabs = allowMultipleTabs
        self.showCVAutofillTool = showCVAutofillTool
    }

    /// Custom decode so a field added after this struct's first release — `iconSystemName`/
    /// `iconColorHex`/`iconImageData`/`allowMultipleTabs`/`showCVAutofillTool` today, whichever
    /// comes next tomorrow — falls back to its default instead of failing the whole decode, the
    /// same fix already applied to `LibraryEntry`/`Paper` after that exact failure mode was caught
    /// there: a plain Swift default value does NOT provide that fallback for synthesized
    /// `Decodable` conformance on its own.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        urlString = try container.decode(String.self, forKey: .urlString)
        showInSidebar = try container.decodeIfPresent(Bool.self, forKey: .showInSidebar) ?? true
        iconSystemName = try container.decodeIfPresent(String.self, forKey: .iconSystemName) ?? "globe"
        iconColorHex = try container.decodeIfPresent(String.self, forKey: .iconColorHex)
        iconImageData = try container.decodeIfPresent(Data.self, forKey: .iconImageData)
        allowMultipleTabs = try container.decodeIfPresent(Bool.self, forKey: .allowMultipleTabs) ?? false
        showCVAutofillTool = try container.decodeIfPresent(Bool.self, forKey: .showCVAutofillTool) ?? false
    }

    /// A curated set of SF Symbols offered in the icon picker — not exhaustive (any valid SF
    /// Symbol name works via `iconSystemName`), just a reasonable starting set covering common
    /// kinds of pages someone might add.
    static let suggestedIcons: [String] = [
        "globe", "safari", "link", "doc.text", "doc.richtext", "note.text",
        "chart.bar", "chart.pie", "photo", "paintbrush", "pencil.and.outline",
        "flowchart", "chevron.left.forwardslash.chevron.right", "terminal",
        "folder", "tray.full", "bookmark", "star", "cube", "network",
        "cloud", "calendar", "envelope", "message", "video", "music.note",
        "gamecontroller", "wrench.and.screwdriver", "person.2", "book",
    ]

    /// Accepts a URL typed with or without a scheme (`excalidraw.com` as well as
    /// `https://excalidraw.com`) — assumes `https://` when none is given, same convention as the
    /// paper "Add via URL" flow in `LibraryStore.downloadAndAddPaper`. Returns nil for input that
    /// still isn't a valid URL even after that.
    static func normalizedURLString(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme.hasPrefix("http") {
            return trimmed
        }
        let withScheme = "https://" + trimmed
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return withScheme
    }
}
