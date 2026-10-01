import SwiftUI
import AppKit

@main
struct MaziarApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var store = ProjectStore()
    @StateObject private var texManager = TeXInstallationManager()
    @StateObject private var settings = AppSettings()
    @StateObject private var aiSettings = AISettings()
    @StateObject private var conferenceStore = ConferenceStore()
    @StateObject private var journalStore = JournalStore()
    @StateObject private var paperStore = PaperStore()
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var cvAutofillStore = CVAutofillStore()

    /// Remembers the Reader window's last size across launches — read here for `.defaultSize`
    /// (which only applies to brand-new windows going forward) and written by
    /// `PaperReaderWindow` itself whenever the user resizes one.
    @AppStorage("maziar.readerWindow.width") private var readerWindowWidth: Double = 900
    @AppStorage("maziar.readerWindow.height") private var readerWindowHeight: Double = 680

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(store)
                .environmentObject(texManager)
                .environmentObject(settings)
                .environmentObject(aiSettings)
                .environmentObject(conferenceStore)
                .environmentObject(journalStore)
                .environmentObject(paperStore)
                .environmentObject(libraryStore)
                .environmentObject(cvAutofillStore)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .tint(settings.color(for: .buttonColor))
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Maziar") {
                    var options: [NSApplication.AboutPanelOptionKey: Any] = [
                        .credits: NSAttributedString(
                            string: AppBranding.aboutText,
                            attributes: [.font: NSFont.systemFont(ofSize: 12)]
                        )
                    ]
                    if let logoImage = AppBranding.logoImage {
                        options[.applicationIcon] = logoImage
                    }
                    NSApplication.shared.orderFrontStandardAboutPanel(options: options)
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(texManager)
                .environmentObject(settings)
                .environmentObject(aiSettings)
                .environmentObject(conferenceStore)
                .environmentObject(journalStore)
                .environmentObject(paperStore)
                .environmentObject(libraryStore)
                .environmentObject(cvAutofillStore)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .tint(settings.color(for: .buttonColor))
        }

        // Two small companion windows for a Library paper, opened via
        // `openWindow(id:value:)` with the paper's UUID — real separate OS windows (not sheets)
        // so both can stay open side by side while reading, each looking the paper back up live
        // from `libraryStore` rather than being handed a frozen copy.
        WindowGroup(id: "paper-info", for: UUID.self) { $paperID in
            if let paperID {
                PaperInfoWindow(paperID: paperID)
                    .environmentObject(libraryStore)
                    .environmentObject(aiSettings)
                    .environmentObject(settings)
                    .environmentObject(texManager)
                    .preferredColorScheme(settings.appearanceMode.colorScheme)
                    .tint(settings.color(for: .buttonColor))
            }
        }
        .defaultSize(width: 460, height: 620)
        .windowResizability(.contentSize)

        WindowGroup(id: "paper-reader", for: UUID.self) { $paperID in
            if let paperID {
                PaperReaderWindow(paperID: paperID)
                    .environmentObject(libraryStore)
                    .environmentObject(aiSettings)
                    .environmentObject(settings)
                    .environmentObject(texManager)
                    .preferredColorScheme(settings.readerColorScheme())
                    .tint(settings.color(for: .buttonColor))
            }
        }
        .defaultSize(width: readerWindowWidth, height: readerWindowHeight)
        .windowResizability(.contentMinSize)

        // Opened from Settings → Accounts' "Sign In…" buttons — a small embedded browser for
        // signing in to a site once, shared automatically with every other page in the app that
        // embeds the same site (see `AccountsSettingsView.swift`'s own doc comment for why).
        WindowGroup(id: "account-signin", for: String.self) { $serviceID in
            AccountSignInWindow(serviceID: serviceID)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .tint(settings.color(for: .buttonColor))
        }
        .defaultSize(width: 520, height: 680)

        // The CV AutoFill panel's own "Setting" button — deliberately a separate window, not a tab
        // in Maziar's regular Settings, matching the original browser extension's own separate
        // Options page (see `CVAutofillSettingsWindow`'s own doc comment).
        WindowGroup(id: "cv-autofill-settings") {
            CVAutofillSettingsWindow()
                .environmentObject(cvAutofillStore)
                .environmentObject(aiSettings)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .tint(settings.color(for: .buttonColor))
        }
        .defaultSize(width: 520, height: 660)

        // The CV AutoFill panel's own "Ask ChatGPT"/"Ask Claude" button — a small embedded browser
        // window, same shape as `account-signin` above.
        WindowGroup(id: "cv-autofill-ask-ai") {
            CustomWebPageView(page: CustomWebPage(name: cvAutofillStore.askAITarget.buttonLabel, urlString: cvAutofillStore.askAITarget.urlString))
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .tint(settings.color(for: .buttonColor))
        }
        .defaultSize(width: 480, height: 640)
    }
}
