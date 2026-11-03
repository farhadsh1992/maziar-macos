import Foundation
import AppKit

/// Where a project's pictures live: copies under Application Support/Maziar/ProjectImages/<project id>/,
/// so the originals can be moved or deleted without breaking the project. (They are local to this Mac —
/// unlike the project's text, the files are not part of the Settings backup / Drive sync.)
enum ProjectImageStorage {
    private static func root() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maziar", isDirectory: true)
            .appendingPathComponent("ProjectImages", isDirectory: true)
    }

    private static func directory(for paperID: UUID) -> URL {
        root().appendingPathComponent(paperID.uuidString, isDirectory: true)
    }

    static func url(for image: ProjectImage, paperID: UUID) -> URL {
        directory(for: paperID).appendingPathComponent(image.fileName)
    }

    /// Copies an image file into the project's folder.
    static func add(from source: URL, paperID: UUID) -> ProjectImage? {
        let ext = source.pathExtension.lowercased()
        let fileName = "\(UUID().uuidString).\(ext.isEmpty ? "png" : ext)"
        do {
            let dir = directory(for: paperID)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(fileName))
        } catch {
            return nil
        }
        return ProjectImage(fileName: fileName, caption: source.deletingPathExtension().lastPathComponent)
    }

    /// Saves an image from the clipboard as a PNG.
    static func add(_ image: NSImage, paperID: UUID) -> ProjectImage? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let fileName = "\(UUID().uuidString).png"
        do {
            let dir = directory(for: paperID)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: dir.appendingPathComponent(fileName))
        } catch {
            return nil
        }
        return ProjectImage(fileName: fileName, caption: "Pasted image")
    }

    static func delete(_ image: ProjectImage, paperID: UUID) {
        try? FileManager.default.removeItem(at: url(for: image, paperID: paperID))
    }

    static func removeAll(_ paperID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: paperID))
    }
}
