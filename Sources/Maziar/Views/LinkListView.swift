import SwiftUI
import AppKit

/// A list of saved links / references: each can be clicked to open in the browser (when it is a web
/// address) or copied, and a field at the bottom adds more. Used by a project's Links & References
/// and by each task's own links.
struct LinkListView: View {
    @Binding var links: [String]
    var placeholder = "e.g. https://... or a citation"

    @State private var newLink = ""
    @State private var copiedLink: String?

    /// The web address a link points to — `https://` is added when a bare domain like `github.com/me`
    /// was typed. nil for anything else (a citation, a note), which can only be copied.
    static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let full = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host,
              trimmed.contains("://") || host.contains(".") else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                row(link, index: index)
            }
            HStack {
                TextField("Add a link or reference", text: $newLink, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func row(_ link: String, index: Int) -> some View {
        let url = Self.webURL(from: link)
        return HStack(spacing: 8) {
            if let url {
                Button { NSWorkspace.shared.open(url) } label: {
                    Text(link)
                        .font(.caption)
                        .underline()
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help("Open in your browser")
            } else {
                Text(link).font(.caption).textSelection(.enabled)
            }
            Spacer()
            Button { copy(link) } label: {
                Image(systemName: copiedLink == link ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(copiedLink == link ? Color.green : Color.secondary)
            .help("Copy")
            if let url {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open in your browser")
            }
            Button { remove(at: index) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove")
        }
        .contextMenu {
            Button("Copy") { copy(link) }
            if let url { Button("Open in Browser") { NSWorkspace.shared.open(url) } }
            Divider()
            Button("Remove", role: .destructive) { remove(at: index) }
        }
    }

    private func add() {
        let trimmed = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        links.append(trimmed)
        newLink = ""
    }

    private func remove(at index: Int) {
        guard links.indices.contains(index) else { return }
        links.remove(at: index)
    }

    private func copy(_ link: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        copiedLink = link
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedLink == link { copiedLink = nil }
        }
    }
}
