import Foundation
import CryptoKit

/// Keeps OpenPrism projects (`…/Maziar/OpenPrism/data/<project id>/`) the same on every Mac, through the
/// Drive app-data folder the settings snapshot already uses (scope `drive.appdata`, nothing else).
///
/// Each project is stored in Drive as one zip, `op-<project id>.zip`. Per project, a pass compares three
/// things — this Mac's folder, the Drive zip, and what this Mac recorded at its last successful sync — and
/// then does exactly one of: nothing, upload, download, or (when both sides changed) keep the newer side.
/// Nothing is ever destroyed silently: whatever gets replaced or removed here is first zipped into
/// `…/OpenPrism/sync-backups/`, and a Drive copy that gets overwritten is saved there first.
///
/// Deletions follow the same rule: a project removed on one Mac is removed from Drive and then, on the
/// other Mac, moved to the backups folder — but only if that Mac hasn't changed it since.
///
/// Left out on purpose: OpenPrism's compile output (`.compile/`, rebuilt on demand), and OpenPrism's own
/// settings (API keys live in its page storage, not in these folders, and secrets stay on each Mac).
enum DriveOpenPrismSync {
    static let namePrefix = "op-"
    static let nameSuffix = ".zip"
    private static let stateKey = "maziar.googleDrive.openPrismState"

    struct Summary {
        var uploaded = 0
        var downloaded = 0
        var removedFromDrive = 0
        var movedToBackups = 0
        var failures: [String] = []

        var didChangeLocalFiles: Bool { downloaded > 0 || movedToBackups > 0 }
        var isEmpty: Bool { uploaded + downloaded + removedFromDrive + movedToBackups == 0 }
        var text: String {
            var parts: [String] = []
            if uploaded > 0 { parts.append("\(uploaded) uploaded") }
            if downloaded > 0 { parts.append("\(downloaded) downloaded") }
            if removedFromDrive > 0 { parts.append("\(removedFromDrive) removed from Drive") }
            if movedToBackups > 0 { parts.append("\(movedToBackups) moved to backups") }
            return parts.isEmpty ? "up to date" : parts.joined(separator: ", ")
        }
    }

    private struct RemoteFile { let id: String; let modified: String }
    private struct ProjectState: Codable { var fingerprint: String; var remoteModified: String }
    private struct Scan { let fingerprint: String; let latest: Date }

    // MARK: - Locations

    static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maziar/OpenPrism", isDirectory: true)
    }
    static var dataDirectory: URL { baseDirectory.appendingPathComponent("data", isDirectory: true) }
    static var backupDirectory: URL { baseDirectory.appendingPathComponent("sync-backups", isDirectory: true) }

    private static func projectDirectory(_ id: String) -> URL { dataDirectory.appendingPathComponent(id, isDirectory: true) }
    private static func isProject(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.json").path)
    }

    private static func localProjectIDs() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { isProject($0) }.map(\.lastPathComponent)
    }

    // MARK: - One pass

    static func sync(token: String) async throws -> Summary {
        let remote = try await list(token: token)
        var states = loadStates()
        var summary = Summary()
        let ids = Set(localProjectIDs()).union(remote.keys).sorted()
        for id in ids {
            do {
                try await syncOne(id, remote: remote[id], token: token, states: &states, summary: &summary)
            } catch {
                summary.failures.append("\(id.prefix(8)): \(error.localizedDescription)")
            }
        }
        saveStates(states)
        return summary
    }

    private static func syncOne(_ id: String, remote: RemoteFile?, token: String,
                                states: inout [String: ProjectState], summary: inout Summary) async throws {
        let directory = projectDirectory(id)
        let localExists = isProject(directory)
        let state = states[id]

        switch (localExists, remote) {
        case (false, nil):
            states[id] = nil

        case (true, nil):
            let scan = try scanDirectory(directory)
            if let state, state.fingerprint == scan.fingerprint {
                // Synced before, gone from Drive, untouched here → it was deleted on another Mac.
                try await backupLocal(id)
                try FileManager.default.removeItem(at: directory)
                states[id] = nil
                summary.movedToBackups += 1
            } else {
                let modified = try await uploadProject(id, existing: nil, token: token)
                states[id] = ProjectState(fingerprint: scan.fingerprint, remoteModified: modified)
                summary.uploaded += 1
            }

        case (false, let remote?):
            if let state, state.remoteModified == remote.modified {
                // Synced before, gone here, Drive unchanged → it was deleted on this Mac.
                try await deleteRemote(id: remote.id, token: token)
                states[id] = nil
                summary.removedFromDrive += 1
            } else {
                states[id] = try await downloadProject(id, remote: remote, token: token)
                summary.downloaded += 1
            }

        case (true, let remote?):
            let scan = try scanDirectory(directory)
            let localChanged = state?.fingerprint != scan.fingerprint
            let remoteChanged = state?.remoteModified != remote.modified
            switch (localChanged, remoteChanged) {
            case (false, false):
                break
            case (true, false):
                let modified = try await uploadProject(id, existing: remote.id, token: token)
                states[id] = ProjectState(fingerprint: scan.fingerprint, remoteModified: modified)
                summary.uploaded += 1
            case (false, true):
                states[id] = try await downloadProject(id, remote: remote, token: token)
                summary.downloaded += 1
            case (true, true):
                // Edited on both Macs since they last agreed (or never compared): the newer side wins and
                // the other is saved to the backups folder first.
                if let remoteDate = parseDate(remote.modified), remoteDate > scan.latest {
                    try await backupLocal(id)
                    states[id] = try await downloadProject(id, remote: remote, token: token)
                    summary.downloaded += 1
                } else {
                    try await backupRemote(id, remote: remote, token: token)
                    let modified = try await uploadProject(id, existing: remote.id, token: token)
                    states[id] = ProjectState(fingerprint: scan.fingerprint, remoteModified: modified)
                    summary.uploaded += 1
                }
            }
        }
    }

    // MARK: - Transfer

    private static func uploadProject(_ id: String, existing: String?, token: String) async throws -> String {
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("maziar-op-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        try await makeZip(of: projectDirectory(id), to: zip)
        return try await resumableUpload(token: token, name: namePrefix + id + nameSuffix, existingID: existing, file: zip)
    }

    /// Replaces the local folder with Drive's copy; returns the state to remember.
    private static func downloadProject(_ id: String, remote: RemoteFile, token: String) async throws -> ProjectState {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("maziar-op-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("project.zip")
        try await downloadFile(token: token, id: remote.id, to: zip)
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        try await run("/usr/bin/unzip", ["-oq", zip.path, "-d", extracted.path], cwd: nil)
        guard isProject(extracted) else { throw SyncFailure("the downloaded project was incomplete") }

        try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let destination = projectDirectory(id)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: extracted, to: destination)
        return ProjectState(fingerprint: try scanDirectory(destination).fingerprint, remoteModified: remote.modified)
    }

    private static func backupLocal(_ id: String) async throws {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try await makeZip(of: projectDirectory(id), to: backupDirectory.appendingPathComponent("\(id)-local-\(stamp()).zip"))
    }

    private static func backupRemote(_ id: String, remote: RemoteFile, token: String) async throws {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try await downloadFile(token: token, id: remote.id, to: backupDirectory.appendingPathComponent("\(id)-drive-\(stamp()).zip"))
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - Local scan and zip

    /// A fingerprint of the project's files (names, sizes, modification times) and the newest change in it.
    /// `.compile/` (build output) and `.DS_Store` are ignored.
    private static func scanDirectory(_ directory: URL) throws -> Scan {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            throw SyncFailure("couldn't read the project folder")
        }
        let rootPath = directory.standardizedFileURL.path
        var lines: [String] = []
        var latest = Date.distantPast
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == ".compile" { enumerator.skipDescendants(); continue }
            if name == ".DS_Store" { continue }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            latest = max(latest, modified)
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count))
            lines.append("\(relative)|\(values.fileSize ?? 0)|\(Int(modified.timeIntervalSince1970))")
        }
        let digest = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8))
        return Scan(fingerprint: digest.map { String(format: "%02x", $0) }.joined(), latest: latest)
    }

    private static func makeZip(of directory: URL, to zip: URL) async throws {
        try? FileManager.default.removeItem(at: zip)
        try await run("/usr/bin/zip", ["-qr", "-X", zip.path, ".", "-x", ".compile/*", "-x", "*.DS_Store"], cwd: directory)
    }

    private struct SyncFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func run(_ tool: String, _ arguments: [String], cwd: URL?) async throws {
        let status: Int32 = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.currentDirectoryURL = cwd
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
        // zip exits 12 when there was nothing to add; unzip exits 1 for warnings only.
        guard status == 0 || (tool.hasSuffix("zip") && status == 12) || (tool.hasSuffix("unzip") && status == 1) else {
            throw SyncFailure("\((tool as NSString).lastPathComponent) failed (exit code \(status))")
        }
    }

    // MARK: - Remembered state (stays on this Mac: `maziar.googleDrive.` keys aren't synced)

    private static func loadStates() -> [String: ProjectState] {
        UserDefaults.standard.data(forKey: stateKey)
            .flatMap { try? JSONDecoder().decode([String: ProjectState].self, from: $0) } ?? [:]
    }

    private static func saveStates(_ states: [String: ProjectState]) {
        if let data = try? JSONEncoder().encode(states) { UserDefaults.standard.set(data, forKey: stateKey) }
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    // MARK: - Drive REST

    private static func check(_ response: URLResponse, _ body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw GoogleDriveAccount.SyncError.http(0, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw GoogleDriveAccount.SyncError.http(http.statusCode, body.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }
    }

    /// Project id → Drive file, for every `op-<id>.zip` in the app-data folder.
    private static func list(token: String) async throws -> [String: RemoteFile] {
        var result: [String: RemoteFile] = [:]
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            components.queryItems = [
                URLQueryItem(name: "spaces", value: "appDataFolder"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,modifiedTime)"),
                URLQueryItem(name: "pageSize", value: "1000"),
            ]
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try check(response, data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            for file in (json?["files"] as? [[String: Any]]) ?? [] {
                guard let name = file["name"] as? String, name.hasPrefix(namePrefix), name.hasSuffix(nameSuffix),
                      let fileID = file["id"] as? String, let modified = file["modifiedTime"] as? String else { continue }
                let id = String(name.dropFirst(namePrefix.count).dropLast(nameSuffix.count))
                result[id] = RemoteFile(id: fileID, modified: modified)
            }
            pageToken = json?["nextPageToken"] as? String
        } while pageToken != nil
        return result
    }

    /// Creates the file, or replaces its content when `existingID` is given. Returns Drive's new `modifiedTime`.
    private static func resumableUpload(token: String, name: String, existingID: String?, file: URL) async throws -> String {
        let base = "https://www.googleapis.com/upload/drive/v3/files"
        let endpoint = existingID.map { "\(base)/\($0)" } ?? base
        var start = URLRequest(url: URL(string: "\(endpoint)?uploadType=resumable&fields=id,modifiedTime")!)
        start.httpMethod = existingID == nil ? "POST" : "PATCH"
        start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let metadata: [String: Any] = existingID == nil ? ["name": name, "parents": ["appDataFolder"]] : [:]
        start.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        let (startData, startResponse) = try await URLSession.shared.data(for: start)
        try check(startResponse, startData)
        guard let http = startResponse as? HTTPURLResponse, let location = http.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: location) else {
            throw GoogleDriveAccount.SyncError.http(0, "no upload session")
        }
        var put = URLRequest(url: sessionURL)
        put.httpMethod = "PUT"
        let (putData, putResponse) = try await URLSession.shared.upload(for: put, fromFile: file)
        try check(putResponse, putData)
        let json = try JSONSerialization.jsonObject(with: putData) as? [String: Any]
        guard let modified = json?["modifiedTime"] as? String else { throw GoogleDriveAccount.SyncError.http(0, "no modified time") }
        return modified
    }

    private static func downloadFile(token: String, id: String, to destination: URL) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        try check(response)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func deleteRemote(id: String, token: String) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
    }
}

extension Notification.Name {
    /// Posted after OpenPrism project folders were changed by a Drive sync.
    static let openPrismProjectsChanged = Notification.Name("maziar.openPrismProjectsChanged")
}
