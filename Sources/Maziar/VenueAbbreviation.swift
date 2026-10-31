import Foundation

/// A short label (CVPR, NeurIPS, IEEE TPAMI, …) for a paper's venue, for the Library row where the
/// full "Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition" is far
/// too long. Tries, in order: a well-known conference/journal name, an acronym the venue string
/// already carries in parentheses, a venue that is itself already short, and finally initials of
/// the significant words. Returns `placeholder` when there's no venue to abbreviate.
enum VenueAbbreviation {
    static let placeholder = "****"

    /// Substring (lowercased) → short name. Order matters: more specific phrases come first
    /// ("european conference on computer vision" before "computer vision").
    private static let known: [(match: String, short: String)] = [
        // The acronym itself already appears in the string — wins over a broader phrase below
        // ("Findings of the Association for Computational Linguistics: EMNLP 2023" is EMNLP).
        ("emnlp", "EMNLP"), ("naacl", "NAACL"), ("eacl", "EACL"), ("cvpr", "CVPR"), ("iccv", "ICCV"),
        ("eccv", "ECCV"), ("icml", "ICML"), ("iclr", "ICLR"), ("aaai", "AAAI"), ("ijcai", "IJCAI"),
        ("european conference on computer vision", "ECCV"),
        ("computer vision and pattern recognition", "CVPR"),
        ("international conference on computer vision", "ICCV"),
        ("winter conference on applications of computer vision", "WACV"),
        ("neural information processing systems", "NeurIPS"),
        ("neurips", "NeurIPS"),
        ("international conference on machine learning", "ICML"),
        ("learning representations", "ICLR"),
        ("empirical methods in natural language processing", "EMNLP"),
        ("north american chapter of the association for computational linguistics", "NAACL"),
        ("european chapter of the association for computational linguistics", "EACL"),
        ("association for computational linguistics", "ACL"),
        ("transactions of the association for computational linguistics", "TACL"),
        ("joint conference on artificial intelligence", "IJCAI"),
        ("aaai conference on artificial intelligence", "AAAI"),
        ("artificial intelligence and statistics", "AISTATS"),
        ("uncertainty in artificial intelligence", "UAI"),
        ("knowledge discovery and data mining", "KDD"),
        ("research and development in information retrieval", "SIGIR"),
        ("the web conference", "WWW"),
        ("world wide web", "WWW"),
        ("siggraph", "SIGGRAPH"),
        ("acoustics, speech and signal processing", "ICASSP"),
        ("robotics and automation", "ICRA"),
        ("intelligent robots and systems", "IROS"),
        ("pattern analysis and machine intelligence", "IEEE TPAMI"),
        ("transactions on image processing", "IEEE TIP"),
        ("transactions on neural networks and learning systems", "IEEE TNNLS"),
        ("international journal of computer vision", "IJCV"),
        ("journal of machine learning research", "JMLR"),
        ("computing surveys", "ACM CSUR"),
        ("arxiv", "arXiv"),
    ]

    private static let skipWords: Set<String> = [
        "of", "on", "the", "and", "for", "in", "at", "to", "a", "an", "proceedings", "conference",
        "international", "annual", "workshop", "symposium", "journal", "meeting", "joint",
    ]

    static func short(_ venue: String?) -> String {
        guard let venue, !venue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return placeholder }
        let text = venue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        if let hit = known.first(where: { lower.contains($0.match) }) { return hit.short }

        // An acronym already in the string: "… Conference on Foo (FOO 2023)".
        if let regex = try? NSRegularExpression(pattern: "\\(([^)]{2,20})\\)"),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            let inner = text[range].split(separator: " ").first.map(String.init) ?? ""
            let letters = inner.filter(\.isLetter)
            if letters.count >= 2, letters.filter(\.isUppercase).count >= 2 { return inner.filter { $0.isLetter || $0.isNumber } }
        }

        // Already a short name: "CVPR", "ICLR 2024", "SIGMOD".
        let words = text.split(whereSeparator: { $0.isWhitespace })
        if let first = words.first, first.count <= 10 {
            if words.count == 1 { return String(first) }
            // "ICLR 2024" → ICLR (a trailing year/number isn't part of the name).
            if words.count == 2, words[1].allSatisfy({ $0.isNumber || $0 == "'" }) { return String(first) }
        }
        // A short two-word name is its own best abbreviation: "IEEE Access".
        if words.count == 2, text.count <= 16 { return text }

        // Initials of the significant words, keeping a leading publisher token (IEEE, ACM) whole.
        var prefix = ""
        var rest = words.map(String.init)
        if let first = rest.first, first.count <= 5, first == first.uppercased(), first.contains(where: \.isLetter) {
            prefix = first + " "
            rest.removeFirst()
        }
        let initials = rest
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && !skipWords.contains($0.lowercased()) }
            .compactMap { $0.first.map { String($0).uppercased() } }
            .joined()
        let result = prefix + String(initials.prefix(8))
        return result.trimmingCharacters(in: .whitespaces).count >= 2 ? result.trimmingCharacters(in: .whitespaces) : placeholder
    }
}
