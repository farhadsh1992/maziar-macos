import SwiftUI
import WebKit

/// One open diagrams.net session within the Diagrams page's own tab bar — lets the user work on
/// several diagram projects at once, each in its own tab, the same way a real browser's tabs work.
private struct DiagramTabModel: Identifiable, Equatable {
    let id = UUID()
    var title: String
}

/// A dedicated top-level page embedding diagrams.net (draw.io) directly in the app, for making
/// flowcharts/diagrams without leaving Maziar. Reuses the exact `ScholarBrowserView`/`WebViewHolder`
/// bridge already used for the Library page's Scholar panel and the Reader's Code mode. Supports
/// multiple simultaneously-open diagram sessions via its own tab bar (`DiagramTabModel`) — each
/// tab's `DiagramTabContentView` stays mounted once created (hidden via opacity/hit-testing when
/// not the active tab, not torn down and recreated), so switching between tabs never reloads one
/// that's already open. The page itself is also kept alive across sidebar navigation by
/// `ContentView` (see its own doc comment) for the same reason: destroying and recreating this view
/// on every visit was forcing every open diagram to reload from scratch each time.
struct DiagramsView: View {
    @State private var tabs: [DiagramTabModel]
    @State private var activeTabID: UUID

    init() {
        let firstTab = DiagramTabModel(title: "Diagram 1")
        _tabs = State(initialValue: [firstTab])
        _activeTabID = State(initialValue: firstTab.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ZStack {
                ForEach(tabs) { tab in
                    DiagramTabContentView()
                        .opacity(tab.id == activeTabID ? 1 : 0)
                        .allowsHitTesting(tab.id == activeTabID)
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                HStack(spacing: 6) {
                    Text(tab.title)
                        .font(.caption)
                        .lineLimit(1)
                    if tabs.count > 1 {
                        Button {
                            closeTab(tab)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    tab.id == activeTabID ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
                .onTapGesture { activeTabID = tab.id }
            }
            Button {
                addTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New diagram tab")
            Spacer()
        }
        .padding(8)
    }

    private func addTab() {
        let newTab = DiagramTabModel(title: "Diagram \(tabs.count + 1)")
        tabs.append(newTab)
        activeTabID = newTab.id
    }

    private func closeTab(_ tab: DiagramTabModel) {
        guard tabs.count > 1 else { return }
        let wasActive = tab.id == activeTabID
        tabs.removeAll { $0.id == tab.id }
        if wasActive {
            activeTabID = tabs.last?.id ?? activeTabID
        }
    }
}

/// One tab's actual embedded diagrams.net session — back/forward/reload/home toolbar, a Light/Dark
/// toggle using diagrams.net's own real `?dark=1`/`?dark=0` URL parameter, and an "Open in Safari"
/// fallback, above the embedded page itself.
private struct DiagramTabContentView: View {
    /// diagrams.net's own real, documented `?dark=1`/`?dark=0` URL parameter (confirmed against
    /// drawio.com's own "Supported URL parameters" reference before wiring this up, not guessed) —
    /// this is the page's actual editor genuinely switching its own dark/light theme, not a CSS
    /// filter or anything layered on top of it from Maziar's side. Shared across tabs (one
    /// preference, remembered for the next tab you open) rather than per-tab.
    @AppStorage("maziar.diagramsDarkMode") private var isDarkMode = false

    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var currentURL: URL?
    @StateObject private var webViewHolder = WebViewHolder()

    private var webView: WKWebView? {
        get { webViewHolder.view }
        nonmutating set { webViewHolder.view = newValue }
    }

    private static let baseURL = URL(string: "https://app.diagrams.net")!

    private var themedURL: URL {
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "dark", value: isDarkMode ? "1" : "0")]
        return components.url ?? Self.baseURL
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { webView?.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!canGoBack)
                Button { webView?.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!canGoForward)
                Button { webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                Button { webView?.load(URLRequest(url: themedURL)) } label: { Image(systemName: "house") }
                Text("app.diagrams.net").font(.caption).foregroundStyle(.secondary)

                Spacer()

                Picker("", selection: $isDarkMode) {
                    Text("Light").tag(false)
                    Text("Dark").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .onChange(of: isDarkMode) { _, _ in
                    webView?.load(URLRequest(url: themedURL))
                }

                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    NSWorkspace.shared.open(themedURL)
                } label: {
                    Label("Open in Safari", systemImage: "safari")
                }
            }
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            ScholarBrowserView(
                initialURL: themedURL,
                onViewCreated: { view in webView = view },
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                isLoading: $isLoading,
                currentURL: $currentURL
            )
        }
    }
}
