import Foundation

// MARK: - SheetItem

/// A single folder or spreadsheet within the user's Neutrino Drive.
struct SheetItem: Identifiable, Hashable {

    // MARK: - ItemType

    enum ItemType {
        case folder
        case file
    }

    // MARK: - MIME

    /// The MIME type that *makes* a Drive file a spreadsheet.
    ///
    /// Since `40842e2` there is no `sheets` marker table and no `/api/v1/sheets` CRUD resource:
    /// membership in the server's `native_types` registry is the marker, and this string is the key
    /// into it (`src/drive/storage/native_types.rs`). It is also what the server's `type=sheet`
    /// filter matches, and what the client-side "is this a spreadsheet?" check in
    /// ``SheetContentService/fileInfo(for:)`` compares against.
    static let sheetMIME = "application/x-neutrino-sheet"

    /// Raw `.xlsx`, which Drive stores but this app cannot open yet — office mode is Epic 23.
    /// Recognised so a listing can show the file and say why it will not open, rather than dropping
    /// it or failing obscurely.
    static let xlsxMIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

    // MARK: - Properties

    let id: String
    var name: String
    let type: ItemType
    /// `nil` means the root of the drive.
    var parentID: String?
    /// Bytes; `nil` for folders.
    var size: Int64?
    var modifiedAt: Date
    var isTrashed: Bool
    /// ``sheetMIME`` for native spreadsheets; `nil` for folders.
    var mimeType: String?
    /// Drive's `isStarred` flag — the Favorites model shared with the web app, stored on the file or
    /// folder row itself rather than in a list of its own.
    var isStarred: Bool = false
    /// Drive's `contentVersion` as of the last time this device heard from the server. Sent back as
    /// `expectedContentVersion` on the next save so the server can reject a stale write; nil means
    /// unguarded.
    var contentVersion: Int?
    /// True for items reached through `GET /drive/shared-with-me`, i.e. owned by somebody else.
    var isShared: Bool = false

    // MARK: - Computed

    /// SF Symbol representing the item in a listing.
    var iconName: String {
        switch type {
        case .folder: return "folder.fill"
        case .file:   return isNativeSheet ? "tablecells.fill" : "doc.fill"
        }
    }

    /// True when this file is a native Neutrino spreadsheet rather than a raw office file.
    ///
    /// This is the client-side check consequence 2 of the roadmap's API section calls for: `/info`
    /// answers for *any* file type now, so nothing server-side will tell the app it opened the
    /// wrong thing.
    var isNativeSheet: Bool {
        type == .file && mimeType == Self.sheetMIME
    }

    /// A spreadsheet this app can list but not yet open — a raw `.xlsx`. Office mode (Epic 23) is
    /// what turns this into something openable.
    var isOfficeSpreadsheet: Bool {
        type == .file && mimeType == Self.xlsxMIME
    }

    /// The title to show. Spreadsheets are stored under their plain name — unlike Neutrino Docs,
    /// which appends `.md` — so only a raw office file has an extension worth hiding.
    var displayName: String {
        guard type == .file, isOfficeSpreadsheet else { return name }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// The name a "Duplicate" should get: `Budget` -> `Budget copy`, `Book.xlsx` -> `Book copy.xlsx`.
    var duplicateName: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return name + " copy"
        }
        return name[..<dot] + " copy" + name[dot...]
    }
}
