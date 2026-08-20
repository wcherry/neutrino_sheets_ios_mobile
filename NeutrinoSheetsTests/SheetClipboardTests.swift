import XCTest
@testable import NeutrinoSheets

/// Epic 8 — what a copied block carries, and what it writes when it lands.
final class SheetClipboardTests: XCTestCase {

    // MARK: - Helpers

    private func range(_ text: String) -> CellRange {
        let parts = text.split(separator: ":").map(String.init)
        let start = CellAddress(parts[0])!
        return CellRange(start, parts.count > 1 ? CellAddress(parts[1])! : start)
    }

    private func cells(_ values: [String: String]) -> [String: SavedCell] {
        values.reduce(into: [:]) { result, entry in
            result[entry.key] = SavedCell(id: entry.key, raw: entry.value, value: entry.value)
        }
    }

    // MARK: - Values

    func testACopiedBlockPastesAtItsOwnSizeFromTheSelectedCell() {
        let clipboard = SheetClipboard(range: range("A1:B2"),
                                       cells: cells(["A1": "1", "B1": "2",
                                                     "A2": "3", "B2": "4"]),
                                       isCut: false)

        let changes = clipboard.changes(at: CellAddress("D5")!, into: range("D5"), existing: [:])

        XCTAssertEqual(changes["D5"]??.value, "1")
        XCTAssertEqual(changes["E5"]??.value, "2")
        XCTAssertEqual(changes["D6"]??.value, "3")
        XCTAssertEqual(changes["E6"]??.value, "4")
    }

    /// Copy one cell, select a column, paste — the block tiles to fill the selection. Without this
    /// the most common paste on a phone writes a single cell and leaves the rest untouched.
    func testABlockTilesToFillALargerSelection() {
        let clipboard = SheetClipboard(range: range("A1"), cells: cells(["A1": "x"]), isCut: false)

        let changes = clipboard.changes(at: CellAddress("C1")!, into: range("C1:C3"), existing: [:])

        XCTAssertEqual(changes["C1"]??.value, "x")
        XCTAssertEqual(changes["C2"]??.value, "x")
        XCTAssertEqual(changes["C3"]??.value, "x")
    }

    /// A selection that is not a whole multiple of the block was not asking to be tiled, so the
    /// block lands at its own size rather than leaving half a tile at the far edge.
    func testASelectionThatIsNotAMultipleOfTheBlockPastesItAtItsOwnSize() {
        let clipboard = SheetClipboard(range: range("A1:A2"),
                                       cells: cells(["A1": "1", "A2": "2"]), isCut: false)

        let target = clipboard.target(at: CellAddress("C1")!, into: range("C1:C5"))

        XCTAssertEqual(target.address, "C1:C2")

        // ...and a selection that *is* a multiple tiles across all of it.
        XCTAssertEqual(clipboard.target(at: CellAddress("C1")!, into: range("C1:C6")).address,
                       "C1:C6")
    }

    func testStylesTravelWithTheCells() {
        var style = CellStyle()
        style.backgroundColor = "#ff0000"
        var source = cells(["A1": "1"])
        source["A1"]?.cellStyle = style

        let clipboard = SheetClipboard(range: range("A1"), cells: source, isCut: false)
        let changes = clipboard.changes(at: CellAddress("B2")!, into: range("B2"), existing: [:])

        XCTAssertEqual(changes["B2"]??.cellStyle?.backgroundColor, "#ff0000")
    }

    /// The reason the payload is encoded rather than copied verbatim: a formula has to shift with
    /// the block it belongs to.
    func testFormulasAreRewrittenForWhereTheyLand() {
        var source = cells([:])
        source["C1"] = SavedCell(id: "C1", raw: "=A1+$B$1", value: "3")

        let clipboard = SheetClipboard(range: range("C1"), cells: source, isCut: false)
        let changes = clipboard.changes(at: CellAddress("C2")!, into: range("C2"), existing: [:])

        XCTAssertEqual(changes["C2"]??.raw, "=A2+$B$1")
        // No evaluator until Epic 15, so the source's result is not carried across.
        XCTAssertNil(changes["C2"]??.value)
    }

    /// An empty cell inside a copied block has to erase what it lands on. Skipping it would leave
    /// the destination's old contents showing through the gaps in the pasted block.
    func testAnEmptyCellInTheBlockClearsItsDestination() {
        let clipboard = SheetClipboard(range: range("A1:A2"), cells: cells(["A1": "x"]),
                                       isCut: false)

        let changes = clipboard.changes(at: CellAddress("B1")!, into: range("B1"),
                                        existing: cells(["B2": "old"]))

        XCTAssertTrue(changes.keys.contains("B2"))
        XCTAssertNil(changes["B2"] ?? nil)
    }

    /// A merge belongs to the grid it is drawn on, not to the values arriving over it.
    func testPastingOverAMergeKeepsTheDestinationsSpans() {
        var existing = cells([:])
        existing["B2"] = SavedCell(id: "B2", raw: "old", value: "old", colSpan: 2, rowSpan: 2)
        let clipboard = SheetClipboard(range: range("A1"), cells: cells(["A1": "new"]),
                                       isCut: false)

        let changes = clipboard.changes(at: CellAddress("B2")!, into: range("B2"),
                                        existing: existing)

        XCTAssertEqual(changes["B2"]??.value, "new")
        XCTAssertEqual(changes["B2"]??.colSpan, 2)
        XCTAssertEqual(changes["B2"]??.rowSpan, 2)
    }

    // MARK: - Plain text

    func testTheBlockIsAlsoWrittenAsTabSeparatedText() {
        let clipboard = SheetClipboard(range: range("A1:B2"),
                                       cells: cells(["A1": "1", "B1": "2", "A2": "3"]),
                                       isCut: false)

        XCTAssertEqual(clipboard.tabSeparatedText, "1\t2\n3\t")
    }

    func testTabSeparatedTextFromAnotherAppBecomesABlock() {
        let clipboard = SheetClipboard.fromTabSeparated("1\t2\n3\t4\n")

        XCTAssertEqual(clipboard?.rows, 2)
        XCTAssertEqual(clipboard?.columns, 2)
        let changes = clipboard?.changes(at: CellAddress("A1")!, into: range("A1"), existing: [:])
        XCTAssertEqual(changes?["B2"]??.value, "4")
    }

    /// Text from another app arrives verbatim, `=` and all — but no display value is invented for
    /// it. There is no evaluator here, so the cell shows its own text and the web computes it on
    /// open; a made-up value would be a wrong number in a shared file.
    func testAFormulaLookingStringFromAnotherAppKeepsItsTextAndNoValue() {
        let clipboard = SheetClipboard.fromTabSeparated("=SUM(A1:A9)")
        let changes = clipboard?.changes(at: CellAddress("C3")!, into: range("C3"), existing: [:])

        XCTAssertEqual(changes?["C3"]??.raw, "=SUM(A1:A9)")
        XCTAssertNil(changes?["C3"]??.value)
    }

    // MARK: - Round trip

    /// The payload crosses the pasteboard as JSON and may outlive the process that wrote it, so it
    /// has to decode into exactly what went in.
    func testThePayloadSurvivesAJSONRoundTrip() throws {
        var source = cells(["A1": "1"])
        source["A1"]?.cellStyle = CellStyle(fontWeight: "bold")
        let clipboard = SheetClipboard(range: range("A1:B1"), cells: source, isCut: true)

        let data = try JSONEncoder().encode(clipboard)
        let decoded = try JSONDecoder().decode(SheetClipboard.self, from: data)

        XCTAssertEqual(decoded, clipboard)
        XCTAssertTrue(decoded.isCut)
    }
}
