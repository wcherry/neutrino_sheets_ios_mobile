import XCTest
import Sodium
@testable import NeutrinoSheets

/// Epic 10 — structure through the editor: what lands in the workbook, what undo puts back, and
/// what deliberately never reaches the file at all.
///
/// The engines are covered on their own in `StructuralShiftTests`, `SortEngineTests` and friends.
/// What this suite is for is the wiring: a structural edit is the first kind that cannot be
/// described as a set of cell patches, so it takes a different route through the undo history, and
/// a route that works for values but not for rows would only show up here.
@MainActor
final class SheetStructureTests: XCTestCase {

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

    /// Four rows in one column, so the row that moves is obvious in a failure message.
    private var listWorkbook: String {
        #"""
        {"sheets":[{"name":"Q3","cells":{
          "A1":{"id":"A1","raw":"Header","value":"Header"},
          "A2":{"id":"A2","raw":"One","value":"One"},
          "A3":{"id":"A3","raw":"Two","value":"Two"},
          "A4":{"id":"A4","raw":"Three","value":"Three"}}}]}
        """#
    }

    private var twoTabWorkbook: String {
        #"""
        {"sheets":[
          {"name":"Q3","cells":{"A1":{"id":"A1","raw":"x","value":"x"}}},
          {"name":"Q4","cells":{"A1":{"id":"A1","raw":"y","value":"y"}}}]}
        """#
    }

    // MARK: - Insert and delete

    func testInsertingARowAboveTheSelectionPushesItDown() async throws {
        try await load(listWorkbook)
        select("A2")

        model.insertRows(before: true)

        XCTAssertEqual(cell("A1")?.value, "Header")
        XCTAssertNil(cell("A2"))
        XCTAssertEqual(cell("A3")?.value, "One")
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    func testInsertingBelowPutsTheRowUnderTheSelection() async throws {
        try await load(listWorkbook)
        select("A2")

        model.insertRows(before: false)

        XCTAssertEqual(cell("A2")?.value, "One")
        XCTAssertNil(cell("A3"))
        XCTAssertEqual(cell("A4")?.value, "Two")
    }

    func testAThreeRowSelectionInsertsThreeRows() async throws {
        try await load(listWorkbook)
        select("A2", "A4")

        model.insertRows(before: true)

        XCTAssertEqual(cell("A1")?.value, "Header")
        XCTAssertEqual(cell("A5")?.value, "One")
        // And the selection follows the new rows, so typing goes where the user was looking.
        XCTAssertEqual(model.selection?.range.address, "A2:A4")
    }

    func testDeletingARowPullsTheRestUp() async throws {
        try await load(listWorkbook)
        select("A2")

        model.deleteRows()

        XCTAssertEqual(cell("A2")?.value, "Two")
        XCTAssertEqual(cell("A3")?.value, "Three")
        XCTAssertNil(cell("A4"))
    }

    func testDeletingSeveralRowsRemovesExactlyThose() async throws {
        try await load(listWorkbook)
        select("A2", "A3")

        model.deleteRows()

        XCTAssertEqual(cell("A1")?.value, "Header")
        XCTAssertEqual(cell("A2")?.value, "Three")
        XCTAssertNil(cell("A3"))
    }

    func testInsertingAColumnShiftsAcross() async throws {
        try await load(#"""
        {"sheets":[{"name":"Q3","cells":{
          "A1":{"id":"A1","raw":"left","value":"left"},
          "B1":{"id":"B1","raw":"right","value":"right"}}}]}
        """#)
        select("B1")

        model.insertColumns(before: true)

        XCTAssertEqual(cell("A1")?.value, "left")
        XCTAssertNil(cell("B1"))
        XCTAssertEqual(cell("C1")?.value, "right")
    }

    // MARK: - Undo

    func testUndoingAnInsertPutsEveryRowBack() async throws {
        try await load(listWorkbook)
        select("A2")
        model.insertRows(before: true)

        model.undo()

        XCTAssertEqual(cell("A2")?.value, "One")
        XCTAssertEqual(cell("A3")?.value, "Two")
        XCTAssertEqual(cell("A4")?.value, "Three")
        XCTAssertNil(cell("A5"))
    }

    func testRedoingAnInsertAppliesItAgain() async throws {
        try await load(listWorkbook)
        select("A2")
        model.insertRows(before: true)
        model.undo()

        model.redo()

        XCTAssertNil(cell("A2"))
        XCTAssertEqual(cell("A3")?.value, "One")
    }

    func testUndoingADeleteBringsTheRowBack() async throws {
        try await load(listWorkbook)
        select("A2")
        model.deleteRows()

        model.undo()

        XCTAssertEqual(cell("A2")?.value, "One")
        XCTAssertEqual(cell("A4")?.value, "Three")
    }

    func testAStructuralUndoAndACellUndoShareOneHistory() async throws {
        // The two kinds of edit take different routes through `WorkbookEdit`, and a history that
        // could only unwind one of them would strand the other.
        try await load(listWorkbook)
        select("A2")
        model.commitEdit("Edited", at: CellAddress("A2")!)
        model.insertRows(before: true)

        model.undo()
        XCTAssertEqual(cell("A2")?.value, "Edited")

        model.undo()
        XCTAssertEqual(cell("A2")?.value, "One")
        XCTAssertFalse(model.canUndo)
    }

    // MARK: - Sizes

    func testResizingWritesTheWidthUnderItsZeroBasedKey() async throws {
        try await load(listWorkbook)

        model.resize(columns: 2...2, to: 180)

        // Column B is index 1 in the workbook's 0-based key space. Getting this off by one would
        // resize the neighbouring column, on both clients.
        XCTAssertEqual(model.activeSheet?.colWidths?["1"], 180)
    }

    func testResizingARangeSetsEveryColumnInIt() async throws {
        try await load(listWorkbook)

        model.resize(columns: 1...3, to: 120)

        XCTAssertEqual(model.activeSheet?.colWidths, ["0": 120, "1": 120, "2": 120])
    }

    func testHidingStoresZeroSoTheWebHidesItToo() async throws {
        try await load(listWorkbook)
        select("A2", "A3")

        model.hideRows()

        XCTAssertEqual(model.activeSheet?.rowHeights?["1"], 0)
        XCTAssertEqual(model.activeSheet?.rowHeights?["2"], 0)
        XCTAssertTrue(model.hasHiddenRowsOrColumns)
    }

    func testShowingRemovesTheOverrideRatherThanGuessingAHeight() async throws {
        try await load(listWorkbook)
        select("A2")
        model.hideRows()

        select("A1", "A3")
        model.showSelection()

        // An absent key means "the default", which is what an unhidden row should be. Writing back
        // a number would freeze it at whatever this app's default happened to be.
        XCTAssertNil(model.activeSheet?.rowHeights?["1"])
        XCTAssertFalse(model.hasHiddenRowsOrColumns)
    }

    func testShowEverythingKeepsDeliberateSizes() async throws {
        try await load(listWorkbook)
        model.resize(rows: 1...1, to: 60)
        select("A2")
        model.hideRows()

        model.showEverything()

        XCTAssertEqual(model.activeSheet?.rowHeights?["0"], 60)
        XCTAssertNil(model.activeSheet?.rowHeights?["1"])
    }

    // MARK: - Sorting

    func testSortingASingleCellSelectionSortsTheWholeUsedRange() async throws {
        try await load(#"""
        {"sheets":[{"name":"Q3","cells":{
          "A1":{"id":"A1","raw":"Chris","value":"Chris"},
          "B1":{"id":"B1","raw":"30","value":"30"},
          "A2":{"id":"A2","raw":"Ada","value":"Ada"},
          "B2":{"id":"B2","raw":"10","value":"10"}}}]}
        """#)
        select("A1")

        model.sort(by: 1, ascending: true)

        XCTAssertEqual(cell("A1")?.value, "Ada")
        XCTAssertEqual(cell("B1")?.value, "10")
        XCTAssertEqual(cell("A2")?.value, "Chris")
        XCTAssertEqual(cell("B2")?.value, "30")
    }

    func testSortingAMergedRangeIsRefusedRatherThanAttempted() async throws {
        try await load(#"""
        {"sheets":[{"name":"Q3","cells":{
          "A1":{"id":"A1","raw":"b","value":"b","rowSpan":2},
          "A2":{"id":"A2","mergeAnchor":"A1"}}}]}
        """#)
        select("A1")

        model.sort(by: 1, ascending: true)

        XCTAssertEqual(cell("A1")?.rowSpan, 2)
        XCTAssertEqual(model.notice, "Cannot sort a range that contains merged cells")
        XCTAssertFalse(model.canUndo)
    }

    // MARK: - Filters

    func testAFilterHidesTheRowsThatDoNotMatch() async throws {
        try await load(listWorkbook)

        model.setFilter(["One", "Two"], forColumn: 1)

        XCTAssertEqual(model.filteredRows, [1, 4])
    }

    func testAFilterIsNeverWrittenToTheWorkbook() async throws {
        try await load(listWorkbook)
        let before = model.file

        model.setFilter(["One"], forColumn: 1)

        // Not an edit: nothing to save, and nothing in the file for the browser to misread.
        XCTAssertEqual(model.file, before)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testFilterValuesOfferBlanksAndAreDeduplicated() async throws {
        try await load(#"""
        {"sheets":[{"name":"Q3","cells":{
          "A1":{"id":"A1","raw":"b","value":"b"},
          "A2":{"id":"A2","raw":"a","value":"a"},
          "A3":{"id":"A3","raw":"a","value":"a"}}}]}
        """#)

        XCTAssertEqual(model.filterValues(inColumn: 1), ["a", "b", ""])
    }

    func testMovingToAnotherTabDropsTheFilters() async throws {
        try await load(twoTabWorkbook)
        model.setFilter(["x"], forColumn: 1)

        model.selectSheet(at: 1)

        XCTAssertTrue(model.columnFilters.isEmpty)
    }

    // MARK: - Find & replace

    func testReplaceAllRewritesEveryMatchAsOneEdit() async throws {
        try await load(#"""
        {"sheets":[{"name":"Q3","cells":{
          "A1":{"id":"A1","raw":"draft one","value":"draft one"},
          "A2":{"id":"A2","raw":"draft two","value":"draft two"}}}]}
        """#)

        let count = model.replaceAll(query: "draft", with: "final", options: FindReplace.Options())

        XCTAssertEqual(count, 2)
        XCTAssertEqual(cell("A1")?.value, "final one")
        XCTAssertEqual(cell("A2")?.value, "final two")

        model.undo()
        XCTAssertEqual(cell("A1")?.value, "draft one")
        XCTAssertEqual(cell("A2")?.value, "draft two")
    }

    func testReplacingAFormulaSaysItWillRecalculate() async throws {
        try await load(#"""
        {"sheets":[{"name":"Q3","cells":{
          "A1":{"id":"A1","raw":"=SUM(B1:B9)","value":"42"}}}]}
        """#)

        model.replaceAll(query: "B", with: "C", options: FindReplace.Options())

        XCTAssertEqual(cell("A1")?.raw, "=SUM(C1:C9)")
        XCTAssertNil(cell("A1")?.value)
        XCTAssertEqual(model.notice,
                       "Replaced formulas recalculate when the sheet is opened on the web")
    }

    // MARK: - Tabs

    func testAddingATabMovesToItAndNamesItUniquely() async throws {
        try await load(twoTabWorkbook)

        model.addSheet()

        XCTAssertEqual(model.sheetNames, ["Q3", "Q4", "Sheet 3"])
        XCTAssertEqual(model.activeSheetIndex, 2)
    }

    func testRenamingATabWritesItIntoTheWorkbook() async throws {
        try await load(twoTabWorkbook)

        model.renameSheet(at: 0, to: "  Summary  ")

        XCTAssertEqual(model.sheetNames.first, "Summary")
    }

    func testDuplicatingATabPutsTheCopyBesideIt() async throws {
        try await load(twoTabWorkbook)

        model.duplicateSheet(at: 0)

        XCTAssertEqual(model.sheetNames, ["Q3", "Q3 (copy)", "Q4"])
        XCTAssertEqual(model.activeSheetIndex, 1)
        XCTAssertEqual(model.activeSheet?.cells["A1"]?.value, "x")
    }

    func testDeletingTheActiveTabLandsOnTheOneBeforeIt() async throws {
        try await load(twoTabWorkbook)
        model.selectSheet(at: 1)

        model.deleteSheet(at: 1)

        XCTAssertEqual(model.sheetNames, ["Q3"])
        XCTAssertEqual(model.activeSheetIndex, 0)
    }

    func testTheLastTabCannotBeDeleted() async throws {
        try await load(listWorkbook)

        XCTAssertFalse(model.canDeleteSheet)
        model.deleteSheet(at: 0)

        XCTAssertEqual(model.sheetNames, ["Q3"])
    }

    func testUndoingATabDeleteBringsItBackWithItsCells() async throws {
        try await load(twoTabWorkbook)
        model.deleteSheet(at: 1)

        model.undo()

        XCTAssertEqual(model.sheetNames, ["Q3", "Q4"])
        XCTAssertEqual(model.file?.sheets[1].cells["A1"]?.value, "y")
    }

    func testMovingATabCarriesTheActiveSelectionWithIt() async throws {
        try await load(twoTabWorkbook)
        model.selectSheet(at: 1)

        model.moveSheet(at: 1, by: -1)

        XCTAssertEqual(model.sheetNames, ["Q4", "Q3"])
        XCTAssertEqual(model.activeSheetIndex, 0)
    }

    func testSettingATabColourStoresACssColour() async throws {
        try await load(twoTabWorkbook)

        model.setSheetColor("#22c55e", at: 0)

        XCTAssertEqual(model.file?.sheets[0].color, "#22c55e")
    }

    // MARK: - Freeze

    func testFreezingRecordsTheRowsAndColumnsAboveAndLeftOfTheSelection() async throws {
        try await load(listWorkbook)
        select("B3")

        model.freezeToSelection()

        XCTAssertEqual(model.frozen, FrozenPanes(rows: 2, columns: 1))
    }

    func testFreezingIsNeverWrittenToTheWorkbook() async throws {
        try await load(listWorkbook)
        let before = model.file
        select("B3")

        model.freezeToSelection()

        // The format has no field for it, so it stays on the device. See `SheetEditorModel.frozen`.
        XCTAssertEqual(model.file, before)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testFreezingIsPerTab() async throws {
        try await load(twoTabWorkbook)
        select("B3")
        model.freezeToSelection()

        model.selectSheet(at: 1)

        XCTAssertTrue(model.frozen.isEmpty)
    }

    func testRearrangingTabsForgetsTheFrozenPanes() async throws {
        // They are keyed by index, and a move renumbers those indices — carrying them would freeze
        // a tab the user never froze.
        try await load(twoTabWorkbook)
        select("B3")
        model.freezeToSelection()

        model.moveSheet(at: 0, by: 1)

        XCTAssertTrue(model.frozen.isEmpty)
    }

    // MARK: - Read-only

    func testAViewerCannotChangeTheStructure() async throws {
        try await load(listWorkbook, role: "viewer")
        select("A2")

        model.insertRows(before: true)
        model.deleteRows()
        model.hideRows()
        model.addSheet()
        model.resize(columns: 1...1, to: 200)

        XCTAssertEqual(cell("A2")?.value, "One")
        XCTAssertEqual(model.sheetNames.count, 1)
        XCTAssertNil(model.activeSheet?.colWidths)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    // MARK: - Saving

    func testAStructuralEditSurvivesARoundTripThroughTheEncoder() async throws {
        try await load(listWorkbook)
        select("A2")
        model.insertRows(before: true)

        let encoded = try XCTUnwrap(model.file).encoded()
        let reloaded = SheetFile.decode(from: encoded)

        XCTAssertEqual(reloaded.sheets.first?.cells["A3"]?.value, "One")
        XCTAssertEqual(reloaded.sheets.first?.cells["A3"]?.id, "A3")
    }
}
