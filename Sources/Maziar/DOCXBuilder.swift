import Foundation

/// Hand-written minimal-but-valid OOXML .docx generator — no external library, plain paragraphs
/// only (a heading style plus normal text, no images/tables/pagination). Same "write parts to a
/// temp dir, then shell out to `/usr/bin/zip`" approach `PPTXBuilder` already uses for .pptx — a
/// .docx is the same kind of OOXML zip container, just with `word/` in place of `ppt/`.
enum DOCXBuilder {
    enum ParagraphStyle {
        case heading
        case normal
    }

    struct Paragraph {
        var text: String
        var style: ParagraphStyle = .normal
    }

    enum BuildError: LocalizedError {
        case zipFailed(String)
        var errorDescription: String? {
            switch self {
            case .zipFailed(let message): return "Failed to package the .docx: \(message)"
            }
        }
    }

    /// Splits each paragraph's text on newlines into its own `<w:p>` — lets a caller pass a whole
    /// multi-line block (a cover letter body, a CV section) as one `Paragraph` rather than needing
    /// to pre-split it itself; a blank line becomes a blank spacing paragraph.
    static func build(title: String, paragraphs: [Paragraph]) throws -> Data {
        let bodyXML = paragraphs
            .flatMap { paragraph -> [String] in
                paragraph.text.components(separatedBy: "\n").map { line in
                    paragraphXML(line, style: paragraph.style)
                }
            }
            .joined(separator: "\n    ")

        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            \(bodyXML)
            <w:sectPr>
              <w:pgSz w:w="11906" w:h="16838"/>
              <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """

        return try assemble(documentXML: documentXML, docTitle: title)
    }

    private static func paragraphXML(_ text: String, style: ParagraphStyle) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "<w:p/>" }
        switch style {
        case .heading:
            return "<w:p><w:pPr><w:rPr><w:b/><w:sz w:val=\"28\"/></w:rPr></w:pPr><w:r><w:rPr><w:b/><w:sz w:val=\"28\"/></w:rPr><w:t xml:space=\"preserve\">\(xmlEscape(trimmed))</w:t></w:r></w:p>"
        case .normal:
            return "<w:p><w:r><w:t xml:space=\"preserve\">\(xmlEscape(trimmed))</w:t></w:r></w:p>"
        }
    }

    private static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func assemble(documentXML: String, docTitle: String) throws -> Data {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("maziar-docx-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        try write(contentTypesXML(), to: tempDir, "[Content_Types].xml")
        try write(rootRelsXML(), to: tempDir, "_rels/.rels")
        try write(corePropsXML(title: docTitle), to: tempDir, "docProps/core.xml")
        try write(appPropsXML(), to: tempDir, "docProps/app.xml")
        try write(documentXML, to: tempDir, "word/document.xml")
        try write(documentRelsXML(), to: tempDir, "word/_rels/document.xml.rels")

        let outputURL = fm.temporaryDirectory.appendingPathComponent("maziar-out-\(UUID().uuidString).docx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-X", outputURL.path, "."]
        process.currentDirectoryURL = tempDir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            throw BuildError.zipFailed(String(data: errData, encoding: .utf8) ?? "zip exited \(process.terminationStatus)")
        }
        defer { try? fm.removeItem(at: outputURL) }
        return try Data(contentsOf: outputURL)
    }

    private static func write(_ content: String, to root: URL, _ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func contentTypesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
          <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """
    }

    private static func rootRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
    }

    private static func documentRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
        """
    }

    private static func corePropsXML(title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <dc:title>\(xmlEscape(title))</dc:title>
          <dc:creator>Maziar</dc:creator>
        </cp:coreProperties>
        """
    }

    private static func appPropsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">
          <Application>Maziar</Application>
        </Properties>
        """
    }
}
