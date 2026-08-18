import Foundation

/// Exports/imports every app setting in one file — the whole point of the `"maziar."` prefix
/// convention every settings class already uses for its UserDefaults keys is that this doesn't
/// need to know each class's individual fields (and can't drift out of sync as new settings get
/// added, the way a hand-maintained parallel struct would): it just captures every UserDefaults
/// key under that prefix as a property list, and restores them the same way. That naturally
/// includes tracked conferences, papers, prompt tasks, pricing, and preferences alike — API keys
/// are never included since those live in the Keychain, not UserDefaults.
@MainActor
enum AppSettingsBackupService {
    static let keyPrefix = "maziar."

    enum BackupError: LocalizedError {
        case invalidFile
        var errorDescription: String? {
            switch self {
            case .invalidFile: return "That file isn't a Maziar settings backup (or it's corrupted)."
            }
        }
    }

    static func exportData() throws -> Data {
        let all = UserDefaults.standard.dictionaryRepresentation()
        let filtered = all.filter { $0.key.hasPrefix(keyPrefix) }
        return try PropertyListSerialization.data(fromPropertyList: filtered, format: .xml, options: 0)
    }

    /// Overwrites every `"maziar."`-prefixed UserDefaults key found in the backup, then calls
    /// each store's `reloadFromDefaults()` so the already-running app reflects it immediately.
    static func importData(
        _ data: Data,
        appSettings: AppSettings,
        aiSettings: AISettings,
        texManager: TeXInstallationManager,
        conferenceStore: ConferenceStore,
        journalStore: JournalStore,
        paperStore: PaperStore
    ) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            throw BackupError.invalidFile
        }
        for (key, value) in dict where key.hasPrefix(keyPrefix) {
            UserDefaults.standard.set(value, forKey: key)
        }

        appSettings.reloadFromDefaults()
        aiSettings.reloadFromDefaults()
        texManager.reloadFromDefaults()
        conferenceStore.reloadFromDefaults()
        journalStore.reloadFromDefaults()
        paperStore.reloadFromDefaults()
    }
}
