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
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .tint(settings.color(for: .buttonColor))
        }
    }
}
