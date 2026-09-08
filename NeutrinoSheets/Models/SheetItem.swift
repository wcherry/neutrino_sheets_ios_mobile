import Foundation
import NeutrinoOOXML

// MARK: - SheetItem

/// A single folder or spreadsheet within the user's Neutrino Drive.
struct SheetItem: Identifiable, Hashable {

    // MARK: - ItemType

    enum ItemType {
        case folder
        case file
    }

    // MARK: - MIME

    /// What a Neutrino spreadsheet is: a real Excel workbook.
    ///
    /// A spreadsheet created by any Neutrino client is an `.xlsx` (`src/drive/storage/native_types.rs`,
    /// issue #127), which this app reads and writes through `NeutrinoOOXML` — so Excel, LibreOffice
    /// and Google's editors open one directly, and import and export are file copies.
    ///
    /// The bespoke `application/x-neutrino-sheet` JSON that predates it is gone from this app. Not
    /// migrated — there was nothing left to migrate — simply no longer a format it reads, writes,
    /// lists or routes.
    static let sheetMIME = XlsxCodec.mimeType

    /// Every MIME type this app browses.
    ///
    /// One entry, and it stays a list because that is the shape both call sites want and because
    /// the server's `type=` filter cannot express "a spreadsheet" on its own — see
    /// ``SheetsDriveService``.
    static let spreadsheetMIMEs = [XlsxCodec.mimeType]

    /// Whether a Drive file is a Neutrino spreadsheet.
    static func isSpreadsheet(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        return spreadsheetMIMEs.contains(mimeType)
    }

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
    /// One of ``spreadsheetMIMEs`` for spreadsheets; `nil` for folders.
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
        type == .folder ? "folder.fill" : "tablecells.fill"
    }

    /// True when this file is a Neutrino spreadsheet.
    ///
    /// This is the client-side check consequence 2 of the roadmap's API section calls for: `/info`
    /// answers for *any* file type now, so nothing server-side will tell the app it opened the
    /// wrong thing.
    var isNativeSheet: Bool {
        type == .file && Self.isSpreadsheet(mimeType)
    }

    /// The title to show.
    ///
    /// An `.xlsx` is a real workbook and its extension is part of the *file* name — it has to land
    /// on disk as `Budget.xlsx` to open on a double-click — but the spreadsheet is called "Budget",
    /// which is what the web library shows too (`stripOoxmlExtension` in `web/packages/api-core`).
    var displayName: String {
        type == .file ? XlsxCodec.strippingExtension(name) : name
    }

    /// The name a "Duplicate" should get: `Book.xlsx` -> `Book copy.xlsx`.
    ///
    /// The extension stays last, because `Book.xlsx copy` is a file the operating system no longer
    /// recognises.
    var duplicateName: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return name + " copy"
        }
        return name[..<dot] + " copy" + name[dot...]
    }
}
