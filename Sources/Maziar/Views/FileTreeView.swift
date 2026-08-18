import SwiftUI
import AppKit

struct FileTreeView: View {
    @ObservedObject var root: FileNode
    @Binding var selection: FileNode?
    var onNewFile: (FileNode) -> Void
    var onNewFolder: (FileNode) -> Void
    var onRename: (FileNode) -> Void
    var onDelete: (FileNode) -> Void

    var body: some View {
        List(selection: $selection) {
            OutlineGroup(root.children ?? [], id: \.self, children: \.children) { node in
                HStack(spacing: 6) {
                    Image(systemName: node.isDirectory ? "folder.fill" : iconName(for: node.url))
                        .foregroundStyle(node.isDirectory ? Color(red: 0.95, green: 0.75, blue: 0.3) : .secondary)
                        .font(.system(size: 12))
                        .frame(width: 14)
                    Text(node.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                }
                .tag(node)
                .padding(.vertical, 1)
                .contextMenu { contextMenuItems(for: node) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contextMenu {
            Button("New File...") { onNewFile(root) }
            Button("New Folder...") { onNewFolder(root) }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for node: FileNode) -> some View {
        if node.isDirectory {
            Button("New File...") { onNewFile(node) }
            Button("New Folder...") { onNewFolder(node) }
            Divider()
        }
        Button("Rename...") { onRename(node) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        Divider()
        Button("Move to Trash", role: .destructive) { onDelete(node) }
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "tex": return "doc.text.fill"
        case "bib": return "book.closed.fill"
        case "png", "jpg", "jpeg": return "photo.fill"
        case "pdf": return "doc.richtext.fill"
        case "cls", "sty": return "doc.badge.gearshape.fill"
        default: return "doc.fill"
        }
    }
}
