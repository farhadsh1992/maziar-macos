import Foundation
import SwiftUI

/// A named color a project task can be tagged with.
struct TaskTag: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var colorHex: String

    var color: Color { Color(hex: colorHex) ?? .gray }
}

/// The task tags offered on every project's task list — created and edited in Settings → Projects.
/// Stored as one JSON value under a `maziar.` key, so it rides along with Settings backup / Drive sync.
@MainActor
final class TaskTagStore: ObservableObject {
    private static let key = "maziar.projects.taskTags"

    @Published var tags: [TaskTag] {
        didSet {
            if let data = try? JSONEncoder().encode(tags) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([TaskTag].self, from: data) {
            tags = decoded
        } else {
            tags = []
        }
        NotificationCenter.default.addObserver(forName: .maziarSettingsImported, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadFromDefaults() }
        }
    }

    func reloadFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([TaskTag].self, from: data) else { tags = []; return }
        if decoded != tags { tags = decoded }
    }

    func tag(_ id: UUID) -> TaskTag? { tags.first { $0.id == id } }

    func tags(for task: PaperTask) -> [TaskTag] { task.tagIDs.compactMap(tag) }

    @discardableResult
    func add(name: String = "New Tag", colorHex: String = "1E6FE0") -> TaskTag {
        let tag = TaskTag(name: name, colorHex: colorHex)
        tags.append(tag)
        return tag
    }

    func remove(_ tag: TaskTag) { tags.removeAll { $0.id == tag.id } }
}
