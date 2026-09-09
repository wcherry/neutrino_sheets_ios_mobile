import XCTest
import NeutrinoCore
@testable import NeutrinoSheets

/// Epic 4 — Drive integration. The listings all pass `?type=office` and then narrow to the
/// spreadsheet MIME types, which together are what keep documents, slides and drawings out of a
/// spreadsheet browser while still showing both formats a spreadsheet is stored in.
@MainActor
final class SheetsDriveServiceTests: XCTestCase {

    private var service: SheetsDriveService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        service = SheetsDriveService(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.reset()
        super.tearDown()
    }

    // MARK: - Listings

    func testHomeListsTheDriveRootFilteredToSpreadsheets() async {
        MockURLProtocol.respond(json: String(decoding: Fixture.listing(
            files: [Fixture.fileJSON(id: "s1", name: "Budget")],
            folders: [Fixture.folderJSON(id: "f1", name: "Finance")]
        ), as: UTF8.self))

        await service.load(.home)

        XCTAssertEqual(service.allItems.count, 2)
        let request = MockURLProtocol.requests.first
        // The root folder id is the user's own id, read from the token's `sub` claim.
        XCTAssertTrue(request?.url?.path.hasSuffix("/drive/folders/\(TestTokens.userId)") ?? false,
                      request?.url?.path ?? "")
        XCTAssertTrue(request?.url?.query?.contains("type=office") ?? false,
                      request?.url?.query ?? "")
    }

    func testEverySectionPassesTheOfficeTypeFilter() async {
        for section in SheetsSection.allCases {
            MockURLProtocol.reset()
            MockURLProtocol.respond(json: String(decoding: Fixture.listing(), as: UTF8.self))

            await service.load(section)

            let query = MockURLProtocol.requests.first?.url?.query ?? ""
            // `type=sheet` would be the obvious filter and is the bug: the server pins it to the
            // bespoke JSON alone, so a drive of `.xlsx` spreadsheets lists as empty.
            XCTAssertTrue(query.contains("type=office"),
                          "\(section.rawValue) did not filter by type: \(query)")
        }
    }

    /// The regression this exists for: a spreadsheet is a real `.xlsx`, and asking for `type=sheet`
    /// returned none of them.
    func testListingsShowXlsxSpreadsheets() async {
        MockURLProtocol.respond(json: String(decoding: Fixture.listing(files: [
            Fixture.fileJSON(id: "s1", name: "Budget.xlsx"),
        ]), as: UTF8.self))

        await service.load(.home)

        XCTAssertEqual(service.allItems.map(\.id), ["s1"])
        XCTAssertTrue(service.allItems[0].isNativeSheet)
    }

    /// `office` is coarser than the app needs — it also carries documents, decks and notes — so the
    /// narrowing on the way in is load-bearing, not tidiness. The bespoke JSON is narrowed out with
    /// everything else now that this app no longer reads it.
    func testTheOfficeCategoryIsNarrowedToSpreadsheets() async {
        MockURLProtocol.respond(json: String(decoding: Fixture.listing(files: [
            Fixture.fileJSON(id: "s1"),
            Fixture.fileJSON(id: "d1", mimeType: "application/x-neutrino-doc"),
            Fixture.fileJSON(id: "p1", mimeType: "application/x-neutrino-slide"),
            Fixture.fileJSON(id: "old", mimeType: "application/x-neutrino-sheet"),
            Fixture.fileJSON(id: "csv", mimeType: "text/csv"),
        ]), as: UTF8.self))

        await service.load(.home)

        XCTAssertEqual(service.allItems.map(\.id), ["s1"])
    }

    func testRecentIsNarrowedAfterTheServersWiderPage() async {
        MockURLProtocol.respond(json: String(decoding: Fixture.listing(files: [
            Fixture.fileJSON(id: "d1", mimeType: "application/x-neutrino-doc"),
            Fixture.fileJSON(id: "s1"),
        ]), as: UTF8.self))

        await service.load(.recent)

        XCTAssertEqual(service.recentItems.map(\.id), ["s1"])
        // The page has to be wider than the section, since the server applies `type` — now the
        // whole office category — before the limit.
        let query = MockURLProtocol.requests.first?.url?.query ?? ""
        XCTAssertTrue(query.contains("limit=500"), query)
    }

    func testTrashIsNarrowedToSpreadsheetsToo() async {
        MockURLProtocol.respond(json: """
        {"files":[
          {"id":"s1","name":"Budget.xlsx","mimeType":"\(SheetItem.sheetMIME)","sizeBytes":128,
           "deletedAt":"\(Fixture.driveTimestamp(Date(timeIntervalSince1970: 1_700_000_000)))"},
          {"id":"d1","name":"Notes","mimeType":"application/x-neutrino-doc","sizeBytes":128,
           "deletedAt":"\(Fixture.driveTimestamp(Date(timeIntervalSince1970: 1_700_000_000)))"}
        ],"folders":[]}
        """)

        await service.load(.trash)

        XCTAssertEqual(service.trashItems.map(\.id), ["s1"])
    }

    func testRecentPreservesTheServersOrdering() async {
        let older = Date(timeIntervalSince1970: 1_600_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_000)
        MockURLProtocol.respond(json: String(decoding: Fixture.listing(files: [
            Fixture.fileJSON(id: "new", name: "New", updatedAt: newer),
            Fixture.fileJSON(id: "old", name: "Old", updatedAt: older),
        ]), as: UTF8.self))

        await service.load(.recent)

        // Newest-first is the point of the listing, so it must not be re-sorted by name.
        XCTAssertEqual(service.recentItems.map(\.id), ["new", "old"])
    }

    func testSharedItemsAreFlaggedAndLoseTheOwnersStar() async {
        MockURLProtocol.respond(json: String(decoding: Fixture.listing(
            files: [Fixture.fileJSON(id: "s1", isStarred: true)],
            folders: [Fixture.folderJSON(id: "f1", isStarred: true)]
        ), as: UTF8.self))

        await service.load(.shared)

        XCTAssertTrue(service.sharedItems.allSatisfy(\.isShared))
        // `is_starred` is a single column, so it is the *owner's* star. Showing it would put a
        // Favorites badge on somebody else's file that this account never set and cannot clear.
        XCTAssertTrue(service.sharedItems.allSatisfy { !$0.isStarred })
        // A shared folder's parent id names a folder this account cannot list, so it is dropped.
        XCTAssertNil(service.sharedItems.first { $0.type == .folder }?.parentID)
    }

    func testAFailedLoadSurfacesAnErrorRatherThanThrowing() async {
        MockURLProtocol.respond(json: "{}", statusCode: 500)

        await service.load(.home)

        XCTAssertNotNil(service.error)
        XCTAssertFalse(service.isLoading)
    }

    func testReloadingAFolderDoesNotDuplicateRows() async {
        let body = String(decoding: Fixture.listing(files: [Fixture.fileJSON(id: "s1")]),
                          as: UTF8.self)
        MockURLProtocol.respond(json: body)

        await service.load(.home)
        await service.load(.home)

        XCTAssertEqual(service.allItems.filter { $0.id == "s1" }.count, 1)
    }

    // MARK: - Deep-link fetch

    func testFetchItemRejectsAFileThatIsNotASpreadsheet() async {
        MockURLProtocol.respond(json: Fixture.fileJSON(mimeType: "application/x-neutrino-doc"))

        do {
            _ = try await service.fetchItem(id: "doc-1")
            XCTFail("expected notFound")
        } catch let error as SheetsDriveError {
            guard case .notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFetchItemAcceptsANativeSpreadsheet() async throws {
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "s1"))
        let item = try await service.fetchItem(id: "s1")
        XCTAssertEqual(item.id, "s1")
        XCTAssertTrue(item.isNativeSheet)
    }

    /// `fetchItem` judges a file by what this app reads, not by the shared link vocabulary — which
    /// stays deliberately more forgiving about formats for the sake of links minted by clients that
    /// have not shipped this change.
    func testFetchItemRejectsTheBespokeJSONFormat() async {
        MockURLProtocol.respond(json: Fixture.fileJSON(mimeType: "application/x-neutrino-sheet"))

        do {
            _ = try await service.fetchItem(id: "old-1")
            XCTFail("expected notFound")
        } catch let error as SheetsDriveError {
            guard case .notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Mutations

    func testRenameIsOptimisticAndRollsBackOnFailure() async {
        service = SheetsDriveService(home: [Fixture.sheet(id: "s1", name: "Budget")],
                                     session: MockURLProtocol.makeSession())
        MockURLProtocol.respond(json: "{}", statusCode: 500)

        service.rename(itemID: "s1", to: "Renamed")
        // The local model changes first, so the row updates without waiting for the server. The
        // stored name carries the extension; `displayName` is what the user sees.
        XCTAssertEqual(service.item(id: "s1")?.name, "Renamed.xlsx")
        XCTAssertEqual(service.item(id: "s1")?.displayName, "Renamed")

        await settle()
        XCTAssertEqual(service.item(id: "s1")?.name, "Budget")
        XCTAssertNotNil(service.error)
    }

    func testRenameSendsAPatchToTheDriveFileEndpoint() async {
        service = SheetsDriveService(home: [Fixture.sheet(id: "s1", name: "Budget")],
                                     session: MockURLProtocol.makeSession())
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "s1", name: "Renamed"))

        service.rename(itemID: "s1", to: "Renamed")
        await settle()

        let request = try? XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request?.httpMethod, "PATCH")
        XCTAssertTrue(request?.url?.path.hasSuffix("/drive/files/s1") ?? false)
    }

    /// A spreadsheet *is* an `.xlsx`, so its Drive file has to be named `Budget.xlsx` — that is what
    /// has to land on disk for a download to open on a double-click. Typing the extension twice must
    /// not produce `Budget.xlsx.xlsx`.
    func testSpreadsheetNamesCarryTheXlsxExtension() async {
        // `route` matches on `contains`, so the more specific paths come first.
        MockURLProtocol.route([
            (suffix: "/autosave", statusCode: 200,
             body: Data(Fixture.fileJSON(id: "new-1", name: "Budget.xlsx").utf8)),
            (suffix: "/key", statusCode: 200, body: Data(#"{"encrypted_file_key":"x"}"#.utf8)),
            (suffix: "/drive/files", statusCode: 201,
             body: Data(Fixture.fileJSON(id: "new-1", name: "Budget.xlsx").utf8)),
        ])
        TestKeys.install()
        defer { TestKeys.remove() }

        let content = SheetContentService(session: MockURLProtocol.makeSession())
        service.contentService = content
        _ = try? await service.createSpreadsheet(name: "Budget.xlsx", parentID: nil)

        let body = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodies[0]) as? [String: Any]
        XCTAssertEqual(body?["name"] as? String, "Budget.xlsx")
    }

    func testStarringUpdatesFavoritesWithoutARefetch() async {
        service = SheetsDriveService(home: [Fixture.sheet(id: "s1")],
                                     session: MockURLProtocol.makeSession())
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "s1", isStarred: true))

        service.setStarred(itemID: "s1", isStarred: true)
        await settle()

        XCTAssertEqual(service.starredItems.map(\.id), ["s1"])
        XCTAssertEqual(service.item(id: "s1")?.isStarred, true)
    }

    func testUnstarringRemovesTheRowFromFavorites() async {
        service = SheetsDriveService(home: [Fixture.sheet(id: "s1", isStarred: true)],
                                     starred: [Fixture.sheet(id: "s1", isStarred: true)],
                                     session: MockURLProtocol.makeSession())
        MockURLProtocol.respond(json: Fixture.fileJSON(id: "s1"))

        service.setStarred(itemID: "s1", isStarred: false)
        await settle()

        XCTAssertTrue(service.starredItems.isEmpty)
    }

    func testTrashingMovesTheRowAndClearsItFromRecentsAndFavorites() async {
        service = SheetsDriveService(home: [Fixture.sheet(id: "s1", isStarred: true)],
                                     recents: [Fixture.sheet(id: "s1")],
                                     starred: [Fixture.sheet(id: "s1", isStarred: true)],
                                     session: MockURLProtocol.makeSession())
        MockURLProtocol.respond(json: #"{"affected":1}"#)

        service.delete(itemID: "s1")
        await settle()

        XCTAssertEqual(service.trashItems.map(\.id), ["s1"])
        XCTAssertTrue(service.allItems.isEmpty)
        // A trashed file is excluded from both server-side views, so leaving a row here would
        // offer to open a deleted spreadsheet.
        XCTAssertTrue(service.recentItems.isEmpty)
        XCTAssertTrue(service.starredItems.isEmpty)
    }

    func testMovingAFolderIntoItsOwnSubtreeIsRefused() {
        service = SheetsDriveService(home: [
            Fixture.folder(id: "parent"),
            Fixture.folder(id: "child", parentID: "parent"),
        ], session: MockURLProtocol.makeSession())

        // Would detach the whole subtree from the drive.
        service.move(itemID: "parent", to: "child")

        XCTAssertNil(service.item(id: "parent")?.parentID)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    func testDescendantDetection() {
        service = SheetsDriveService(home: [
            Fixture.folder(id: "a"),
            Fixture.folder(id: "b", parentID: "a"),
            Fixture.folder(id: "c", parentID: "b"),
        ], session: MockURLProtocol.makeSession())

        XCTAssertTrue(service.isDescendant(potentialChildID: "c", ofFolderID: "a"))
        XCTAssertTrue(service.isDescendant(potentialChildID: "a", ofFolderID: "a"))
        XCTAssertFalse(service.isDescendant(potentialChildID: "a", ofFolderID: "c"))
    }

    func testBreadcrumbWalksUpToTheRoot() {
        service = SheetsDriveService(home: [
            Fixture.folder(id: "a", name: "A"),
            Fixture.folder(id: "b", name: "B", parentID: "a"),
        ], session: MockURLProtocol.makeSession())

        XCTAssertEqual(service.breadcrumb(to: "b").map(\.name), ["A", "B"])
        XCTAssertTrue(service.breadcrumb(to: nil).isEmpty)
    }

    // MARK: - Offline

    func testMutationsAreRefusedWhenOffline() async {
        // `autoStart: false` so a real `NWPathMonitor` cannot race the stubbed state.
        let monitor = NetworkMonitor(autoStart: false)
        monitor.setOnlineForTesting(false)
        service = SheetsDriveService(home: [Fixture.sheet(id: "s1", name: "Budget")],
                                     session: MockURLProtocol.makeSession())
        service.networkMonitor = monitor

        service.rename(itemID: "s1", to: "Renamed")
        await settle()

        // Phase 1 has no offline queue (Epic 12), so a mutation is refused up front rather than
        // silently dropped — the name must not be left showing a change that never happened.
        XCTAssertEqual(service.item(id: "s1")?.name, "Budget")
        XCTAssertNotNil(service.error)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    // MARK: - Editor callbacks

    func testSaveCallbackUpdatesEveryListingHoldingTheRow() {
        service = SheetsDriveService(home: [Fixture.sheet(id: "s1")],
                                     recents: [Fixture.sheet(id: "s1")],
                                     session: MockURLProtocol.makeSession())
        let saved = Date(timeIntervalSince1970: 1_800_000_000)

        service.spreadsheetWasSaved(itemID: "s1", size: 4096, modifiedAt: saved, contentVersion: 9)

        XCTAssertEqual(service.allItems.first?.size, 4096)
        XCTAssertEqual(service.allItems.first?.contentVersion, 9)
        XCTAssertEqual(service.recentItems.first?.modifiedAt, saved)
    }

    // MARK: - Helpers

    /// Lets the fire-and-forget `Task`s inside the optimistic mutations run to completion.
    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}
