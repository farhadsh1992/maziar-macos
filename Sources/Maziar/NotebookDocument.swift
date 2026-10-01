import Foundation

/// One cell of a paper's notes notebook — always a markdown cell (no code execution, by design:
/// these are paper notes, not a coding notebook), matching a real Jupyter `.ipynb` markdown cell's
/// shape closely enough that the file opens correctly in actual Jupyter/VS Code/Kaggle too, not
/// just in Maziar.
struct NotebookCell: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var cellType: String = "markdown"
    var source: String
    /// Free-form key/value metadata as raw JSON, preserved as-is round-trip — a `.ipynb` file
    /// opened in real Jupyter may carry metadata we don't understand (e.g. collapsed state);
    /// dropping it would be a lossy edit of a file that isn't only ours.
    var metadataJSON: String = "{}"

    enum CodingKeys: String, CodingKey {
        case id, source, metadata
        case cellType = "cell_type"
    }

    init(id: String = UUID().uuidString, source: String) {
        self.id = id
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        cellType = try container.decodeIfPresent(String.self, forKey: .cellType) ?? "markdown"
        let lines = try container.decodeIfPresent([String].self, forKey: .source) ?? []
        source = lines.joined()
        if let metadata = try? container.decode(JSONPassthrough.self, forKey: .metadata) {
            metadataJSON = metadata.rawJSON
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(cellType, forKey: .cellType)
        try container.encode(Self.linesForSource(source), forKey: .source)
        try container.encode(JSONPassthrough(rawJSON: metadataJSON), forKey: .metadata)
    }

    /// Jupyter's `source` field is an array of lines, each keeping its own trailing "\n" except
    /// the last — this splits a plain multi-line string into that shape.
    static func linesForSource(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let lines = text.components(separatedBy: "\n")
        return lines.enumerated().map { index, line in index == lines.count - 1 ? line : line + "\n" }
    }

    /// An app-specific key inside `metadataJSON` (`maziar_border_color`, one of "red"/"green"/
    /// "yellow"/"blue", or absent for the default gray) — the cell-card border color set from the
    /// Notebook editor. Riding along inside the existing free-form `metadata` object rather than a
    /// new top-level `Codable` field keeps this a normal, ignorable extra key to any other tool
    /// that opens the `.ipynb` file (exactly what Jupyter's own `metadata` object is for), instead
    /// of a field only Maziar understands sitting at the cell's top level.
    var borderColorName: String? {
        metadataValue(forKey: "maziar_border_color")
    }

    mutating func setBorderColorName(_ name: String?) {
        setMetadataValue(name, forKey: "maziar_border_color")
    }

    /// Same `metadata`-riding-along approach as `borderColorName`, one of "white"/"black", or
    /// absent for the normal system card background.
    var backgroundColorName: String? {
        metadataValue(forKey: "maziar_background_color")
    }

    mutating func setBackgroundColorName(_ name: String?) {
        setMetadataValue(name, forKey: "maziar_background_color")
    }

    private func metadataValue(forKey key: String) -> String? {
        guard let data = metadataJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict[key] as? String
    }

    private mutating func setMetadataValue(_ value: String?, forKey key: String) {
        var dict: [String: Any] = [:]
        if let data = metadataJSON.data(using: .utf8),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = existing
        }
        dict[key] = value
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return }
        metadataJSON = string
    }
}

/// Stores a JSON fragment (an object, typically `{}`) as its exact original text, so metadata this
/// app doesn't otherwise model round-trips byte-for-byte instead of being silently dropped.
private struct JSONPassthrough: Codable {
    let rawJSON: String

    init(rawJSON: String) {
        self.rawJSON = rawJSON
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: JSONAnyValue].self), let data = try? JSONEncoder().encode(dict),
           let string = String(data: data, encoding: .utf8) {
            rawJSON = string
        } else {
            rawJSON = "{}"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        guard let data = rawJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: JSONAnyValue].self, from: data) else {
            try container.encode([String: JSONAnyValue]())
            return
        }
        try container.encode(dict)
    }
}

/// A minimal `Codable` box for "any JSON value", just enough to round-trip arbitrary cell metadata
/// without needing to model Jupyter's full metadata schema.
private enum JSONAnyValue: Codable {
    case string(String), number(Double), bool(Bool), object([String: JSONAnyValue]), array([JSONAnyValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode([String: JSONAnyValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONAnyValue].self) { self = .array(value) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// A `.ipynb` file's top-level shape, trimmed to what this app actually reads/writes — real
/// Jupyter/VS Code/Kaggle can still open it, since every field a markdown-only notebook needs is
/// present and correctly named.
struct NotebookDocument: Codable, Equatable {
    var cells: [NotebookCell] = []
    var nbformat: Int = 4
    var nbformatMinor: Int = 5

    enum CodingKeys: String, CodingKey {
        case cells, nbformat, metadata
        case nbformatMinor = "nbformat_minor"
    }

    init(cells: [NotebookCell] = []) {
        self.cells = cells
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cells = try container.decodeIfPresent([NotebookCell].self, forKey: .cells) ?? []
        nbformat = try container.decodeIfPresent(Int.self, forKey: .nbformat) ?? 4
        nbformatMinor = try container.decodeIfPresent(Int.self, forKey: .nbformatMinor) ?? 5
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cells, forKey: .cells)
        try container.encode(nbformat, forKey: .nbformat)
        try container.encode(nbformatMinor, forKey: .nbformatMinor)
        try container.encode(Self.metadataObject, forKey: .metadata)
    }

    private static let metadataObject: [String: [String: String]] = [
        "kernelspec": ["display_name": "Markdown", "language": "markdown", "name": "markdown"]
    ]

    static func decode(_ data: Data) -> NotebookDocument? {
        try? JSONDecoder().decode(NotebookDocument.self, from: data)
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }
}
