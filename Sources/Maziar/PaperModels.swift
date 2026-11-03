import Foundation

struct PaperSubtask: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var isDone: Bool = false
}

struct PaperTask: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var isDone: Bool = false
    /// Optional due date (a calendar day) — shown next to the task and offered for "Add to Calendar".
    var dueDate: Date?
    var subtasks: [PaperSubtask] = []
    var notes: String = ""
    /// Color tags (`TaskTagStore`, managed in Settings → Projects). A tag deleted since is just ignored.
    var tagIDs: [UUID] = []
    /// Links and references for this task — web addresses open in the browser, anything else is just kept.
    var links: [String] = []

    enum CodingKeys: String, CodingKey {
        case id, text, isDone, dueDate, subtasks, notes, tagIDs, links
    }

    init(
        id: UUID = UUID(), text: String, isDone: Bool = false, dueDate: Date? = nil,
        subtasks: [PaperSubtask] = [], notes: String = "", tagIDs: [UUID] = [], links: [String] = []
    ) {
        self.links = links
        self.id = id
        self.text = text
        self.isDone = isDone
        self.dueDate = dueDate
        self.subtasks = subtasks
        self.notes = notes
        self.tagIDs = tagIDs
    }

    /// Custom decode so tasks saved before sub-tasks / notes / tags existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        isDone = try container.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        subtasks = try container.decodeIfPresent([PaperSubtask].self, forKey: .subtasks) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tagIDs = try container.decodeIfPresent([UUID].self, forKey: .tagIDs) ?? []
        links = try container.decodeIfPresent([String].self, forKey: .links) ?? []
    }

    var hasDetails: Bool { !subtasks.isEmpty || !links.isEmpty || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
/// reviewer/rebuttal notes, and — for either kind — a tagged Library group whose reference papers
/// are listed on the page, and any number of nested sub-projects of either kind.
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

    /// The Library group this project is tagged with, chosen from the project's page — its papers are
    /// listed there and can be opened from it. Creating a project no longer creates a group (or any
    /// folder); older projects keep the group that was auto-created for them.
    var libraryGroupID: UUID?
    /// Every Library group tagged on this project (any number). The single `libraryGroupID` above is
    /// the older one-group form — `init(from:)` folds it into this list and clears it.
    var libraryGroupIDs: [UUID] = []
    /// The Idea box as RTF (bold / colors / fonts / sizes). `ideaDescription` keeps the same text as
    /// plain text — it's what older versions stored, and it seeds the rich box when this is nil.
    var ideaRichText: Data?
    /// Card icon (SF Symbol) and color for this project's tile — set from "Rename / Change Icon…" on a
    /// sub-project; nil means the kind's own icon and the Library button color.
    var iconSystemName: String?
    var iconColorHex: String?
    /// Quick-access buttons shown at the top of the project page: a folder on this Mac or a website.
    var shortcuts: [ProjectShortcut] = []
    /// The project's Information sections (formerly the single Idea box) — empty until the first one
    /// is edited or a second is added; until then the first section is read from `ideaRichText` /
    /// `ideaDescription`, which keep mirroring the first section afterwards.
    var infoSections: [ProjectInfoSection] = []
    /// Pictures attached to the project (files live in `ProjectImageStorage`'s folder for this project).
    var images: [ProjectImage] = []
    /// The order of the page's sections (boxes), including any extra Information / Notes / Images boxes
    /// the user added. Empty = the default order for this kind of project.
    var sectionLayout: [ProjectSectionEntry] = []
    /// Content of extra Information / Images boxes, keyed by the box's `ProjectSectionEntry.id`
    /// (extra Notes boxes keep theirs in `ProjectNotebookStorage`).
    var extraInfo: [String: [ProjectInfoSection]] = [:]
    var extraImages: [String: [ProjectImage]] = [:]

    enum CodingKeys: String, CodingKey {
        case shortcuts, infoSections, images, sectionLayout, extraInfo, extraImages
        case id, title, kind, projectPath, conferenceName, independentDeadlineString, tasks,
             reviewerComments, rebuttalNotes, decision, improvementSuggestions, githubRepoURLString,
             lastUpdated, dateCreated, ideaDescription, links, parentID, libraryGroupID, libraryGroupIDs, ideaRichText, iconSystemName, iconColorHex
    }

    init(
        id: UUID = UUID(), title: String, kind: ProjectKind = .paperSubmission, projectPath: String? = nil,
        conferenceName: String? = nil, independentDeadlineString: String? = nil, tasks: [PaperTask] = [],
        reviewerComments: [ReviewerComment] = [], rebuttalNotes: String = "", decision: PaperDecision = .pending,
        improvementSuggestions: String = "", githubRepoURLString: String? = nil, lastUpdated: Date = Date(),
        dateCreated: Date = Date(), ideaDescription: String = "", links: [String] = [], parentID: UUID? = nil,
        libraryGroupID: UUID? = nil, libraryGroupIDs: [UUID] = [], ideaRichText: Data? = nil,
        iconSystemName: String? = nil, iconColorHex: String? = nil, shortcuts: [ProjectShortcut] = [],
        infoSections: [ProjectInfoSection] = [], images: [ProjectImage] = [],
        sectionLayout: [ProjectSectionEntry] = []
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
        self.libraryGroupIDs = libraryGroupIDs
        self.ideaRichText = ideaRichText
        self.iconSystemName = iconSystemName
        self.iconColorHex = iconColorHex
        self.shortcuts = shortcuts
        self.infoSections = infoSections
        self.images = images
        self.sectionLayout = sectionLayout
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
        libraryGroupIDs = try container.decodeIfPresent([UUID].self, forKey: .libraryGroupIDs) ?? []
        ideaRichText = try container.decodeIfPresent(Data.self, forKey: .ideaRichText)
        iconSystemName = try container.decodeIfPresent(String.self, forKey: .iconSystemName)
        iconColorHex = try container.decodeIfPresent(String.self, forKey: .iconColorHex)
        shortcuts = try container.decodeIfPresent([ProjectShortcut].self, forKey: .shortcuts) ?? []
        infoSections = try container.decodeIfPresent([ProjectInfoSection].self, forKey: .infoSections) ?? []
        images = try container.decodeIfPresent([ProjectImage].self, forKey: .images) ?? []
        sectionLayout = try container.decodeIfPresent([ProjectSectionEntry].self, forKey: .sectionLayout) ?? []
        extraInfo = try container.decodeIfPresent([String: [ProjectInfoSection]].self, forKey: .extraInfo) ?? [:]
        extraImages = try container.decodeIfPresent([String: [ProjectImage]].self, forKey: .extraImages) ?? [:]
        libraryGroupID = try container.decodeIfPresent(UUID.self, forKey: .libraryGroupID)
        if let legacy = libraryGroupID {
            if !libraryGroupIDs.contains(legacy) { libraryGroupIDs.append(legacy) }
            libraryGroupID = nil
        }
    }
}

extension Paper {
    var cardIcon: String { iconSystemName ?? kind.icon }
    var doneTaskCount: Int { tasks.filter(\.isDone).count }
    var githubRepoURL: URL? {
        guard let githubRepoURLString, let url = URL(string: githubRepoURLString), url.scheme != nil else { return nil }
        return url
    }
}

/// A button at the top of a project's page — opens a folder on this Mac in Finder, or a website
/// inside Maziar (its own window with the app's embedded browser).
struct ProjectShortcut: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case folder, website }

    var id = UUID()
    var kind: Kind
    var title: String
    /// A folder's absolute path, or a website's address.
    var target: String
    /// Optional button color (hex); nil = the neutral default look.
    var colorHex: String?
    /// Optional label color; nil picks white or black automatically to read well on `colorHex`.
    var textColorHex: String?

    var icon: String { kind == .folder ? "folder.fill" : "globe" }

    /// The website address with `https://` added when none was typed; nil if it can't form a web URL.
    var webURL: URL? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let full = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// What the "project-web" window shows. `id` is the shortcut's id, so the window's zoom and
/// light/dark choices stay with that shortcut, and opening it twice reuses the same window.
struct ProjectWebTarget: Codable, Hashable {
    var id: UUID
    var title: String
    var urlString: String
}

/// One tab of a project's Information — a titled rich-text box.
struct ProjectInfoSection: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var rtf: Data?
    var plain: String = ""
}

/// One picture in a project's Images section.
struct ProjectImage: Codable, Equatable, Identifiable {
    var id = UUID()
    /// The copy's file name inside this project's image folder.
    var fileName: String
    var caption: String = ""
}

/// The kinds of box a project page is made of.
enum ProjectSectionKind: String, Codable, CaseIterable {
    case latexProject, venue, information, tasks, notes, images, subProjects, reviewer, decision, generate, codePage, links, libraryGroups

    var defaultTitle: String {
        switch self {
        case .latexProject: return "LaTeX Project"
        case .venue: return "Conference / Journal"
        case .information: return "Information"
        case .tasks: return "Tasks"
        case .notes: return "Notes"
        case .images: return "Images"
        case .subProjects: return "Sub-Projects"
        case .reviewer: return "Reviewer Comments & Rebuttal"
        case .decision: return "Decision"
        case .generate: return "Poster & Slides"
        case .codePage: return "Code Page"
        case .links: return "Links & References"
        case .libraryGroups: return "Library Groups"
        }
    }

    /// Information, Notes and Images boxes can be added more than once.
    var isRepeatable: Bool { self == .information || self == .notes || self == .images }

    /// The id the built-in (non-extra) box of this kind always has.
    var primaryID: UUID {
        let index = Self.allCases.firstIndex(of: self) ?? 0
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000000%02d", index)) ?? UUID()
    }

    func applies(to projectKind: ProjectKind) -> Bool {
        switch self {
        case .latexProject, .venue, .reviewer, .decision, .generate, .codePage: return projectKind == .paperSubmission
        case .links: return projectKind == .developing
        default: return true
        }
    }
}

/// One box on a project's page, in display order.
struct ProjectSectionEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: ProjectSectionKind
    /// A custom title; nil = the kind's default.
    var title: String?
    /// True for a box the user added (the built-in one of each kind is not extra).
    var isExtra: Bool = false

    var displayTitle: String { title ?? kind.defaultTitle }
}

extension Paper {
    static func defaultLayout(for kind: ProjectKind) -> [ProjectSectionEntry] {
        let order: [ProjectSectionKind] = kind == .paperSubmission
            ? [.latexProject, .venue, .information, .tasks, .notes, .images, .subProjects, .reviewer, .decision, .generate, .codePage, .libraryGroups]
            : [.information, .tasks, .notes, .images, .subProjects, .links, .libraryGroups]
        return order.map { ProjectSectionEntry(id: $0.primaryID, kind: $0) }
    }

    /// The saved order, with any built-in box it doesn't know yet appended.
    var layout: [ProjectSectionEntry] {
        guard !sectionLayout.isEmpty else { return Self.defaultLayout(for: kind) }
        var result = sectionLayout.filter { $0.kind.applies(to: kind) }
        for entry in Self.defaultLayout(for: kind) where !result.contains(where: { $0.id == entry.id }) {
            result.append(entry)
        }
        return result
    }
}
