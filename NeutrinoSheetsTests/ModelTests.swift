import XCTest
@testable import NeutrinoSheets

/// The small models — the ones whose mistakes show up as a wrong icon, a stray extension, or an
/// editor opened on a file the user may not write to.
///
/// `@MainActor` because `AppSettings` and `DeepLinkRouter` are: both are read by the view tree on
/// every update, so their isolation is part of their design rather than an accident.
@MainActor
final class ModelTests: XCTestCase {

    // MARK: - SheetItem

    func testNativeSheetsAreDistinguishedFromOfficeFiles() {
        XCTAssertTrue(Fixture.sheet().isNativeSheet)
        XCTAssertFalse(Fixture.sheet(mimeType: SheetItem.xlsxMIME).isNativeSheet)
        XCTAssertTrue(Fixture.sheet(mimeType: SheetItem.xlsxMIME).isOfficeSpreadsheet)
        XCTAssertFalse(Fixture.folder().isNativeSheet)
    }

    func testDisplayNameKeepsPlainSpreadsheetNames() {
        // Unlike a Neutrino Doc, a spreadsheet has no extension to hide.
        XCTAssertEqual(Fixture.sheet(name: "Q3 Budget").displayName, "Q3 Budget")
        // A raw office file does.
        XCTAssertEqual(Fixture.sheet(name: "Book.xlsx", mimeType: SheetItem.xlsxMIME).displayName,
                       "Book")
    }

    func testDuplicateNameKeepsAnyExtensionLast() {
        XCTAssertEqual(Fixture.sheet(name: "Budget").duplicateName, "Budget copy")
        XCTAssertEqual(Fixture.sheet(name: "Book.xlsx").duplicateName, "Book copy.xlsx")
        // A leading dot is the whole name, not an extension.
        XCTAssertEqual(Fixture.sheet(name: ".hidden").duplicateName, ".hidden copy")
    }

    // MARK: - ShareRole

    func testUnknownRolesDefaultToTheLeastPrivileged() {
        // Defaulting *down* is deliberate: a role this build does not know is more safely read as
        // read-only than as write access.
        XCTAssertEqual(ShareRole(serverValue: "something-new"), .viewer)
        XCTAssertEqual(ShareRole(serverValue: "OWNER"), .owner)
    }

    func testEditCapability() {
        XCTAssertTrue(ShareRole.owner.canEdit)
        XCTAssertTrue(ShareRole.editor.canEdit)
        XCTAssertFalse(ShareRole.commenter.canEdit)
        XCTAssertFalse(ShareRole.viewer.canEdit)
    }

    // MARK: - SheetFileInfo

    func testFileInfoDefaultsAnAbsentRoleToOwner() throws {
        // `/info` omits `yourRole` for a file in the caller's own drive.
        let json = Data("""
        {"id":"s1","name":"Budget","sizeBytes":10,"folderId":null,
         "mimeType":"\(SheetItem.sheetMIME)","updatedAt":"2026-08-10T12:00:00"}
        """.utf8)

        let info = try SheetFileInfo.decoder.decode(SheetFileInfo.self, from: json)

        XCTAssertEqual(info.yourRole, .owner)
        XCTAssertTrue(info.isEditable)
        XCTAssertTrue(info.isNativeSheet)
        XCTAssertTrue(info.isLive)
        XCTAssertNil(info.contentVersion)
    }

    func testATrashedFileIsNotLive() throws {
        let json = Data("""
        {"id":"s1","name":"Budget","sizeBytes":10,"folderId":null,
         "mimeType":"\(SheetItem.sheetMIME)","updatedAt":"2026-08-10T12:00:00",
         "deletedAt":"2026-08-10T13:00:00","yourRole":"owner"}
        """.utf8)

        let info = try SheetFileInfo.decoder.decode(SheetFileInfo.self, from: json)

        // Drive rejects an autosave into the trash outright, so this is worth knowing before a
        // save is attempted.
        XCTAssertFalse(info.isLive)
    }

    // MARK: - App links

    func testSheetLinksAreAcceptedAndOtherKindsAreNot() {
        let router = DeepLinkRouter()

        XCTAssertTrue(router.handle(URL(string: "https://www.getneutrino.app/open/sheet/abc")!))
        XCTAssertEqual(router.pending?.fileID, "abc")

        router.clear()
        // A `/open/doc/…` link belongs to Neutrino Docs; opening it here would show an empty grid
        // where a document's text should be.
        XCTAssertFalse(router.handle(URL(string: "https://www.getneutrino.app/open/doc/abc")!))
        XCTAssertNil(router.pending)
    }

    func testConsumeClearsThePendingLink() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "https://getneutrino.app/open/sheet/abc")!)

        XCTAssertEqual(router.consume()?.fileID, "abc")
        XCTAssertNil(router.pending)
        XCTAssertNil(router.consume())
    }

    func testTheSheetMimeTypeMatchesTheAppLinkVocabulary() {
        // One wire format across separately shipped binaries: if these two ever disagree, links
        // route to the wrong app.
        XCTAssertEqual(NeutrinoAppLink.kind(forMIME: SheetItem.sheetMIME), .sheet)
    }

    // MARK: - Settings

    func testGridDefaultsMatchTheWebAppsConstants() {
        let defaults = UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)

        // `CELL_W` / `CELL_H` from the web app's `editor/constants.ts`. A sheet with no stored
        // widths must lay out identically in both clients.
        XCTAssertEqual(settings.defaultColumnWidth, 100)
        XCTAssertEqual(settings.defaultRowHeight, 28)
        XCTAssertEqual(settings.gridMetrics.defaultColumnWidth, 100)
    }

    func testStoredGeometryIsClampedOnRead() {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // A zero-width column would divide by zero in the grid's virtualisation.
        defaults.set(0.0, forKey: AppSettings.Keys.defaultColumnWidth)
        defaults.set(9999.0, forKey: AppSettings.Keys.defaultRowHeight)

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.defaultColumnWidth, AppSettings.columnWidthRange.lowerBound)
        XCTAssertEqual(settings.defaultRowHeight, AppSettings.rowHeightRange.upperBound)
    }

    func testResetRestoresDefaults() {
        let defaults = UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.theme = .dark
        settings.showGridLines = false
        settings.defaultColumnWidth = 200

        settings.resetToDefaults()

        XCTAssertEqual(settings.theme, .system)
        XCTAssertTrue(settings.showGridLines)
        XCTAssertEqual(settings.defaultColumnWidth, AppSettings.defaultColumnWidth)
    }

    // MARK: - Sections

    func testOnlyHomeNavigatesIntoFolders() {
        XCTAssertTrue(SheetsSection.home.supportsFolderNavigation)
        for section in SheetsSection.allCases where section != .home {
            // Recent and Favorites deliberately cut across the tree; Shared cannot be walked at
            // all, because Drive's folder listings are owner-scoped.
            XCTAssertFalse(section.supportsFolderNavigation, "\(section.rawValue)")
        }
    }

    func testEverySectionHasAnEmptyState() {
        for section in SheetsSection.allCases {
            XCTAssertFalse(section.emptyMessage.isEmpty)
            XCTAssertFalse(section.emptyIcon.isEmpty)
        }
    }
}
