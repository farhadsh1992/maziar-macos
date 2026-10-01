import SwiftUI
import WebKit

/// Embedded, live GitHub with a real, Safari-style address bar — the same shape as
/// `YouTubeBrowserPane`, just pointed at github.com: back/forward/reload above a
/// `ScholarBrowserView`-backed WKWebView, an address bar that tracks the current page's URL live
/// and doubles as search (paste a URL to navigate, type anything else to search GitHub), and an
/// optional `onAddRepository` capture button for whichever repo page is currently loaded.
struct CodeBrowserPane: View {
    var initialURL: URL = CodeBrowserPane.homeURL
    var onAddRepository: ((URL) -> Void)?

    @State private var addressText = ""
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var currentURL: URL?
    @State private var addMessage: String?
    @StateObject private var webViewHolder = WebViewHolder()

    private var webView: WKWebView? {
        get { webViewHolder.view }
        nonmutating set { webViewHolder.view = newValue }
    }

    static let homeURL = URL(string: "https://github.com")!

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { webView?.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!canGoBack)
                Button { webView?.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!canGoForward)
                Button { webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                Button { webView?.load(URLRequest(url: Self.homeURL)) } label: { Image(systemName: "house") }
                TextField("Search GitHub or enter a URL…", text: $addressText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(navigateOrSearch)
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                if let onAddRepository {
                    Button {
                        guard let url = webView?.url else { return }
                        if GitHubLinkParser.repository(from: url) != nil {
                            addMessage = nil
                            onAddRepository(url)
                        } else {
                            addMessage = "Open a specific repository first."
                        }
                    } label: {
                        Label("Add to Code List", systemImage: "plus.circle")
                    }
                }
            }
            .buttonStyle(.borderless)
            .padding(8)
            if let addMessage {
                Text(addMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            Divider()
            ScholarBrowserView(
                initialURL: initialURL,
                onViewCreated: { view in webView = view },
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                isLoading: $isLoading,
                currentURL: $currentURL
            )
        }
        .onChange(of: currentURL) { _, newValue in
            if let newValue { addressText = newValue.absoluteString }
        }
        .onAppear { addressText = initialURL.absoluteString }
    }

    /// One Safari-style bar for both purposes: a typed/pasted http(s) URL navigates there
    /// directly; anything else is treated as a GitHub repository search.
    private func navigateOrSearch() {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme.hasPrefix("http") {
            webView?.load(URLRequest(url: url))
            return
        }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://github.com/search?q=\(encoded)&type=repositories") else { return }
        webView?.load(URLRequest(url: searchURL))
    }
}
