import Foundation
import SwiftUI

/// One paper in the reference library — a Mendeley-style personal collection of papers you've
/// read/collected, distinct from `Paper` (which tracks a paper *you're writing and submitting*).
/// A paper can belong to any number of groups at once (or none); since a group is a real folder,
/// belonging to N groups means N real copies of the file exist (see `LibraryStore` for why
/// duplicating rather than symlinking) — `rootFileName`/`groupFileNames` is the map of "which
/// filename does this paper's copy have in each of the places it lives," since a name collision
/// could force a slightly different name in one location than another.
struct LibraryEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var authors: String?
    var year: String?
    var venue: String?
    var doi: String?
    /// The first author's university or company, if known — filled in by Extract Info with AI,
    /// or typed in by hand. Powers one of the categories in the Library page's keyword strip.
    var affiliation: String?
    var abstract: String?
    var tags: [String] = []
    /// Kept only as a migration fallback — notes now live in a real companion `.txt` file next to
    /// the PDF (see `LibraryStore.notesFileURL`/`readNotes`/`writeNotes`), not in this JSON blob,
    /// so they're a real, Drive-backed-up file like everything else in the library rather than
    /// something that only exists inside Maziar's own settings storage.
    var notes: String = ""
    var dateAdded: Date = Date()
    /// The filename of the copy living directly in the library root, if there is one.
    var rootFileName: String?
    /// Every group this paper also belongs to, and the filename of its copy in that group's folder.
    var groupFileNames: [UUID: String] = [:]
    /// YouTube video links attached to this paper (talks, tutorials, author walkthroughs) — shown
    /// in the Reader window's Video mode. Full URLs, not just IDs, so a link typed in a form other
    /// than `youtube.com/watch?v=` still round-trips exactly as entered.
    var videoLinks: [String] = []
    /// GitHub repository links attached to this paper (its official implementation, a reproduction,
    /// etc.) — shown in the Reader window's Code mode. Stored as the canonical `github.com/owner/
    /// repo` URL regardless of which specific page (file, folder, issue) the link was captured
    /// from, so different deep links into the same repo are recognized as duplicates.
    var codeLinks: [String] = []
    /// This paper's assigned label color (`LibraryStore.paperLabels`), if any — shown as a small
    /// colored circle next to its title in the Library list. A dangling id (the color it pointed to
    /// was since deleted) is treated the same as no color at all by whatever reads it, rather than
    /// needing a migration pass every time a color is removed.
    var labelColorID: UUID?
    /// This paper's reading-order number, if any (`LibraryStore.paperLabelNumbers`), shown printed
    /// inside that same circle. Independent of `labelColorID` — a paper can have a color, a number,
    /// both, or neither, chosen separately from the circle's right-click menu.
    var labelNumber: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, authors, year, venue, doi, affiliation, abstract, tags, notes, dateAdded,
             rootFileName, groupFileNames, videoLinks, codeLinks, labelColorID, labelNumber
    }

    init(
        id: UUID = UUID(), title: String, authors: String? = nil, year: String? = nil, venue: String? = nil,
        doi: String? = nil, affiliation: String? = nil, abstract: String? = nil, tags: [String] = [],
        notes: String = "", dateAdded: Date = Date(), rootFileName: String? = nil,
        groupFileNames: [UUID: String] = [:], videoLinks: [String] = [], codeLinks: [String] = [],
        labelColorID: UUID? = nil, labelNumber: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.doi = doi
        self.affiliation = affiliation
        self.abstract = abstract
        self.tags = tags
        self.notes = notes
        self.dateAdded = dateAdded
        self.rootFileName = rootFileName
        self.groupFileNames = groupFileNames
        self.videoLinks = videoLinks
        self.codeLinks = codeLinks
        self.labelColorID = labelColorID
        self.labelNumber = labelNumber
    }

    /// Custom decode so every field added after this struct's first release — `videoLinks`,
    /// `codeLinks`, whichever comes next tomorrow — falls back to its default instead of failing
    /// the whole decode. A plain Swift default value (`= []` etc.) does NOT provide that fallback
    /// for synthesized `Decodable` conformance — a missing key still throws `keyNotFound` for a
    /// non-Optional property regardless of its declared default, which would silently discard
    /// every already-saved library entry on next launch. Same fix already applied to `Paper` in
    /// `PaperModels.swift` after that exact failure mode was caught there; verified empirically
    /// here too before shipping — decoding a pre-`videoLinks` JSON fixture into this struct threw
    /// `keyNotFound` under plain synthesis and decodes cleanly with this custom init.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        authors = try container.decodeIfPresent(String.self, forKey: .authors)
        year = try container.decodeIfPresent(String.self, forKey: .year)
        venue = try container.decodeIfPresent(String.self, forKey: .venue)
        doi = try container.decodeIfPresent(String.self, forKey: .doi)
        affiliation = try container.decodeIfPresent(String.self, forKey: .affiliation)
        abstract = try container.decodeIfPresent(String.self, forKey: .abstract)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
        rootFileName = try container.decodeIfPresent(String.self, forKey: .rootFileName)
        groupFileNames = try container.decodeIfPresent([UUID: String].self, forKey: .groupFileNames) ?? [:]
        videoLinks = try container.decodeIfPresent([String].self, forKey: .videoLinks) ?? []
        codeLinks = try container.decodeIfPresent([String].self, forKey: .codeLinks) ?? []
        labelColorID = try container.decodeIfPresent(UUID.self, forKey: .labelColorID)
        labelNumber = try container.decodeIfPresent(Int.self, forKey: .labelNumber)
    }
}

/// A named collection of papers ("Group" in the UI) — backed by an actual subfolder of the
/// library root, same "the folder IS the model" idea as the root library folder itself. Shown as
/// a card at the top of the Library page; clicking one filters the list to just that group's
/// papers.
struct LibraryGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// The subfolder's actual name on disk — kept in sync with `name` (renaming the group renames
    /// the folder too), but tracked separately since sanitizing `name` into a filesystem-safe
    /// folder name can change it slightly (e.g. stripped "/").
    var folderName: String
    /// A built-in SF Symbol name, used when `customIconData` isn't set.
    var iconSystemName: String = "folder.fill"
    /// Tint for the symbol (ignored when `customIconData` is set — a picked image keeps its own
    /// colors). Hex-encoded via the same `Color.toHex()`/`init?(hex:)` the rest of the app's
    /// custom colors already use (AppSettings.swift); nil means "use the app's accent color".
    var iconColorHex: String?
    /// A small PNG thumbnail if the user picked their own image for this group's card, instead of
    /// a symbol — stored inline (groups are few, images are thumbnail-sized) rather than as
    /// separate files, so the whole group list stays in one persisted JSON blob like `entries`.
    var customIconData: Data?
    /// Free-text description, comma-style keywords, and reference links — shown in a hover tooltip
    /// on the group's card rather than cluttering the card itself.
    var info: String = ""
    var keywords: [String] = []
    var links: [String] = []
    var dateCreated: Date = Date()
}

/// One entry in the Reader window's highlighter palette — a named color the user can apply to
/// selected PDF text. User-managed (add/rename/remove) rather than a fixed set, same "don't
/// preload a lot, let the user grow their own list" idea as `LibraryStore.translatorLanguages`.
struct HighlightColorOption: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Hex-encoded via the same `Color.toHex()`/`init?(hex:)` the rest of the app's custom colors
    /// already use (AppSettings.swift).
    var colorHex: String

    var color: Color { Color(hex: colorHex) ?? .yellow }
}

/// One entry in the Library page's paper-label color palette — a named color a paper can be
/// tagged with, shown as a small circle next to its title in the list (`LibraryStore.paperLabels`;
/// user-managed in Settings, same pattern as `HighlightColorOption`). Independent of
/// `LibraryStore.paperLabelNumbers` — a paper's color and its reading-order number are chosen
/// separately, from the circle's own right-click menu, not bundled into one combined label.
struct PaperLabelOption: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var colorHex: String

    var color: Color { Color(hex: colorHex) ?? .red }
}

/// How the Library page orders its list.
enum LibrarySortMode: String, CaseIterable, Identifiable {
    case dateAdded
    case title
    case year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateAdded: return "Date Added"
        case .title: return "Title"
        case .year: return "Year"
        }
    }
}
