import Foundation

/// Project pictures in the Drive app-data folder: one file per picture, named
/// `img-<project id>-<file name>`, next to the settings snapshot. Plain REST calls with the same
/// `drive.appdata` access token the snapshot sync already uses.
enum DriveImageFiles {
    static let namePrefix = "img-"

    private static func check(_ response: URLResponse, _ body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw GoogleDriveAccount.SyncError.http(0, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw GoogleDriveAccount.SyncError.http(http.statusCode, body.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }
    }

    /// Remote picture file name → Drive file id.
    static func list(token: String) async throws -> [String: String] {
        var result: [String: String] = [:]
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            components.queryItems = [
                URLQueryItem(name: "spaces", value: "appDataFolder"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name)"),
                URLQueryItem(name: "pageSize", value: "1000"),
            ]
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try check(response, data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            for file in (json?["files"] as? [[String: Any]]) ?? [] {
                if let name = file["name"] as? String, name.hasPrefix(namePrefix), let id = file["id"] as? String {
                    result[name] = id
                }
            }
            pageToken = json?["nextPageToken"] as? String
        } while pageToken != nil
        return result
    }

    /// Resumable upload, so a large photo isn't limited by the simple-upload size cap.
    static func upload(token: String, name: String, file: URL) async throws {
        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable")!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "parents": ["appDataFolder"]])
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
    }

    static func download(token: String, id: String, to destination: URL) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        try check(response)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

extension Notification.Name {
    /// Posted after a Drive snapshot was applied to the running app.
    static let maziarSettingsImported = Notification.Name("maziar.settingsImported")
    /// Posted after project pictures were downloaded from Drive.
    static let projectImagesChanged = Notification.Name("maziar.projectImagesChanged")
}
