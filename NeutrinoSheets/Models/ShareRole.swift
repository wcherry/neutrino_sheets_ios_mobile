import Foundation

// MARK: - ShareRole

/// What the signed-in account may do with a document, as reported by `yourRole` on
/// `GET /api/v1/drive/files/{id}/info`.
///
/// Phase 1 does not grant or manage permissions — that is Phase 4 — but it still has to *honour*
/// them: a document somebody shared read-only must open in the viewer rather than the editor.
enum ShareRole: String, Codable, Hashable, CaseIterable {
    case owner
    case editor
    case commenter
    case viewer

    // MARK: - Decoding

    /// Maps the server's string, defaulting unknown values to the least privileged role.
    ///
    /// Defaulting *down* is deliberate: a role this build does not recognise is more safely
    /// treated as read-only than as write access, and the server rejects the write anyway.
    init(serverValue: String) {
        self = ShareRole(rawValue: serverValue.lowercased()) ?? .viewer
    }

    // MARK: - Capabilities

    /// Whether this role may change the document's content.
    var canEdit: Bool {
        switch self {
        case .owner, .editor:   return true
        case .commenter, .viewer: return false
        }
    }

    /// Whether this role may rename, move, trash, star, or manage versions of the document.
    /// Drive scopes all of those to the owner.
    var canManage: Bool { self == .owner }

    // MARK: - Display

    var displayName: String {
        switch self {
        case .owner:     return "Owner"
        case .editor:    return "Editor"
        case .commenter: return "Commenter"
        case .viewer:    return "Viewer"
        }
    }
}
