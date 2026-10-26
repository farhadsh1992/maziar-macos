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

            googleDriveSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 320)
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
    private var googleDriveSection: some View {
        Section {
            if drive.isSignedIn {
                LabeledContent("Signed in as", value: drive.email ?? "Google account")
                LabeledContent("Last synced", value: drive.lastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                Toggle("Sync automatically", isOn: $drive.autoSync)
                HStack {
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
                TextField("OAuth client ID", text: $drive.clientID)
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
            Text("With \u{201c}Sync automatically\u{201d} on, Maziar checks Google Drive when it opens, when you switch back to it, and every few minutes, loads newer data from your other devices, and uploads your changes about ten seconds after you make them. If both sides changed, it asks which copy to keep rather than overwriting either. Saves Maziar's own data — library list, groups, labels, notebook templates, settings, tracked papers/conferences/journals — to a private app folder in your Google Drive, and loads it on another Mac signed in to the same account. PDFs and notes files are not uploaded here; they stay in the Library's connected folder (point it at Google Drive for desktop to share them). API keys and this Mac's folder path and LaTeX install are never synced. To sign in you need your own OAuth client: in Google Cloud Console, enable the Google Drive API and create an OAuth client ID of type \u{201c}Desktop app\u{201d}, then paste its ID and secret above.")
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
