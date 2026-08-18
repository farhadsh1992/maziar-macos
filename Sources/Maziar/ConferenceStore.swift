import Foundation

@MainActor
final class ConferenceStore: ObservableObject {
    @Published var conferences: [ConferenceEntry] {
        didSet { persist() }
    }
    /// Reference sites (WikiCFP, CORE rankings, DBLP, etc.) suggested to the AI as search
    /// starting points on every conference lookup — see `ConferenceInfoService`.
    @Published var helperWebsites: [String] {
        didSet { UserDefaults.standard.set(helperWebsites, forKey: Self.helperWebsitesKey) }
    }

    private static let key = "maziar.conferences"
    private static let helperWebsitesKey = "maziar.conferences.helperWebsites"

    static let defaultHelperWebsites = [
        "https://www.wikicfp.com/cfp/",
        "https://portal.core.edu.au/conf-ranks/",
        "https://dblp.org/"
    ]

    init() {
        conferences = Self.loadConferences()
        helperWebsites = UserDefaults.standard.stringArray(forKey: Self.helperWebsitesKey) ?? Self.defaultHelperWebsites
    }

    /// Re-reads everything from UserDefaults — used after a settings backup is imported, so the
    /// already-running app reflects it immediately instead of needing a restart.
    func reloadFromDefaults() {
        conferences = Self.loadConferences()
        helperWebsites = UserDefaults.standard.stringArray(forKey: Self.helperWebsitesKey) ?? Self.defaultHelperWebsites
    }

    private static func loadConferences() -> [ConferenceEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([ConferenceEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    @discardableResult
    func addHelperWebsite(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !helperWebsites.contains(trimmed) else { return false }
        helperWebsites.append(trimmed)
        return true
    }

    func removeHelperWebsite(_ url: String) {
        helperWebsites.removeAll { $0 == url }
    }

    @discardableResult
    func add(name: String, fullName: String? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !conferences.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        let trimmedFullName = fullName?.trimmingCharacters(in: .whitespacesAndNewlines)
        conferences.append(ConferenceEntry(name: trimmed, fullName: (trimmedFullName?.isEmpty ?? true) ? nil : trimmedFullName))
        return true
    }

    func remove(_ entry: ConferenceEntry) {
        conferences.removeAll { $0.id == entry.id }
    }

    /// Merges a previously-exported JSON list back in — e.g. after reinstalling the app, or moving
    /// to a new Mac, without going through the full Settings backup/restore. Matches by name
    /// (case-insensitive) so re-importing the same file is idempotent: an existing tracked
    /// conference is replaced wholesale by the imported one (including its deadlines/links/notes),
    /// anything new is appended. Returns the number of entries processed.
    @discardableResult
    func importEntries(_ entries: [ConferenceEntry]) -> Int {
        for imported in entries {
            if let index = conferences.firstIndex(where: { $0.name.caseInsensitiveCompare(imported.name) == .orderedSame }) {
                conferences[index] = imported
            } else {
                conferences.append(imported)
            }
        }
        return entries.count
    }

    func update(_ entry: ConferenceEntry) {
        guard let index = conferences.firstIndex(where: { $0.id == entry.id }) else { return }
        conferences[index] = entry
    }

    /// Array order is the persisted, user-visible order — these just swap neighbors.
    func moveUp(_ entry: ConferenceEntry) {
        guard let index = conferences.firstIndex(where: { $0.id == entry.id }), index > 0 else { return }
        conferences.swapAt(index, index - 1)
    }

    func moveDown(_ entry: ConferenceEntry) {
        guard let index = conferences.firstIndex(where: { $0.id == entry.id }), index < conferences.count - 1 else { return }
        conferences.swapAt(index, index + 1)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(conferences) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
