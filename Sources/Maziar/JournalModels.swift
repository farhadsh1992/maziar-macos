import Foundation

/// A journal an AI-backed lookup (listing-website import, keyword suggestions) found but hasn't
/// been added to the tracked list yet — shown in a picker sheet for the user to confirm.
struct JournalCandidate: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var websiteURLString: String?
}

struct JournalEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// e.g. "IEEE Transactions on Pattern Analysis and Machine Intelligence" for "TPAMI" —
    /// optional, but disambiguates the short name for the AI lookup and shows in small text
    /// under the name wherever it's displayed.
    var fullName: String?
    /// User-supplied official site URLs — when set, `JournalInfoService` fetches their content
    /// directly and hands it to the model instead of relying on (slower, less reliable) web
    /// search, so updates are faster and more accurate.
    var thisYearWebsiteURLString: String?
    var nextYearWebsiteURLString: String?
    var authorGuideURLString: String?
    var templateURLString: String?
    /// e.g. "no strict limit" or "12 pages, double column" — free text since limits vary in how
    /// they're phrased, and many journals don't have one at all.
    var pageLimit: String?
    /// e.g. "Double column" / "Single column" — free text for the same reason.
    var columnFormat: String?
    /// e.g. "Q1", "IF 5.2", "JCR Q2" — free text since ranking/impact metrics vary; `rankSortPriority`
    /// does a best-effort match against common quartile scales for the Rank sort mode. Journals
    /// don't have a fixed submission deadline the way conferences do (most are rolling), so this
    /// — together with `reviewTime`/`publicationTime` below — is what actually distinguishes one
    /// journal's attractiveness/urgency from another's.
    var rank: String?
    /// e.g. "~8-12 weeks to first decision" — typical time to a first review decision.
    var reviewTime: String?
    /// e.g. "~2-3 months after acceptance" — typical time from acceptance to publication.
    var publicationTime: String?
    var notes: String?
    var lastUpdated: Date?
    var lastUpdateError: String?
}

/// How the Journals page orders its list. Journals are mostly rolling-submission (no fixed
/// deadline to sort by the way Conferences can), so ordering instead falls back to the two things
/// that actually vary journal-to-journal: ranking/impact and turnaround speed.
enum JournalSortMode: String, CaseIterable, Identifiable {
    case manual
    case rank
    case reviewSpeed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "My Order"
        case .rank: return "Rank"
        case .reviewSpeed: return "Review Speed"
        }
    }
}

extension JournalEntry {
    var authorGuideURL: URL? {
        guard let authorGuideURLString, let url = URL(string: authorGuideURLString), url.scheme != nil else { return nil }
        return url
    }

    var templateURL: URL? {
        guard let templateURLString, let url = URL(string: templateURLString), url.scheme != nil else { return nil }
        return url
    }

    var thisYearWebsiteURL: URL? {
        guard let thisYearWebsiteURLString, let url = URL(string: thisYearWebsiteURLString), url.scheme != nil else { return nil }
        return url
    }

    var nextYearWebsiteURL: URL? {
        guard let nextYearWebsiteURLString, let url = URL(string: nextYearWebsiteURLString), url.scheme != nil else { return nil }
        return url
    }

    /// The upcoming edition's page — next year's if known, else this year's.
    var nextConferenceWebsiteURL: URL? {
        nextYearWebsiteURL ?? thisYearWebsiteURL
    }

    /// Lower sorts first. Best-effort match against common ranking scales (journal quartiles,
    /// CORE/CCF-style letters some journals also carry) — anything unmatched falls just before
    /// "no rank at all", so an unrecognized-but-present rank still outranks a journal with none.
    var rankSortPriority: Int {
        guard let raw = rank?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !raw.isEmpty else {
            return Int.max
        }
        let priorityByToken: [String: Int] = [
            "A*": 0, "A+": 0, "Q1": 0,
            "A": 1, "Q2": 1,
            "B": 2, "Q3": 2,
            "C": 3, "Q4": 3,
            "D": 4
        ]
        // Tokens must sit at a word boundary — otherwise a scheme name like "CORE A*" or "CCF B"
        // could match the embedded "C" in "CORE"/"CCF" before ever reaching the real rank letter,
        // since dictionary/substring matching alone has no concept of "this C is part of a
        // longer word." Alternatives are listed longest-first so "A*"/"A+"/"Q1" win over bare "A".
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![A-Z0-9])(A\\*|A\\+|Q1|Q2|Q3|Q4|A|B|C|D)(?![A-Z0-9])"
        ) else {
            return Int.max - 1
        }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let tokenRange = Range(match.range(at: 1), in: raw) else {
            return Int.max - 1
        }
        return priorityByToken[String(raw[tokenRange])] ?? Int.max - 1
    }

    /// Best-effort estimate, in weeks, of `reviewTime`'s free text — lower sorts first for the
    /// Review Speed sort mode. Picks out the first number and a week/month/day unit; a journal
    /// with no parseable estimate sorts last rather than being excluded, same spirit as
    /// `rankSortPriority`. Not exact (ranges like "8-12 weeks" just use the first number), but
    /// good enough to order a handful of tracked journals by roughly how fast they are.
    var reviewSpeedSortWeeks: Double {
        guard let raw = reviewTime?.lowercased(), !raw.isEmpty,
              let regex = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*(day|week|month)") else {
            return .greatestFiniteMagnitude
        }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let numberRange = Range(match.range(at: 1), in: raw),
              let unitRange = Range(match.range(at: 2), in: raw),
              let number = Double(raw[numberRange]) else {
            return .greatestFiniteMagnitude
        }
        switch raw[unitRange] {
        case "day": return number / 7
        case "month": return number * 4.345
        default: return number
        }
    }
}
