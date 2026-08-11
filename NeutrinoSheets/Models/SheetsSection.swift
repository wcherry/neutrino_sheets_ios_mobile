import Foundation

// MARK: - SheetsSection

/// The top-level sections of the Drive browser (Epic 1 — "Tabs", Epic 4 — "Browse with `?type=sheet`").
enum SheetsSection: String, CaseIterable, Identifiable {
    /// The user's own spreadsheets, navigable by folder.
    case home      = "Home"
    /// `GET /api/v1/drive/recent?type=sheet` — most recently modified, newest first.
    case recent    = "Recent"
    /// `GET /api/v1/drive/starred?type=sheet` — Drive's `isStarred` flag.
    case favorites = "Favorites"
    /// `GET /api/v1/drive/shared-with-me?type=sheet` — spreadsheets other people own.
    case shared    = "Shared"
    case trash     = "Trash"

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Display

    /// SF Symbol representing this section.
    var iconName: String {
        switch self {
        case .home:      return "house"
        case .recent:    return "clock"
        case .favorites: return "star"
        case .shared:    return "person.2"
        case .trash:     return "trash"
        }
    }

    /// Whether this section navigates into folders.
    ///
    /// Only Home does. Recent and Favorites are flat server-side listings that deliberately cut
    /// across the folder tree, and Shared is flat by necessity: Drive's folder listings are
    /// owner-scoped, so the contents of somebody else's folder cannot be enumerated at all.
    var supportsFolderNavigation: Bool { self == .home }

    /// Copy shown when the section has nothing in it (Epic 1 — "Empty states").
    var emptyMessage: String {
        switch self {
        case .home:      return "No spreadsheets yet. Tap + to create one."
        case .recent:    return "Spreadsheets you open or edit will appear here."
        case .favorites: return "Star a spreadsheet to keep it here."
        case .shared:    return "Spreadsheets other people share with you will appear here."
        case .trash:     return "Trash is empty."
        }
    }

    /// SF Symbol for the empty state.
    var emptyIcon: String {
        switch self {
        case .home:      return "tablecells"
        case .recent:    return "clock.arrow.circlepath"
        case .favorites: return "star.slash"
        case .shared:    return "person.2.slash"
        case .trash:     return "trash.slash"
        }
    }
}
