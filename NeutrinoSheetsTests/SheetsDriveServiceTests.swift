import XCTest
@testable import NeutrinoSheets

/// Epic 4 — Drive integration. The listings all pass `?type=sheet`, which is the only thing keeping
/// documents, slides and drawings out of a spreadsheet browser.
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
        XCTAssertTrue(request?.url?.query?.contains("type=sheet") ?? false,
                      request?.url?.query ?? "")
    }

    func testEverySectionPassesTheSheetTypeFilter() async {
        for section in SheetsSection.allCases {
            MockURLProtocol.reset()
            MockURLProtocol.respond(json: String(decoding: Fixture.listing(), as: UTF8.self))

            await service.load(section)

            let query = MockURLProtocol.requests.first?.url?.query ?? ""
            XCTAssertTrue(query.contains("type=sheet"),
                          "\(section.rawValue) did not filter by type: \(query)")
        }
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

    // MARK: - Mutations

    func testRenameIsOptimisticAndRollsBackOnFailure() async {
        service = SheetsDriveService(home: [Fixture.sheet(id: "s1", name: "Budget")],
                                     session: MockURLProtocol.makeSession())
        MockURLProtocol.respond(json: "{}", statusCode: 500)

        service.rename(itemID: "s1", to: "Renamed")
        // The local model changes first, so the row updates without waiting for the server.
        XCTAssertEqual(service.item(id: "s1")?.name, "Renamed")

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

    /// Unlike Neutrino Docs, which appends `.md`, a spreadsheet is identified by its MIME type
    /// alone. Adding an extension would show up as a stray suffix in every listing on the web.
    func testSpreadsheetNamesGetNoExtension() async {
        MockURLProtocol.route([
            (suffix: "/drive/files", statusCode: 201,
             body: Data(Fixture.fileJSON(id: "new-1", name: "Budget").utf8)),
            (suffix: "/key", statusCode: 200, body: Data(#"{"encrypted_file_key":"x"}"#.utf8)),
        ])
        TestKeys.install()
        defer { TestKeys.remove() }

        let content = SheetContentService(session: MockURLProtocol.makeSession())
        service.contentService = content
        _ = try? await service.createSpreadsheet(name: "Budget", parentID: nil)

        let body = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodies[0]) as? [String: Any]
        XCTAssertEqual(body?["name"] as? String, "Budget")
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
