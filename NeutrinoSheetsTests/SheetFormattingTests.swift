import XCTest
import Sodium
@testable import NeutrinoSheets

/// Epic 9 — formatting through the editor: what lands in the workbook, and what undo puts back.
///
/// Separate from `SheetEditorModelTests` because the questions are different. That suite is about
/// the save chain and the conflict path; this one is about the cells, and specifically about the
/// two ways a formatting command can quietly corrupt a shared file — writing a style the browser
/// does not read, and dropping something it does.
@MainActor
final class SheetFormattingTests: XCTestCase {

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
                                 contentService: service, driveService: nil,
                                 pasteboard: MemoryPasteboard())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestKeys.remove()
        TestTokens.remove()
        TestServer.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func load(_ workbook: String, role: String = "owner") async throws {
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
            return ok(ciphertext)
        }
        await model.load()
    }

    private func select(_ start: String, _ end: String? = nil) {
        let anchor = CellAddress(start)!
        model.selection = SheetSelection(anchor: anchor, active: CellAddress(end ?? start)!)
    }

    private func cell(_ id: String) -> SavedCell? {
        model.activeSheet?.cells[id]
    }

    private var sampleWorkbook: String {
        #"""
        {"sheets":[{"name":"Q3","cells":{
          "A1":{"id":"A1","raw":"Revenue","value":"Revenue"},
          "B1":{"id":"B1","raw":"1250.5","value":"1250.5"},
          "A2":{"id":"A2","raw":"Costs","value":"Costs"},
          "B2":{"id":"B2","raw":"400","value":"400"}}}]}
        """#
    }

    // MARK: - Applying a style

    func testAStyleAppliesToEveryCellInTheSelection() async throws {
        try await load(sampleWorkbook)
        select("A1", "B2")

        model.applyStyle(.bold(true), name: "Bold")

        for id in ["A1", "B1", "A2", "B2"] {
            XCTAssertEqual(cell(id)?.cellStyle?.fontWeight, "bold", id)
        }
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    /// Formatting an empty range is how a table gets prepared before anything is typed into it, so
    /// the cells are created — this is what the web app stores too.
    func testAStyleCreatesCellsThatDidNotExist() async throws {
        try await load(sampleWorkbook)
        select("D4", "D5")

        model.applyStyle(.fillColor("#fef3c7"), name: "Fill")

        XCTAssertEqual(cell("D4")?.cellStyle?.backgroundColor, "#fef3c7")
        XCTAssertNil(cell("D4")?.value)
    }

    func testStylingLeavesValuesAlone() async throws {
        try await load(sampleWorkbook)
        select("B1")

        model.applyStyle(.numberFormat("currency"), name: "Currency")

        XCTAssertEqual(cell("B1")?.raw, "1250.5")
        XCTAssertEqual(cell("B1")?.value, "1250.5")
        XCTAssertEqual(cell("B1")?.cellStyle?.numberFormat, "currency")
    }

    func testAReadOnlyShareCannotBeFormatted() async throws {
        try await load(sampleWorkbook, role: "viewer")
        select("A1")

        model.applyStyle(.bold(true), name: "Bold")

        XCTAssertNil(cell("A1")?.cellStyle)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testTheActiveCellsStyleIsWhatTheControlsRead() async throws {
        try await load(sampleWorkbook)
        select("A1")
        model.applyStyle(.bold(true), name: "Bold")

        XCTAssertEqual(model.selectionStyle?.isBold, true)

        select("B2")
        XCTAssertNil(model.selectionStyle)
    }

    // MARK: - Clearing

    func testClearFormattingRemovesTheStyleButKeepsTheValue() async throws {
        try await load(sampleWorkbook)
        select("A1")
        model.applyStyle(.bold(true), name: "Bold")
        model.applyStyle(.fillColor("#eef2ff"), name: "Fill")

        model.clearFormatting()

        XCTAssertNil(cell("A1")?.cellStyle)
        XCTAssertEqual(cell("A1")?.value, "Revenue")
    }

    /// A cell that only ever held formatting is removed outright rather than left as an id and
    /// nothing else, which is the shape the web app never writes.
    func testClearFormattingRemovesACellThatHeldNothingElse() async throws {
        try await load(sampleWorkbook)
        select("D4")
        model.applyStyle(.fillColor("#eef2ff"), name: "Fill")
        XCTAssertNotNil(cell("D4"))

        model.clearFormatting()

        XCTAssertNil(cell("D4"))
    }

    // MARK: - Undo

    func testUndoRestoresTheStyleThatWasThereBefore() async throws {
        try await load(sampleWorkbook)
        select("A1", "B1")
        model.applyStyle(.textColor("#b91c1c"), name: "Text Colour")

        model.undo()

        XCTAssertNil(cell("A1")?.cellStyle)
        XCTAssertNil(cell("B1")?.cellStyle)

        model.redo()
        XCTAssertEqual(cell("A1")?.cellStyle?.color, "#b91c1c")
    }

    func testAStyleThatChangesNothingIsNotRecorded() async throws {
        try await load(sampleWorkbook)
        select("A1")
        model.applyStyle(.bold(true), name: "Bold")
        let token = model.historyToken

        model.applyStyle(.bold(true), name: "Bold")

        XCTAssertEqual(model.historyToken, token, "re-applying the same style is not an edit")
    }

    // MARK: - Merge

    func testMergingWritesTheAnchorAndItsCoveredCells() async throws {
        try await load(sampleWorkbook)
        select("A1", "B2")

        model.toggleMerge()

        XCTAssertEqual(cell("A1")?.colSpan, 2)
        XCTAssertEqual(cell("A1")?.rowSpan, 2)
        XCTAssertEqual(cell("B2")?.mergeAnchor, "A1")
        XCTAssertTrue(model.isSelectionMerged)
        // The selection collapses onto the anchor, which is the only cell the block now edits.
        XCTAssertEqual(model.selection?.range.address, "A1")
    }

    func testTheSameCommandUnmergesAndSelectsWhatWasSplit() async throws {
        try await load(sampleWorkbook)
        select("A1", "B2")
        model.toggleMerge()

        model.toggleMerge()

        XCTAssertNil(cell("A1")?.colSpan)
        XCTAssertNil(cell("B2")?.mergeAnchor)
        XCTAssertFalse(model.isSelectionMerged)
        XCTAssertEqual(model.selection?.range.address, "A1:B2")
    }

    func testMergingASingleCellDoesNothing() async throws {
        try await load(sampleWorkbook)
        select("A1")
        let token = model.historyToken

        model.toggleMerge()

        XCTAssertNil(cell("A1")?.colSpan)
        XCTAssertEqual(model.historyToken, token)
    }

    func testUndoingAMergePutsTheBlockBack() async throws {
        try await load(sampleWorkbook)
        select("A1", "B2")
        model.toggleMerge()

        model.undo()

        XCTAssertNil(cell("A1")?.colSpan)
        XCTAssertNil(cell("B2")?.mergeAnchor)
        XCTAssertEqual(cell("B2")?.value, "400")
    }

    // MARK: - Table styles

    func testApplyingATableStyleBandsTheRangeAndRecordsARegion() async throws {
        try await load(sampleWorkbook)
        select("A1", "B2")
        let style = try XCTUnwrap(TableStyles.style(withID: "blue-banded"))

        model.applyTableStyle(style)

        XCTAssertEqual(cell("A1")?.cellStyle?.backgroundColor, "#1e40af")
        XCTAssertEqual(cell("A1")?.cellStyle?.color, "#ffffff")
        XCTAssertEqual(cell("A2")?.cellStyle?.backgroundColor, "#ffffff")
        XCTAssertEqual(model.tableRegions.count, 1)
        XCTAssertEqual(model.tableRegions.first?.styleId, "blue-banded")
        XCTAssertEqual(model.tableRegions.first?.range.address, "A1:B2")
    }

    func testTheBlankStyleStripsTheFormattingAndForgetsTheRegion() async throws {
        try await load(sampleWorkbook)
        select("A1", "B2")
        model.applyTableStyle(try XCTUnwrap(TableStyles.style(withID: "blue-banded")))

        model.applyTableStyle(try XCTUnwrap(TableStyles.style(withID: "blank")))

        XCTAssertNil(cell("A1")?.cellStyle)
        XCTAssertEqual(cell("A1")?.value, "Revenue")
        XCTAssertTrue(model.tableRegions.isEmpty)
    }

    /// The region is part of the edit, so undo has to take it with it — otherwise a workbook keeps
    /// claiming a table whose colours have just been undone.
    func testUndoingATableStyleAlsoRemovesTheRegion() async throws {
        try await load(sampleWorkbook)
        select("A1", "B2")
        model.applyTableStyle(try XCTUnwrap(TableStyles.style(withID: "blue-banded")))

        model.undo()

        XCTAssertTrue(model.tableRegions.isEmpty)
        XCTAssertNil(cell("A1")?.cellStyle)

        model.redo()
        XCTAssertEqual(model.tableRegions.count, 1)
    }

    func testAStyleAppliedOverAnExistingTableReplacesItsRegion() async throws {
        try await load(sampleWorkbook)
        select("A1", "B2")
        model.applyTableStyle(try XCTUnwrap(TableStyles.style(withID: "blue-banded")))
        select("A1", "B4")
        model.applyTableStyle(try XCTUnwrap(TableStyles.style(withID: "rose-banded")))

        XCTAssertEqual(model.tableRegions.count, 1)
        XCTAssertEqual(model.tableRegions.first?.styleId, "rose-banded")
        XCTAssertEqual(model.tableRegions.first?.range.address, "A1:B4")
    }

    func testATableStyleSurvivesASaveAndReload() async throws {
        try await load(sampleWorkbook)
        select("A1", "B2")
        model.applyTableStyle(try XCTUnwrap(TableStyles.style(withID: "blue-banded")))

        // The regions have to be *written*: a save that dropped them would leave the colours with
        // nothing recording what they mean.
        let encoded = try XCTUnwrap(model.file).encoded()
        let reloaded = SheetFile.decode(from: encoded)

        XCTAssertEqual(reloaded.sheets.first?.tables?.first?.styleId, "blue-banded")
        XCTAssertEqual(reloaded.sheets.first?.cells["A1"]?.cellStyle?.backgroundColor, "#1e40af")
    }
}
