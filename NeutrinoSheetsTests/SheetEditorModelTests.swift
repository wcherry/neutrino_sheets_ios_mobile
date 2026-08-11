import XCTest
import Sodium
@testable import NeutrinoSheets

/// The editor's save behaviour: the serialised chain, the conflict path, and what an edit does to
/// the workbook.
@MainActor
final class SheetEditorModelTests: XCTestCase {

    private var service: SheetContentService!
    private var model: SheetEditorModel!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestKeys.install()
        TestTokens.install()
        service = SheetContentService(session: MockURLProtocol.makeSession())
        model = SheetEditorModel(item: Fixture.sheet(id: "s1", contentVersion: 4),
                                 contentService: service, driveService: nil)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestKeys.remove()
        TestTokens.remove()
        TestServer.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func stubLoad(workbook: String, role: String = "owner") throws {
        let dek = Sodium().secretStream.xchacha20poly1305.key()
        let sealed = try service.sealDEK(dek)
        let ciphertext = try service.encrypt(text: workbook, dek: dek,
                                             xcss: Sodium().secretStream.xchacha20poly1305)
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let ok = { (data: Data) in
                (HTTPURLResponse(url: request.url!, statusCode: 200,
                                 httpVersion: nil, headerFields: nil)!, data)
            }
            if path.hasSuffix("/info") {
                return ok(Data("""
                {"id":"s1","name":"Budget","sizeBytes":10,"folderId":null,
                 "mimeType":"\(SheetItem.sheetMIME)","updatedAt":"2026-08-10T12:00:00",
                 "yourRole":"\(role)","contentVersion":4}
                """.utf8))
            }
            if path.hasSuffix("/key") { return ok(Data("{\"encrypted_file_key\":\"\(sealed)\"}".utf8)) }
            if request.httpMethod == "PUT" {
                return ok(Data("""
                {"id":"s1","name":"Budget","folderId":null,"sizeBytes":42,
                 "mimeType":"\(SheetItem.sheetMIME)","updatedAt":"2026-08-10T12:05:00",
                 "contentVersion":5}
                """.utf8))
            }
            return ok(ciphertext)
        }
    }

    // MARK: - Loading

    func testLoadPopulatesTheWorkbookAndSelectsA1() async throws {
        try stubLoad(workbook: #"{"sheets":[{"name":"Q3","cells":{"A1":{"id":"A1","value":"7"}}}]}"#)

        await model.load()

        XCTAssertEqual(model.sheetNames, ["Q3"])
        XCTAssertEqual(model.selection, CellAddress(column: 1, row: 1))
        XCTAssertEqual(model.selectedCell?.value, "7")
        XCTAssertTrue(model.isEditable)
        XCTAssertNil(model.loadError)
    }

    func testASharedViewerCannotEdit() async throws {
        try stubLoad(workbook: #"{"sheets":[{"cells":{}}]}"#, role: "viewer")

        await model.load()

        XCTAssertFalse(model.isEditable)
        // And an edit attempt is a no-op rather than a local change that can never be saved.
        model.commitEdit("hello", at: CellAddress(column: 1, row: 1))
        XCTAssertNil(model.selectedCell)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    // MARK: - Editing

    func testCommittingAValueMarksTheWorkbookDirty() async throws {
        try stubLoad(workbook: #"{"sheets":[{"cells":{}}]}"#)
        await model.load()

        model.commitEdit("42", at: CellAddress(column: 2, row: 3))

        XCTAssertTrue(model.hasUnsavedChanges)
        let cell = model.activeSheet?.cells["B3"]
        XCTAssertEqual(cell?.raw, "42")
        // `value` is written too, because it is what the grid and the web app's viewer read.
        XCTAssertEqual(cell?.value, "42")
    }

    func testClearingACellRemovesItRatherThanStoringItBlank() async throws {
        try stubLoad(workbook: #"{"sheets":[{"cells":{"A1":{"id":"A1","raw":"x","value":"x"}}}]}"#)
        await model.load()

        model.commitEdit("", at: CellAddress(column: 1, row: 1))

        // An empty cell is an absent key in the web app's output, not a key holding "".
        XCTAssertNil(model.activeSheet?.cells["A1"])
    }

    func testClearingAStyledCellKeepsItsFormatting() async throws {
        try stubLoad(workbook: """
        {"sheets":[{"cells":{"A1":{"id":"A1","raw":"x","value":"x",
                                   "cellStyle":{"fontWeight":"bold"}}}}]}
        """)
        await model.load()

        model.commitEdit("", at: CellAddress(column: 1, row: 1))

        // Dropping the cell entirely would silently discard the user's formatting.
        XCTAssertEqual(model.activeSheet?.cells["A1"]?.cellStyle?.fontWeight, "bold")
        XCTAssertNil(model.activeSheet?.cells["A1"]?.raw)
    }

    /// With no evaluator (Epic 15), storing a formula would write a `value` that is just the
    /// formula's text — and the web app would then show that text where a number belongs.
    func testFormulasAreRecognisedSoTheEditorCanRefuseThem() {
        XCTAssertTrue(SheetEditorModel.isFormula("=SUM(A1:A9)"))
        XCTAssertTrue(SheetEditorModel.isFormula("  =A1+1"))
        XCTAssertFalse(SheetEditorModel.isFormula("42"))
        XCTAssertFalse(SheetEditorModel.isFormula("a = b"))
    }

    // MARK: - The save chain

    /// Two autosave PUTs in flight at once truncated the second request's body in the web app.
    /// The chain is what stops that, and this is the test that says so.
    func testSavesNeverOverlap() async throws {
        try stubLoad(workbook: #"{"sheets":[{"cells":{}}]}"#)
        await model.load()

        let tracker = ConcurrencyTracker()
        let previous = MockURLProtocol.handler
        MockURLProtocol.handler = { request in
            guard request.httpMethod == "PUT" else { return try previous!(request) }
            tracker.enter()
            // Long enough that an unserialised second request would overlap this one.
            Thread.sleep(forTimeInterval: 0.05)
            tracker.leave()
            return try previous!(request)
        }

        model.commitEdit("1", at: CellAddress(column: 1, row: 1))
        model.queueSave()
        // Let the first save actually start, so the next one is queued against a request that is
        // already on the wire — the situation that truncated bodies in the browser.
        for _ in 0..<50 { await Task.yield() }

        model.commitEdit("2", at: CellAddress(column: 1, row: 2))
        model.queueSave()
        model.commitEdit("3", at: CellAddress(column: 1, row: 3))
        model.queueSave()

        await model.flush()

        XCTAssertGreaterThanOrEqual(tracker.total, 2)
        XCTAssertEqual(tracker.maxConcurrent, 1, "two autosave PUTs were in flight at once")
    }

    func testASuccessfulSaveClearsTheDirtyFlagAndAdvancesTheVersion() async throws {
        try stubLoad(workbook: #"{"sheets":[{"cells":{}}]}"#)
        await model.load()

        model.commitEdit("1", at: CellAddress(column: 1, row: 1))
        await model.flush()

        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNil(model.saveError)
        // The first save is guarded against the version the file was opened at.
        let first = MockURLProtocol.requests.last { $0.httpMethod == "PUT" }
        XCTAssertEqual(first?.url?.query, "expectedContentVersion=4")

        // The second must use the version the first one produced (5), or it would be rejected as
        // stale against an edit this device itself made.
        model.commitEdit("2", at: CellAddress(column: 1, row: 2))
        await model.flush()
        let next = MockURLProtocol.requests.last { $0.httpMethod == "PUT" }
        XCTAssertEqual(next?.url?.query, "expectedContentVersion=5")
    }

    func testAFailedSaveLeavesTheWorkbookDirty() async throws {
        try stubLoad(workbook: #"{"sheets":[{"cells":{}}]}"#)
        await model.load()

        let previous = MockURLProtocol.handler
        MockURLProtocol.handler = { request in
            guard request.httpMethod == "PUT" else { return try previous!(request) }
            return (HTTPURLResponse(url: request.url!, statusCode: 500,
                                    httpVersion: nil, headerFields: nil)!, Data())
        }

        model.commitEdit("1", at: CellAddress(column: 1, row: 1))
        await model.flush()

        // Otherwise the edit is silently dropped: the flag is the only record that it is unsaved.
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertNotNil(model.saveError)
    }

    // MARK: - Conflict

    func testA409StopsSavingAndAsksTheUser() async throws {
        try stubLoad(workbook: #"{"sheets":[{"cells":{}}]}"#)
        await model.load()

        let previous = MockURLProtocol.handler
        MockURLProtocol.handler = { request in
            guard request.httpMethod == "PUT" else { return try previous!(request) }
            return (HTTPURLResponse(url: request.url!, statusCode: 409,
                                    httpVersion: nil, headerFields: nil)!,
                    Data(#"{"error":{"code":"CONTENT_VERSION_CONFLICT","message":"found 9"}}"#.utf8))
        }

        model.commitEdit("1", at: CellAddress(column: 1, row: 1))
        await model.flush()

        XCTAssertNotNil(model.conflict)
        XCTAssertEqual(model.conflict?.serverVersion, 9)
        XCTAssertTrue(model.hasUnsavedChanges)

        // And nothing more is written until the user decides — saving over an unresolved conflict
        // is exactly what must not happen.
        let before = MockURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count
        model.saveIfNeeded()
        await model.flush()
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count, before)
    }

    func testKeepingTheLocalCopySavesAgainstTheServersVersion() async throws {
        try stubLoad(workbook: #"{"sheets":[{"cells":{}}]}"#)
        await model.load()

        let previous = MockURLProtocol.handler
        var failNext = true
        MockURLProtocol.handler = { request in
            guard request.httpMethod == "PUT" else { return try previous!(request) }
            if failNext {
                failNext = false
                return (HTTPURLResponse(url: request.url!, statusCode: 409,
                                        httpVersion: nil, headerFields: nil)!,
                        Data(#"{"error":{"code":"CONTENT_VERSION_CONFLICT","message":"found 9"}}"#.utf8))
            }
            return try previous!(request)
        }

        model.commitEdit("1", at: CellAddress(column: 1, row: 1))
        await model.flush()
        XCTAssertNotNil(model.conflict)

        model.keepLocalCopyAfterConflict()
        await model.flush()

        XCTAssertNil(model.conflict)
        // The retry is guarded against version 9 — the one the server said it holds — so it
        // overwrites *that* revision and nothing newer.
        let last = MockURLProtocol.requests.last { $0.httpMethod == "PUT" }
        XCTAssertEqual(last?.url?.query, "expectedContentVersion=9")
    }
}

// MARK: - ConcurrencyTracker

/// Counts how many requests are inside the handler at once.
private final class ConcurrencyTracker {
    private let lock = NSLock()
    private var current = 0
    private(set) var maxConcurrent = 0
    private(set) var total = 0

    func enter() {
        lock.lock()
        defer { lock.unlock() }
        current += 1
        total += 1
        maxConcurrent = max(maxConcurrent, current)
    }

    func leave() {
        lock.lock()
        defer { lock.unlock() }
        current -= 1
    }
}
