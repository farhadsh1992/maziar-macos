import Foundation

/// One tab of a project's Notes — each has its own markdown-cell notebook.
struct ProjectNoteSection: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
}

/// A project's notes — the same markdown-cell notebook (`NotebookDocument`) the Library and Reader
/// use, split into any number of titled sections the user can reorder. Stored under
/// `maziar.projectNotes…` UserDefaults keys per project/section rather than inside `Paper` itself,
/// so typing in a note doesn't rewrite the whole projects array, and the notes still ride along with
/// Settings backup / Google Drive sync like every other `maziar.` key.
///
/// A project that never added a second section has no section list stored: it gets one implicit
/// "Notes" section whose id is the project's own id, which maps to the original single-notebook key
/// (`maziar.projectNotes.<project id>`) — so notes written before sections existed need no migration.
enum ProjectNotebookStorage {
    private static let defaults = UserDefaults.standard

    private static func legacyKey(_ projectID: UUID) -> String { "maziar.projectNotes.\(projectID.uuidString)" }
    private static func sectionsKey(_ projectID: UUID) -> String { "maziar.projectNoteSections.\(projectID.uuidString)" }
    private static func contentKey(_ projectID: UUID, _ sectionID: UUID) -> String {
        sectionID == projectID ? legacyKey(projectID) : "\(legacyKey(projectID)).\(sectionID.uuidString)"
    }

    static func sections(for projectID: UUID) -> [ProjectNoteSection] {
        if let data = defaults.data(forKey: sectionsKey(projectID)),
           let list = try? JSONDecoder().decode([ProjectNoteSection].self, from: data), !list.isEmpty {
            return list
        }
        return [ProjectNoteSection(id: projectID, title: "Notes")]
    }

    static func writeSections(_ sections: [ProjectNoteSection], for projectID: UUID) {
        guard let data = try? JSONEncoder().encode(sections) else { return }
        defaults.set(data, forKey: sectionsKey(projectID))
    }

    static func read(_ projectID: UUID, section sectionID: UUID? = nil) -> [NotebookCell] {
        guard let data = defaults.data(forKey: contentKey(projectID, sectionID ?? projectID)) else { return [] }
        return NotebookDocument.decode(data)?.cells ?? []
    }

    static func write(_ cells: [NotebookCell], for projectID: UUID, section sectionID: UUID? = nil) {
        let key = contentKey(projectID, sectionID ?? projectID)
        // An emptied notebook is saved as an empty one rather than deleted, so clearing notes on one
        // Mac also clears them on the other (a snapshot only carries keys that exist).
        guard let data = NotebookDocument(cells: cells).encoded() else { return }
        defaults.set(data, forKey: key)
    }

    static func removeSection(_ sectionID: UUID, for projectID: UUID) {
        defaults.removeObject(forKey: contentKey(projectID, sectionID))
    }

    static func remove(_ projectID: UUID) {
        for section in sections(for: projectID) {
            defaults.removeObject(forKey: contentKey(projectID, section.id))
        }
        defaults.removeObject(forKey: legacyKey(projectID))
        defaults.removeObject(forKey: sectionsKey(projectID))
    }
}
