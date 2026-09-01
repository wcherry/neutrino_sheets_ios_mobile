import Foundation
import NeutrinoCore

// MARK: - SheetFileInfo

/// The metadata Drive returns for a single file from `GET /api/v1/drive/files/{id}/info`.
///
/// This is the only Drive endpoint that answers for a file the caller can *access* rather than one
/// the caller *owns*, which makes it the right source for three things:
///
/// - `mimeType` — whether the file is a native spreadsheet at all. `/info` answers for every file
///   type, so this check has to happen here; see ``isNativeSheet``.
/// - `yourRole` — what this account may do with the workbook, which decides whether the editor is
///   writable.
/// - `contentVersion` — the value to send back as `expectedContentVersion` on the next save.
struct SheetFileInfo: Decodable, Hashable {

    // MARK: - Properties

    let id: String
    let name: String
    let sizeBytes: Int64
    let folderID: String?
    let mimeType: String?
    let updatedAt: Date
    /// Non-nil when the file is in the Trash. `/info` still describes a trashed file, unlike the
    /// listings, which drop it. Drive rejects an autosave into the trash outright, so this is worth
    /// knowing before a save is attempted.
    let deletedAt: Date?
    let yourRole: ShareRole
    /// Drive's `content_version`, bumped by one on every content write.
    ///
    /// Sending it back as `expectedContentVersion` is what lets the *server* reject a stale write.
    /// Comparing `updatedAt` instead could only ever be a check-then-write: another device can land
    /// an edit in the gap between the check and the upload.
    ///
    /// Optional because a server predating the field omits it; a nil version means the save goes
    /// unguarded.
    let contentVersion: Int?

    // MARK: - Init

    init(id: String, name: String, sizeBytes: Int64, folderID: String?, mimeType: String?,
         updatedAt: Date, deletedAt: Date? = nil, yourRole: ShareRole, contentVersion: Int? = nil) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.folderID = folderID
        self.mimeType = mimeType
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.yourRole = yourRole
        self.contentVersion = contentVersion
    }

    // MARK: - Computed

    /// True when the file is still somewhere an edit can land.
    var isLive: Bool { deletedAt == nil }

    /// True when this file is a native Neutrino spreadsheet.
    ///
    /// The web client synthesises its own 404 when this is false, and that is load-bearing rather
    /// than incidental: office mode (Epic 23) keys off exactly that signal to decide it must parse
    /// the file as `.xlsx`. Phase 1 has no office mode, so a false here is reported to the user as
    /// "this isn't a spreadsheet this app can open" — but the *check* lives here from the start, so
    /// Epic 23 has a hook rather than a rewrite.
    var isNativeSheet: Bool { mimeType == SheetItem.sheetMIME }

    /// Whether this account may write to the workbook.
    var isEditable: Bool { yourRole.canEdit }

    // MARK: - Decoding

    /// Drive's zone-less timestamps, camelCase keys — the same shapes the file listings use.
    static let decoder: JSONDecoder = DriveDate.makeDecoder()

    private enum CodingKeys: String, CodingKey {
        case id, name, sizeBytes, mimeType, updatedAt, deletedAt, yourRole, contentVersion
        case folderID = "folderId"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        folderID = try container.decodeIfPresent(String.self, forKey: .folderID)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        // Absent means the caller owns it: `/info` omits the field for a file in the caller's own
        // drive, and every non-shared listing this app calls is owner-scoped server-side.
        yourRole = ShareRole(serverValue: try container.decodeIfPresent(String.self, forKey: .yourRole) ?? "owner")
        contentVersion = try container.decodeIfPresent(Int.self, forKey: .contentVersion)
    }
}
