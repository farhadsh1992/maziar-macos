import Foundation

/// A single dated (or not-yet-dated) deadline for a conference — e.g. "Paper submission deadline
/// 2026". `dateString` is "YYYY-MM-DD" when known; `rawText` carries the model's own wording as a
/// fallback when a clean date couldn't be pinned down (rolling/TBA deadlines, timezone caveats).
struct ConferenceDeadlineInfo: Codable, Equatable, Identifiable {
    var id = UUID()
    var label: String
    var dateString: String?
    var rawText: String?

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    var date: Date? {
        guard let dateString else { return nil }
        return Self.formatter.date(from: dateString)
    }
}

/// A conference an AI-backed lookup (listing-website import, keyword suggestions) found but
/// hasn't been added to the tracked list yet — shown in a picker sheet for the user to confirm.
struct ConferenceCandidate: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var websiteURLString: String?
}

struct ConferenceEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// e.g. "IEEE/CVF Conference on Computer Vision and Pattern Recognition" for "CVPR" — optional,
    /// but disambiguates the acronym for the AI lookup (many short names collide across fields)
    /// and shows in small text under the name wherever it's displayed.
    var fullName: String?
    /// User-supplied official site URLs — when set, `ConferenceInfoService` fetches their content
    /// directly and hands it to the model instead of relying on (slower, less reliable) web
    /// search, so updates are faster and more accurate.
    var thisYearWebsiteURLString: String?
    var nextYearWebsiteURLString: String?
    var authorGuideURLString: String?
    var templateURLString: String?
    var deadlines: [ConferenceDeadlineInfo] = []
    /// e.g. "8 pages + references" — free text since limits vary in how they're phrased.
    var pageLimit: String?
    /// e.g. "Double column" / "Single column" — free text for the same reason.
    var columnFormat: String?
    /// e.g. "CORE A*", "CCF A", "Q1" — free text since ranking systems vary; `rankSortPriority`
    /// does a best-effort match against common scales for the Rank sort mode.
    var rank: String?
    var notes: String?
    var lastUpdated: Date?
    var lastUpdateError: String?
}

/// How the Conferences page orders its list.
enum ConferenceSortMode: String, CaseIterable, Identifiable {
    case manual
    case deadline
    case rank

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "My Order"
        case .deadline: return "Deadline"
        case .rank: return "Rank"
        }
    }
}

extension ConferenceEntry {
    private var todayStart: Date { Calendar.current.startOfDay(for: Date()) }

    /// Deadlines with a known date today or later, soonest first — "next deadline" is the first.
    var upcomingDeadlines: [ConferenceDeadlineInfo] {
        deadlines
            .filter { ($0.date ?? .distantPast) >= todayStart }
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    var nextDeadline: ConferenceDeadlineInfo? { upcomingDeadlines.first }

    /// Deadlines with a known date before today, most recent first.
    var pastDeadlines: [ConferenceDeadlineInfo] {
        deadlines
            .filter { if let date = $0.date { return date < todayStart } else { return false } }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Deadlines mentioned by the model without a clean parseable date (e.g. "TBA", "rolling").
    var undatedDeadlines: [ConferenceDeadlineInfo] {
        deadlines.filter { $0.dateString == nil }
    }

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

    /// The upcoming edition's page — next year's if known, else this year's. Used by the "Open
    /// Website" button, since "next conference" means whichever page is actually forward-looking.
    var nextConferenceWebsiteURL: URL? {
        nextYearWebsiteURL ?? thisYearWebsiteURL
    }

    /// Lower sorts first. Best-effort match against common ranking scales (CORE/CCF-style
    /// letters, journal quartiles) — anything unmatched falls just before "no rank at all", so an
    /// unrecognized-but-present rank still outranks a conference with none.
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
}
