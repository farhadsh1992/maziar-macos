import Foundation

struct PaperTask: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var isDone: Bool = false
}

/// One reviewer's comments, kept separate so multi-reviewer papers (the norm) can be organized
/// and edited per-reviewer instead of as one undifferentiated blob of pasted text.
struct ReviewerComment: Codable, Equatable, Identifiable {
    var id = UUID()
    var label: String
    var text: String = ""
}

/// The outcome recorded once a decision comes back — gates Poster & Slides / Code Page (which
/// only make sense once a paper is actually accepted somewhere) and, when rejected, switches the
/// page over to AI-assisted improvement suggestions instead.
enum PaperDecision: String, Codable {
    case pending
    case accepted
    case rejected
}

/// A paper's whole lifecycle from picking a venue through rebuttal — the hub that ties together
/// a LaTeX project (edited in the existing project editor), a target conference/journal (linked
/// to `ConferenceStore` when tracked there), a task checklist, and reviewer/rebuttal notes.
struct Paper: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    /// Absolute path of the linked LaTeX project (`Project.path`), if one's been created/attached.
    var projectPath: String?
    /// Name matching a `ConferenceEntry.name` when linked to a tracked conference; free text otherwise.
    var conferenceName: String?
    /// Only used when `conferenceName` doesn't match a tracked conference (so there's nothing to
    /// pull a deadline from automatically).
    var independentDeadlineString: String?
    var tasks: [PaperTask] = []
    var reviewerComments: [ReviewerComment] = []
    var rebuttalNotes: String = ""
    var decision: PaperDecision = .pending
    var improvementSuggestions: String = ""
    var githubRepoURLString: String?
    var lastUpdated: Date = Date()
}

extension Paper {
    var doneTaskCount: Int { tasks.filter(\.isDone).count }
    var githubRepoURL: URL? {
        guard let githubRepoURLString, let url = URL(string: githubRepoURLString), url.scheme != nil else { return nil }
        return url
    }
}
