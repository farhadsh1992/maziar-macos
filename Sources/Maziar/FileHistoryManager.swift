import Foundation
import CryptoKit

struct FileSnapshot: Identifiable {
    let id: String // the timestamp-derived filename
    let date: Date
    let url: URL

    func loadContent() -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Keeps timestamped snapshots of edited files outside the project folder (so history metadata
/// never gets swept into the user's own git commits), keyed by the file's absolute path. Every
/// successful save appends a snapshot; older ones beyond `maxSnapshotsPerFile` are pruned.
@MainActor
final class FileHistoryManager {
    static let shared = FileHistoryManager()

    private let maxSnapshotsPerFile = 100
    private let baseDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDirectory = appSupport.appendingPathComponent("Maziar/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    private func directory(for fileURL: URL) -> URL {
        let hash = SHA256.hash(data: Data(fileURL.standardizedFileURL.path.utf8))
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return baseDirectory.appendingPathComponent(hex, isDirectory: true)
    }

    /// Records a snapshot of `content` for `fileURL`, skipping if identical to the most recent one.
    func record(content: String, for fileURL: URL) {
        let dir = directory(for: fileURL)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let existing = snapshots(for: fileURL)
        if let last = existing.first, last.loadContent() == content { return }

        // Filename is the timestamp in milliseconds since 1970 — sorts lexically, and needs no
        // fragile character-substitution round-trip the way an ISO8601 string with ':' replaced
        // for filesystem-safety would.
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        let snapshotURL = dir.appendingPathComponent("\(millis).txt")
        try? content.write(to: snapshotURL, atomically: true, encoding: .utf8)

        let all = snapshots(for: fileURL)
        if all.count > maxSnapshotsPerFile {
            for stale in all.suffix(from: maxSnapshotsPerFile) {
                try? FileManager.default.removeItem(at: stale.url)
            }
        }
    }

    /// Snapshots for `fileURL`, newest first.
    func snapshots(for fileURL: URL) -> [FileSnapshot] {
        let dir = directory(for: fileURL)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return items
            .filter { $0.pathExtension == "txt" }
            .compactMap { url -> FileSnapshot? in
                guard let millis = Int(url.deletingPathExtension().lastPathComponent) else { return nil }
                return FileSnapshot(id: url.lastPathComponent, date: Date(timeIntervalSince1970: Double(millis) / 1000), url: url)
            }
            .sorted { $0.date > $1.date }
    }
}
