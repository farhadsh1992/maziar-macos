import Foundation
import Network
import CryptoKit
import AppKit

/// Google sign-in plus a single-file snapshot sync of Maziar's own state (library list, groups,
/// labels, notebook templates, settings, tracked papers/conferences/journals — everything
/// `AppSettingsBackupService.cloudExportData()` captures) to the signed-in account's Google Drive.
///
/// Uses OAuth 2.0 for installed apps: PKCE, a loopback redirect to a short-lived local listener,
/// and the `drive.appdata` scope — a private, hidden per-app folder in the user's Drive that this
/// app alone can read or write, which keeps the scope non-sensitive (no Google app verification
/// needed) at the cost of not being able to see the user's ordinary Drive files. That means PDFs
/// are *not* synced by this; they live in the Library's own connected folder (pointed at Drive for
/// desktop), same as before. The OAuth client ID/secret are entered by the user in Settings since
/// they come from their own Google Cloud project; none ship with the app.
@MainActor
final class GoogleDriveAccount: ObservableObject {
    static let shared = GoogleDriveAccount()

    enum SyncError: LocalizedError {
        case notConfigured
        case notSignedIn
        case authorizationFailed(String)
        case http(Int, String)
        case nothingInDrive
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Enter your Google OAuth client ID and secret first."
            case .notSignedIn: return "Sign in with Google first."
            case .authorizationFailed(let reason): return "Google sign-in failed: \(reason)"
            case .http(let code, let body): return "Google returned HTTP \(code): \(body)"
            case .nothingInDrive: return "No Maziar data has been uploaded to this Google Drive account yet."
            case .timedOut: return "Sign-in timed out waiting for the browser."
            }
        }
    }

    @Published var clientID: String { didSet { KeychainHelper.set(clientID, forKey: Self.clientIDKey) } }
    @Published var clientSecret: String { didSet { KeychainHelper.set(clientSecret, forKey: Self.clientSecretKey) } }
    @Published private(set) var email: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var isBusy = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    var isSignedIn: Bool { KeychainHelper.get(forKey: Self.refreshTokenKey) != nil }
    var isConfigured: Bool { !clientID.trimmingCharacters(in: .whitespaces).isEmpty && !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty }

    private static let clientIDKey = "googleDrive.clientID"
    private static let clientSecretKey = "googleDrive.clientSecret"
    private static let refreshTokenKey = "googleDrive.refreshToken"
    private static let emailDefaultsKey = "maziar.googleDrive.email"
    private static let lastSyncDefaultsKey = "maziar.googleDrive.lastSync"
    private static let stateFileName = "maziar-state.plist"
    private static let autoSyncKey = "maziar.googleDrive.autoSync"
    private static let lastRemoteKey = "maziar.googleDrive.lastRemoteModified"
    private static let dirtyKey = "maziar.googleDrive.localDirty"

    /// Check Drive when Maziar opens/regains focus/every few minutes, and upload shortly after a local
    /// change. On by default once signed in — the whole point of signing in is not having to remember.
    @Published var autoSync: Bool {
        didSet {
            UserDefaults.standard.set(autoSync, forKey: Self.autoSyncKey)
            autoSync ? startAutoSyncIfNeeded() : stopAutoSync()
        }
    }

    /// The Drive file's `modifiedTime` as of this Mac's last successful sync — if Drive's current one
    /// differs, some *other* device has uploaded since. `nil` means this Mac has never synced.
    private var lastSyncedRemote: String? {
        get { UserDefaults.standard.string(forKey: Self.lastRemoteKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastRemoteKey) }
    }
    /// True when this Mac has changed something Drive doesn't have yet.
    private var localDirty: Bool {
        get { UserDefaults.standard.bool(forKey: Self.dirtyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.dirtyKey) }
    }

    struct Stores {
        let app: AppSettings, ai: AISettings, tex: TeXInstallationManager, conference: ConferenceStore
        let journal: JournalStore, paper: PaperStore, library: LibraryStore, cv: CVAutofillStore
    }
    private var stores: Stores?
    private var changeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var lastFingerprint: Data?
    private var lastCheck = Date.distantPast
    private var suppressChangesUntil = Date.distantPast
    private var isPromptingConflict = false

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast

    private init() {
        clientID = KeychainHelper.get(forKey: Self.clientIDKey) ?? ""
        clientSecret = KeychainHelper.get(forKey: Self.clientSecretKey) ?? ""
        email = UserDefaults.standard.string(forKey: Self.emailDefaultsKey)
        lastSync = UserDefaults.standard.object(forKey: Self.lastSyncDefaultsKey) as? Date
        autoSync = UserDefaults.standard.object(forKey: Self.autoSyncKey) as? Bool ?? true
    }

    // MARK: - Sign in / out

    func signIn() async {
        await run {
            guard self.isConfigured else { throw SyncError.notConfigured }
            let verifier = Self.randomURLSafeString(byteCount: 64)
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            let state = Self.randomURLSafeString(byteCount: 16)

            let (code, redirect) = try await self.authorize(challenge: challenge, state: state)
            let tokens = try await self.tokenRequest([
                "code": code,
                "client_id": self.clientID,
                "client_secret": self.clientSecret,
                "code_verifier": verifier,
                "redirect_uri": redirect,
                "grant_type": "authorization_code",
            ])
            guard let refresh = tokens["refresh_token"] as? String else {
                throw SyncError.authorizationFailed("Google didn't return a refresh token — remove Maziar from your Google account's third-party access list and try again.")
            }
            KeychainHelper.set(refresh, forKey: Self.refreshTokenKey)
            self.store(tokens)
            let address = (tokens["id_token"] as? String).flatMap(Self.emailFromIDToken)
            self.email = address
            UserDefaults.standard.set(address, forKey: Self.emailDefaultsKey)
            self.statusMessage = "Signed in\(address.map { " as \($0)" } ?? "")."
        }
        if isSignedIn { startAutoSyncIfNeeded() }
    }

    func signOut() {
        stopAutoSync()
        lastSyncedRemote = nil
        localDirty = false
        KeychainHelper.delete(forKey: Self.refreshTokenKey)
        accessToken = nil
        email = nil
        UserDefaults.standard.removeObject(forKey: Self.emailDefaultsKey)
        statusMessage = "Signed out."
        errorMessage = nil
    }

    // MARK: - Manual sync

    func upload() async {
        await run {
            let token = try await self.validAccessToken()
            let remote = try await self.remoteMeta(token: token)
            try await self.uploadSnapshot(token: token, existingID: remote?.id)
            self.statusMessage = "Uploaded to Google Drive."
        }
    }

    /// Returns the snapshot and the Drive `modifiedTime` it corresponds to, for the caller to
    /// confirm and hand to `applySnapshot` — or `nil` if the request failed (see `errorMessage`).
    func downloadSnapshot() async -> (data: Data, modified: String?)? {
        var result: (Data, String?)?
        await run {
            let token = try await self.validAccessToken()
            guard let remote = try await self.remoteMeta(token: token) else { throw SyncError.nothingInDrive }
            result = (try await self.fetchSnapshot(token: token, id: remote.id), remote.modified)
        }
        return result
    }

    /// Imports a Drive snapshot into the running app and records this Mac as now in sync with it.
    func applySnapshot(_ data: Data, remoteModified: String?) throws {
        guard let s = stores else { throw SyncError.notSignedIn }
        suppressChangesUntil = Date().addingTimeInterval(15)
        try AppSettingsBackupService.importData(
            data, appSettings: s.app, aiSettings: s.ai, texManager: s.tex, conferenceStore: s.conference,
            journalStore: s.journal, paperStore: s.paper, libraryStore: s.library, cvAutofillStore: s.cv,
            skipMachineSpecific: true
        )
        lastSyncedRemote = remoteModified
        localDirty = false
        lastFingerprint = currentFingerprint()
        markSynced()
    }

    func markSynced() {
        lastSync = Date()
        UserDefaults.standard.set(lastSync, forKey: Self.lastSyncDefaultsKey)
    }

    // MARK: - Automatic sync

    func attach(_ stores: Stores) {
        self.stores = stores
        startAutoSyncIfNeeded()
    }

    func startAutoSyncIfNeeded() {
        guard isSignedIn, autoSync, stores != nil, changeObserver == nil else { return }
        lastFingerprint = currentFingerprint()
        changeObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleLocalChangeCheck() }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.autoSyncCheck(minimumInterval: 30) }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.autoSyncCheck(minimumInterval: 60) }
        }
        Task { await autoSyncCheck(minimumInterval: 0) }
    }

    func stopAutoSync() {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        changeObserver = nil
        activeObserver = nil
        pollTimer?.invalidate()
        pollTimer = nil
        debounceTask?.cancel()
    }

    /// Any `UserDefaults` write (including unrelated system ones) lands here; wait for ten quiet
    /// seconds, then only treat it as a real local edit if the actual Maziar data differs from what
    /// was last synced.
    private func scheduleLocalChangeCheck() {
        guard Date() >= suppressChangesUntil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, Date() >= self.suppressChangesUntil else { return }
            let fingerprint = self.currentFingerprint()
            guard fingerprint != self.lastFingerprint else { return }
            self.lastFingerprint = fingerprint
            self.localDirty = true
            await self.autoSyncCheck(minimumInterval: 0)
        }
    }

    private func currentFingerprint() -> Data? {
        (try? AppSettingsBackupService.cloudExportData()).map { Data(SHA256.hash(data: $0)) }
    }

    /// One reconciliation pass: compare Drive's copy against what this Mac last synced and whether
    /// it has changed since, then upload, download, or ask — never silently overwriting data that
    /// exists only on one side.
    func autoSyncCheck(minimumInterval: TimeInterval) async {
        guard isSignedIn, autoSync, stores != nil, !isBusy,
              Date().timeIntervalSince(lastCheck) >= minimumInterval else { return }
        lastCheck = Date()
        await run {
            let token = try await self.validAccessToken()
            guard let remote = try await self.remoteMeta(token: token) else {
                try await self.uploadSnapshot(token: token, existingID: nil)
                self.statusMessage = "Uploaded to Google Drive."
                return
            }
            if self.lastSyncedRemote == nil {
                try await self.resolveConflict(token: token, remote: remote, firstSync: true)
            } else if remote.modified != self.lastSyncedRemote {
                if self.localDirty {
                    try await self.resolveConflict(token: token, remote: remote, firstSync: false)
                } else {
                    let data = try await self.fetchSnapshot(token: token, id: remote.id)
                    try self.applySnapshot(data, remoteModified: remote.modified)
                    self.statusMessage = "Updated from Google Drive (changed on another device)."
                }
            } else if self.localDirty {
                try await self.uploadSnapshot(token: token, existingID: remote.id)
                self.statusMessage = "Uploaded to Google Drive."
            }
        }
    }

    private func resolveConflict(token: String, remote: (id: String, modified: String?), firstSync: Bool) async throws {
        guard !isPromptingConflict else { return }
        isPromptingConflict = true
        defer { isPromptingConflict = false }
        let alert = NSAlert()
        alert.messageText = firstSync ? "Google Drive already has Maziar data" : "Maziar data changed on two devices"
        alert.informativeText = firstSync
            ? "This Mac hasn't synced with Google Drive before. Use the copy in Drive (replacing this Mac's library list and settings), or keep this Mac's data and overwrite Drive's?"
            : "This Mac and another device both changed Maziar data since the last sync. Only one version can be kept."
        alert.addButton(withTitle: "Use Google Drive Copy")
        alert.addButton(withTitle: "Keep This Mac's Data")
        alert.addButton(withTitle: "Decide Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let data = try await fetchSnapshot(token: token, id: remote.id)
            try applySnapshot(data, remoteModified: remote.modified)
            statusMessage = "Loaded from Google Drive."
        case .alertSecondButtonReturn:
            try await uploadSnapshot(token: token, existingID: remote.id)
            statusMessage = "Uploaded to Google Drive."
        default:
            statusMessage = "Sync paused until you choose which copy to keep."
            lastCheck = Date().addingTimeInterval(600)
        }
    }

    private func remoteMeta(token: String) async throws -> (id: String, modified: String?)? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: "name = '\(Self.stateFileName)'"),
            URLQueryItem(name: "fields", value: "files(id,modifiedTime)"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await Self.send(request)
        let file = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["files"] as? [[String: Any]])?.first
        guard let id = file?["id"] as? String else { return nil }
        return (id, file?["modifiedTime"] as? String)
    }

    private func fetchSnapshot(token: String, id: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await Self.send(request)
    }

    /// Creates or overwrites the Drive snapshot, then records the new Drive `modifiedTime` so this
    /// Mac's own upload isn't later mistaken for "another device changed it."
    private func uploadSnapshot(token: String, existingID: String?) async throws {
        let data = try AppSettingsBackupService.cloudExportData()
        var request: URLRequest
        if let existingID {
            request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(existingID)?uploadType=media&fields=id,modifiedTime")!)
            request.httpMethod = "PATCH"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        } else {
            let boundary = "maziar-\(UUID().uuidString)"
            let metadata = #"{"name":"\#(Self.stateFileName)","parents":["appDataFolder"]}"#
            var body = Data()
            body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(metadata)\r\n".utf8))
            body.append(Data("--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n--\(boundary)--".utf8))
            request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,modifiedTime")!)
            request.httpMethod = "POST"
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await Self.send(request)
        let modified = (try? JSONSerialization.jsonObject(with: response) as? [String: Any])?["modifiedTime"] as? String
        suppressChangesUntil = Date().addingTimeInterval(5)
        lastSyncedRemote = modified
        localDirty = false
        lastFingerprint = currentFingerprint()
        markSynced()
    }

    // MARK: - Internals

    private func run(_ work: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        do { try await work() } catch { errorMessage = error.localizedDescription }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refresh = KeychainHelper.get(forKey: Self.refreshTokenKey) else { throw SyncError.notSignedIn }
        guard isConfigured else { throw SyncError.notConfigured }
        let tokens = try await tokenRequest([
            "refresh_token": refresh,
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "refresh_token",
        ])
        store(tokens)
        guard let accessToken else { throw SyncError.notSignedIn }
        return accessToken
    }

    private func store(_ tokens: [String: Any]) {
        accessToken = tokens["access_token"] as? String
        accessTokenExpiry = Date().addingTimeInterval((tokens["expires_in"] as? Double) ?? 3000)
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        let data = try await Self.send(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.authorizationFailed("unreadable token response")
        }
        return json
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.http(0, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw SyncError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Opens the browser at Google's consent page and waits for it to redirect back to a one-shot
    /// listener on 127.0.0.1 (a random free port — the loopback redirect Google allows for desktop
    /// clients). Returns the authorization code and the exact redirect URI used, which the token
    /// request must repeat.
    private func authorize(challenge: String, state: String) async throws -> (String, String) {
        let box = try LoopbackBox()
        let id = clientID
        let port: UInt16 = try await box.start()
        let redirect = "http://127.0.0.1:\(port)"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email https://www.googleapis.com/auth/drive.appdata"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(components.url!)
        let query = try await box.waitForRedirect(timeout: 180)
        if let error = query["error"] { throw SyncError.authorizationFailed(error) }
        guard query["state"] == state, let code = query["code"] else {
            throw SyncError.authorizationFailed("the response didn't match this sign-in attempt")
        }
        return (code, redirect)
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func emailFromIDToken(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

/// A one-shot HTTP listener on a random loopback port that captures the single OAuth redirect.
private final class LoopbackBox: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var redirectContinuation: CheckedContinuation<[String: String], Error>?
    private var pendingQuery: [String: String]?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); startContinuation = continuation; lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port?.rawValue { self.finishStart(.success(port)) }
                case .failed(let error):
                    self.finishStart(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: .global())
        }
    }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        defer { listener.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingQuery {
                lock.unlock()
                continuation.resume(returning: pendingQuery)
                return
            }
            redirectContinuation = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finishRedirect(.failure(GoogleDriveAccount.SyncError.timedOut))
            }
        }
    }

    private func finishStart(_ result: Result<UInt16, Error>) {
        lock.lock(); let continuation = startContinuation; startContinuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }

    private func finishRedirect(_ result: Result<[String: String], Error>) {
        lock.lock()
        let continuation = redirectContinuation
        redirectContinuation = nil
        if continuation == nil, case .success(let query) = result { pendingQuery = query }
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.components(separatedBy: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = line.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : ""
            let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
            // Ignore stray requests (e.g. a favicon fetch) that carry neither a code nor an error.
            guard items.contains(where: { $0.name == "code" || $0.name == "error" }) else {
                connection.cancel()
                return
            }
            let page = "<html><body style=\"font-family:-apple-system;text-align:center;padding:60px\"><h2>Maziar is connected to Google Drive.</h2><p>You can close this tab and return to the app.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            self.finishRedirect(.success(Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })))
        }
    }
}
