import Foundation

/// Shared helper for pulling a JSON value out of an LLM's text reply, since models often ignore
/// "respond with ONLY JSON" instructions and add prose and/or a ```json fence anyway. Strips an
/// optional fenced code block first; if that still doesn't decode, falls back to grabbing the
/// first balanced span between the given open/close characters.
enum JSONExtraction {
    static func decodeObject<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        decode(type, from: text, open: "{", close: "}")
    }

    static func decodeArray<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        decode(type, from: text, open: "[", close: "]")
    }

    private static func decode<T: Decodable>(_ type: T.Type, from text: String, open: Character, close: Character) -> T? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let regex = try? NSRegularExpression(pattern: "```(?:json)?\\n([\\s\\S]*?)```"),
           let match = regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
           let range = Range(match.range(at: 1), in: candidate) {
            candidate = String(candidate[range])
        }
        if let data = candidate.data(using: .utf8),
           let result = try? JSONDecoder().decode(type, from: data) {
            return result
        }
        if let start = candidate.firstIndex(of: open), let end = candidate.lastIndex(of: close), start < end {
            let sub = String(candidate[start...end])
            if let data = sub.data(using: .utf8) {
                return try? JSONDecoder().decode(type, from: data)
            }
        }
        return nil
    }
}
