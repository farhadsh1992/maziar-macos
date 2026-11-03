import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An image file shown downscaled (so a big photo doesn't sit in memory at full size).
struct ProjectImageView: View {
    let url: URL
    let maxPixel: CGFloat
    var fill = false

    @State private var image: NSImage?
    @State private var failed = false
    /// Bumped when pictures were just downloaded from Drive, so a "missing" one gets another try.
    @State private var reloadToken = 0

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark").font(.title2)
                    Text("Image file missing").font(.caption2)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectImagesChanged)) { _ in reloadToken += 1 }
        .task(id: "\(url.path)#\(reloadToken)") {
            failed = false
            let loaded = await Self.load(url, maxPixel: maxPixel)
            image = loaded
            failed = loaded == nil
        }
    }

    private static func load(_ url: URL, maxPixel: CGFloat) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }
}

/// A project's Images section: add pictures (file picker, drag & drop, or paste), flip through them
/// with the left/right arrows, reorder, caption and remove them.
struct ProjectImagesView: View {
    /// The pictures of this box (the project's own, or an extra Images box's).
    @Binding var allImages: [ProjectImage]
    let paperID: UUID

    @State private var index = 0
    @State private var isTargeted = false
    @State private var errorMessage: String?

    private var images: [ProjectImage] { allImages }
    private var safeIndex: Int { min(max(index, 0), max(images.count - 1, 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if images.isEmpty {
                emptyState
            } else {
                viewer
                HStack(spacing: 6) {
                    Image(systemName: "text.below.photo").foregroundStyle(.secondary)
                    TextField("Caption", text: Binding(
                        get: { images.indices.contains(safeIndex) ? images[safeIndex].caption : "" },
                        set: { if allImages.indices.contains(safeIndex) { allImages[safeIndex].caption = $0 } }
                    ), prompt: Text("Add a caption for this image\u{2026}"))
                    .textFieldStyle(.roundedBorder)
                }
                thumbnails
            }
            toolbar
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: isTargeted ? 2 : 0))
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
        .onChange(of: paperID) { _, _ in index = 0 }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Drop images here, or use Add Images\u{2026}").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5])))
    }

    private var viewer: some View {
        let current = images[safeIndex]
        return ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1))
            ProjectImageView(url: ProjectImageStorage.url(for: current, paperID: paperID), maxPixel: 1800)
                .padding(10)
                .id(current.id)
                .onTapGesture(count: 2) { open(current) }
            HStack {
                navButton("chevron.left", help: "Previous image") { step(-1) }
                Spacer()
                navButton("chevron.right", help: "Next image") { step(1) }
            }
            .padding(8)
            VStack {
                Spacer()
                Text("\(safeIndex + 1) / \(images.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 6)
            }
        }
        .frame(height: 360)
        .help("Double-click to open in your default image app")
    }

    private func navButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .opacity(images.count > 1 ? 1 : 0.35)
        .disabled(images.count < 2)
        .help(help)
    }

    private var thumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.element.id) { position, image in
                    ProjectImageView(url: ProjectImageStorage.url(for: image, paperID: paperID), maxPixel: 200, fill: true)
                        .frame(width: 72, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(position == safeIndex ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: position == safeIndex ? 2 : 1)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { index = position }
                        .help(image.caption.isEmpty ? "Image \(position + 1)" : image.caption)
                }
            }
            .padding(2)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { chooseFiles() } label: { Label("Add Images\u{2026}", systemImage: "plus") }
            Button { pasteImage() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                .help("Add the image currently on the clipboard")
            Spacer()
            if !images.isEmpty {
                Button { move(-1) } label: { Image(systemName: "arrow.left.to.line") }
                    .disabled(safeIndex == 0)
                    .help("Move this image earlier")
                Button { move(1) } label: { Image(systemName: "arrow.right.to.line") }
                    .disabled(safeIndex >= images.count - 1)
                    .help("Move this image later")
                Button { open(images[safeIndex]) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("Open in your default image app")
                Button(role: .destructive) { removeCurrent() } label: { Image(systemName: "trash") }
                    .help("Remove this image from the project")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: Actions

    private func step(_ delta: Int) {
        guard images.count > 1 else { return }
        index = (safeIndex + delta + images.count) % images.count
    }

    private func move(_ delta: Int) {
        let from = safeIndex
        let to = from + delta
        guard allImages.indices.contains(to) else { return }
        allImages.swapAt(from, to)
        index = to
    }

    private func open(_ image: ProjectImage) {
        NSWorkspace.shared.open(ProjectImageStorage.url(for: image, paperID: paperID))
    }

    private func removeCurrent() {
        guard allImages.indices.contains(safeIndex) else { return }
        let removed = allImages.remove(at: safeIndex)
        ProjectImageStorage.delete(removed, paperID: paperID)
        index = min(safeIndex, max(allImages.count - 1, 0))
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    private func addFiles(_ urls: [URL]) {
        errorMessage = nil
        var added: [ProjectImage] = []
        var skipped = 0
        for url in urls where url.isFileURL {
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  let image = ProjectImageStorage.add(from: url, paperID: paperID) else { skipped += 1; continue }
            added.append(image)
        }
        guard !added.isEmpty || skipped > 0 else { return }
        if !added.isEmpty {
            allImages.append(contentsOf: added)
            index = allImages.count - added.count
        }
        if skipped > 0 { errorMessage = "\(skipped) file\(skipped == 1 ? "" : "s") couldn\u{2019}t be added (not an image, or unreadable)." }
    }

    private func pasteImage() {
        errorMessage = nil
        guard let image = NSImage(pasteboard: .general), let saved = ProjectImageStorage.add(image, paperID: paperID) else {
            errorMessage = "There is no image on the clipboard."
            return
        }
        allImages.append(saved)
        index = allImages.count - 1
    }
}
