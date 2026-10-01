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

/// What kind of project a `Paper` entry actually tracks — the Projects page originally only ever
/// tracked paper submissions; `.developing` covers a software/idea project instead (a description,
/// links/references, a task list, and sub-projects), with no venue/reviewer/decision workflow.
enum ProjectKind: String, Codable, CaseIterable, Identifiable {
    case paperSubmission
    case developing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paperSubmission: return "Paper Submission"
        case .developing: return "Developing"
        }
    }

    var icon: String {
        switch self {
        case .paperSubmission: return "doc.text"
        case .developing: return "hammer"
        }
    }
}

/// A project's whole lifecycle — for a paper submission, from picking a venue through rebuttal;
/// for a developing project, from idea through however many sub-projects it grows. The hub that
/// ties together a LaTeX project (edited in the existing project editor, paper submissions only),
/// a target conference/journal (linked to `ConferenceStore` when tracked there), a task checklist,
/// reviewer/rebuttal notes, and — for either kind — an auto-created Library group to collect
/// reference papers in, and any number of nested sub-projects of either kind.
struct Paper: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var kind: ProjectKind = .paperSubmission
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
    var dateCreated: Date = Date()

    /// Free-text description of the idea — `.developing` projects only.
    var ideaDescription: String = ""
    /// Links/references, one per entry — same free-text-list shape as `LibraryGroup.links`.
    var links: [String] = []

    /// nil for a top-level project; otherwise the parent project's `id`. Children aren't stored
    /// inline (no duplicate source of truth) — `PaperStore.children(of:)` filters the flat
    /// `papers` array by this, the same "one flat array, relationships by id" shape the rest of
    /// the store already uses.
    var parentID: UUID?

    /// The Library group auto-created alongside this project (if a library folder was connected
    /// at creation time — `LibraryStore.createGroup` is skipped, not forced, when one isn't), so
    /// each project can collect its own reference papers independently.
    var libraryGroupID: UUID?

    enum CodingKeys: String, CodingKey {
        case id, title, kind, projectPath, conferenceName, independentDeadlineString, tasks,
             reviewerComments, rebuttalNotes, decision, improvementSuggestions, githubRepoURLString,
             lastUpdated, dateCreated, ideaDescription, links, parentID, libraryGroupID
    }

    init(
        id: UUID = UUID(), title: String, kind: ProjectKind = .paperSubmission, projectPath: String? = nil,
        conferenceName: String? = nil, independentDeadlineString: String? = nil, tasks: [PaperTask] = [],
        reviewerComments: [ReviewerComment] = [], rebuttalNotes: String = "", decision: PaperDecision = .pending,
        improvementSuggestions: String = "", githubRepoURLString: String? = nil, lastUpdated: Date = Date(),
        dateCreated: Date = Date(), ideaDescription: String = "", links: [String] = [], parentID: UUID? = nil,
        libraryGroupID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.projectPath = projectPath
        self.conferenceName = conferenceName
        self.independentDeadlineString = independentDeadlineString
        self.tasks = tasks
        self.reviewerComments = reviewerComments
        self.rebuttalNotes = rebuttalNotes
        self.decision = decision
        self.improvementSuggestions = improvementSuggestions
        self.githubRepoURLString = githubRepoURLString
        self.lastUpdated = lastUpdated
        self.dateCreated = dateCreated
        self.ideaDescription = ideaDescription
        self.links = links
        self.parentID = parentID
        self.libraryGroupID = libraryGroupID
    }

    /// Custom decode so that every field added after this struct's first release — `kind`,
    /// `dateCreated`, `ideaDescription`, `links`, `parentID`, `libraryGroupID` — falls back to its
    /// default instead of failing the whole decode. A plain Swift default value (`= .paperSubmission`
    /// etc.) does NOT provide that fallback for synthesized `Decodable` conformance — a missing key
    /// still throws `keyNotFound` for a non-Optional property regardless of its declared default,
    /// which would have silently discarded every already-persisted project on next launch (`try?
    /// JSONDecoder().decode(...)` in `PaperStore.loadPapers()` returns `[]` on any decode failure).
    /// Caught by a headless test decoding a pre-this-change JSON fixture before this shipped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decodeIfPresent(ProjectKind.self, forKey: .kind) ?? .paperSubmission
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        conferenceName = try container.decodeIfPresent(String.self, forKey: .conferenceName)
        independentDeadlineString = try container.decodeIfPresent(String.self, forKey: .independentDeadlineString)
        tasks = try container.decodeIfPresent([PaperTask].self, forKey: .tasks) ?? []
        reviewerComments = try container.decodeIfPresent([ReviewerComment].self, forKey: .reviewerComments) ?? []
        rebuttalNotes = try container.decodeIfPresent(String.self, forKey: .rebuttalNotes) ?? ""
        decision = try container.decodeIfPresent(PaperDecision.self, forKey: .decision) ?? .pending
        improvementSuggestions = try container.decodeIfPresent(String.self, forKey: .improvementSuggestions) ?? ""
        githubRepoURLString = try container.decodeIfPresent(String.self, forKey: .githubRepoURLString)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? Date()
        dateCreated = try container.decodeIfPresent(Date.self, forKey: .dateCreated) ?? Date()
        ideaDescription = try container.decodeIfPresent(String.self, forKey: .ideaDescription) ?? ""
        links = try container.decodeIfPresent([String].self, forKey: .links) ?? []
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        libraryGroupID = try container.decodeIfPresent(UUID.self, forKey: .libraryGroupID)
    }
}

extension Paper {
    var doneTaskCount: Int { tasks.filter(\.isDone).count }
    var githubRepoURL: URL? {
        guard let githubRepoURLString, let url = URL(string: githubRepoURLString), url.scheme != nil else { return nil }
        return url
    }
}
