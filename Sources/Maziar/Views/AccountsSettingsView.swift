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
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 320)
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
