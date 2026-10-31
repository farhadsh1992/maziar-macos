import SwiftUI

/// One third-party site Maziar embeds elsewhere in the app (custom pages, the Reader's AI Chat
/// mode) that requires signing in. Not persisted — just a fixed, known catalog of sign-in targets.
struct AccountService: Identifiable {
    let id: String
    let name: String
    let signInURLString: String
    let icon: String
}

let knownAccountServices: [AccountService] = [
    AccountService(id: "chatgpt", name: "ChatGPT / OpenAI", signInURLString: "https://chatgpt.com", icon: "bubble.left.and.bubble.right"),
    AccountService(id: "google", name: "Google", signInURLString: "https://accounts.google.com", icon: "globe"),
    AccountService(id: "claude", name: "Claude", signInURLString: "https://claude.ai/new", icon: "sparkle"),
]

/// Settings → Accounts: sign in once to a site here, and every other embedded page in the app that
/// loads the same site (a custom page, the Reader's AI Chat mode set to ChatGPT/Claude, etc.) is
/// already signed in too — no extra plumbing needed for that part, since every embedded `WKWebView`
/// in the app already shares one persistent `WKWebsiteDataStore` (WebKit's default one; nothing in
/// this codebase ever opts into a private/non-persistent store), so cookies set from signing in here
/// are simply the same cookies every other page already reads, and they survive an app relaunch the
/// same way a browser's own logins do. This tab is just a convenient, dedicated place to *do* that
/// sign-in once, rather than needing to add a custom page or reach a sign-in wall while trying to
/// use one page's embedded chat.
struct AccountsSettingsTab: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var drive = GoogleDriveAccount.shared
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var aiSettings: AISettings
    @EnvironmentObject var texManager: TeXInstallationManager
    @EnvironmentObject var conferenceStore: ConferenceStore
    @EnvironmentObject var journalStore: JournalStore
    @EnvironmentObject var paperStore: PaperStore
    @EnvironmentObject var libraryStore: LibraryStore
    @State private var driveRoots: [URL] = []
    @State private var pendingDownload: (data: Data, modified: String?)?
    @State private var showDownloadConfirm = false

    var body: some View {
        Form {
            Section {
                ForEach(knownAccountServices) { service in
                    HStack {
                        Image(systemName: service.icon)
                            .frame(width: 20)
                        Text(service.name)
                        Spacer()
                        Button("Sign In…") {
                            openWindow(id: "account-signin", value: service.id)
                        }
                    }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Sign in to a site here once — every page in Maziar that embeds the same site (a custom page you've added, or the Reader's AI Chat mode set to ChatGPT/Claude) shares the same signed-in session automatically, and it stays signed in across app restarts, the same as a real browser.")
                    .font(.caption)
            }

            storageFolderSection
            googleDriveSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 320)
        .onAppear { driveRoots = LibraryStore.suggestedDriveRoots() }
        .confirmationDialog(
            "Replace this Mac's Maziar data with the copy in Google Drive?",
            isPresented: $showDownloadConfirm,
            titleVisibility: .visible
        ) {
            Button("Replace with Drive Copy", role: .destructive) { applyDownload() }
            Button("Cancel", role: .cancel) { pendingDownload = nil }
        } message: {
            Text("Your library list, groups, labels, settings and tracked papers/conferences/journals are overwritten by what was last uploaded. Anything here that was never uploaded is lost.")
        }
    }

    @ViewBuilder
    private var storageFolderSection: some View {
        Section {
            if let path = libraryStore.folderPath {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Label("Not connected", systemImage: "folder.badge.questionmark")
                    .foregroundStyle(.secondary)
            }

            if !driveRoots.isEmpty {
                ForEach(driveRoots, id: \.self) { root in
                    Button {
                        openPicker(startingAt: root)
                    } label: {
                        Label(root.lastPathComponent.replacingOccurrences(of: "GoogleDrive-", with: ""), systemImage: "folder.badge.gearshape")
                    }
                }
            }

            Button {
                openPicker(startingAt: nil)
            } label: {
                Label(libraryStore.folderPath == nil ? "Connect Folder…" : "Change Folder…", systemImage: "folder.badge.plus")
            }

            if libraryStore.folderPath != nil {
                Button("Reveal in Finder") {
                    if let url = libraryStore.folderURL { NSWorkspace.shared.open(url) }
                }
                Button("Disconnect", role: .destructive) { libraryStore.disconnect() }
            }
        } header: {
            Text("Storage Folder")
        } footer: {
            Text("Where your papers (and their notes files) actually live — point this at a folder inside your Google Drive for Desktop sync (detected accounts are listed above as shortcuts) so everything you add here is backed up automatically. Maziar just watches whatever folder you pick, the same way it would watch any other local folder; signing in with Google below is separate and only syncs Maziar's own data.")
                .font(.caption)
        }
    }

    private func openPicker(startingAt url: URL?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Connect"
        panel.message = "Choose or create a folder for your paper library"
        if let url { panel.directoryURL = url }
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        libraryStore.connect(picked)
    }

    @ViewBuilder
    private var googleDriveSection: some View {
        Section {
            HStack(spacing: 12) {
                AccountAvatar(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Your name", text: $drive.displayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    Text(drive.email ?? "Not signed in").font(.caption).foregroundStyle(.secondary)
                    Text("The name and picture show on the account button at the top of the left sidebar.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Picture…") { drive.chooseProfileImage() }
                if drive.profileImage != nil {
                    Button("Remove") { drive.clearProfileImage() }
                }
            }
            if drive.isSignedIn {
                LabeledContent("Signed in as", value: drive.email ?? "Google account")
                LabeledContent("Last synced", value: drive.lastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                Toggle("Sync automatically", isOn: $drive.autoSync)
                HStack {
                    Button("Sync Now") { Task { await drive.syncNow() } }
                        .help("Check Google Drive now: load newer data from other devices and upload this Mac's changes")
                    Button("Upload to Drive") { Task { await drive.upload() } }
                    Button("Download from Drive") {
                        Task {
                            if let snapshot = await drive.downloadSnapshot() {
                                pendingDownload = snapshot
                                showDownloadConfirm = true
                            }
                        }
                    }
                    Spacer()
                    Button("Sign Out", role: .destructive) { drive.signOut() }
                }
                .disabled(drive.isBusy)
            } else {
                Label(drive.isConfigured
                      ? "Not syncing \u{2014} click \u{201c}Sign in with Google\u{201d} below. Nothing is saved to or loaded from Google Drive until you do."
                      : "Not syncing \u{2014} enter both the OAuth client ID and the client secret below, then sign in. Nothing is saved to or loaded from Google Drive until you do.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                TextField("OAuth client ID", text: $drive.clientID)
                if !drive.clientID.trimmingCharacters(in: .whitespaces).isEmpty && !drive.clientIDLooksValid {
                    Label("That doesn't look like a client ID. It must end in .apps.googleusercontent.com (it isn't your email or a project name). Copy it from Google Cloud Console \u{2192} APIs & Services \u{2192} Credentials.",
                          systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                SecureField("OAuth client secret", text: $drive.clientSecret)
                Button("Sign in with Google") { Task { await drive.signIn() } }
                    .disabled(!drive.isConfigured || drive.isBusy)
            }
            if drive.isBusy { ProgressView().controlSize(.small) }
            if let status = drive.statusMessage {
                Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            }
            if let error = drive.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        } header: {
            Text("Google Drive Sync")
        } footer: {
            Text("With \u{201c}Sync automatically\u{201d} on, Maziar checks Google Drive when it opens, when you switch back to it, and every few minutes, loads newer data from your other devices, and uploads your changes about ten seconds after you make them. If both sides changed, it asks which copy to keep rather than overwriting either. Saves Maziar's own data — library list, groups, labels, notebook templates, settings, tracked papers/conferences/journals — to a private app folder in your Google Drive, and loads it on another Mac signed in to the same account. PDFs and notes files are not uploaded here; they stay in the Library's connected folder (point it at Google Drive for desktop to share them). Never synced, by design: the AI section, this Account section (including the picture), API keys, this Mac's folder path and LaTeX install. To sign in you need your own OAuth client: in Google Cloud Console, enable the Google Drive API and create an OAuth client ID of type \u{201c}Desktop app\u{201d}, then paste its ID and secret above.")
                .font(.caption)
        }
    }

    private func applyDownload() {
        guard let snapshot = pendingDownload else { return }
        pendingDownload = nil
        do {
            try drive.applySnapshot(snapshot.data, remoteModified: snapshot.modified)
            drive.statusMessage = "Loaded from Google Drive."
        } catch {
            drive.errorMessage = error.localizedDescription
        }
    }
}

/// The real, separate OS window a "Sign In…" button opens — just an embedded browser pointed at the
/// service's sign-in page, reusing `CustomWebPageView`'s whole toolbar/back-forward/download/popup
/// machinery instead of duplicating it for a one-off sign-in flow.
struct AccountSignInWindow: View {
    let serviceID: String?

    private var service: AccountService? {
        knownAccountServices.first { $0.id == serviceID }
    }

    var body: some View {
        if let service {
            CustomWebPageView(page: CustomWebPage(name: service.name, urlString: service.signInURLString))
        } else {
            Text("Unknown service").foregroundStyle(.secondary)
        }
    }
}

/// The round account picture (or a plain person glyph when none is set) — shared by the Settings
/// row where it's chosen and the sidebar button that shows it.
struct AccountAvatar: View {
    var size: CGFloat
    @ObservedObject private var drive = GoogleDriveAccount.shared

    var body: some View {
        Group {
            if let image = drive.profileImage {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
