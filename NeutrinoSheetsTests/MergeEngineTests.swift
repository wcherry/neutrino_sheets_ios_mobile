import XCTest
@testable import NeutrinoSheets

/// Epic 9 — "Merge / unmerge". The rules are the web app's `mergeCells`, and the format is shared,
/// so a merge written here has to be one the browser reads as a merge.
final class MergeEngineTests: XCTestCase {

    // MARK: - Helpers

    private func address(_ id: String) -> CellAddress {
        CellAddress(id)!
    }

    private func range(_ start: String, _ end: String) -> CellRange {
        CellRange(address(start), address(end))
    }

    private func apply(_ changes: CellChanges, to cells: [String: SavedCell]) -> [String: SavedCell] {
        var result = cells
        for (id, cell) in changes {
            if let cell { result[id] = cell } else { result.removeValue(forKey: id) }
        }
        return result
    }

    // MARK: - Merging

    func testMergeAnchorsTheBlockAtItsTopLeft() {
        let cells = ["B2": SavedCell(id: "B2", raw: "Total", value: "Total")]

        let merged = apply(MergeEngine.merge(range("B2", "C3"), cells: cells), to: cells)

        XCTAssertEqual(merged["B2"]?.colSpan, 2)
        XCTAssertEqual(merged["B2"]?.rowSpan, 2)
        XCTAssertNil(merged["B2"]?.mergeAnchor)
        for covered in ["C2", "B3", "C3"] {
            XCTAssertEqual(merged[covered]?.mergeAnchor, "B2", "\(covered) should point at the anchor")
            XCTAssertNil(merged[covered]?.colSpan)
        }
    }

    /// The web app keeps a covered cell's value rather than discarding it, which is what makes an
    /// unmerge lossless. Excel does the opposite; the format is the contract, not Excel.
    func testMergeKeepsTheValuesOfCoveredCells() {
        let cells = [
            "A1": SavedCell(id: "A1", raw: "Left", value: "Left"),
            "B1": SavedCell(id: "B1", raw: "Right", value: "Right"),
        ]

        let merged = apply(MergeEngine.merge(range("A1", "B1"), cells: cells), to: cells)

        XCTAssertEqual(merged["B1"]?.value, "Right")
        XCTAssertEqual(merged["B1"]?.mergeAnchor, "A1")
    }

    func testMergingASingleCellChangesNothing() {
        XCTAssertTrue(MergeEngine.merge(range("A1", "A1"), cells: [:]).isEmpty)
    }

    /// A merge drawn over an existing one has to take its cells away, or the old anchor goes on
    /// claiming a span the new merge now owns and the grid draws two overlapping blocks.
    func testMergingOverAnExistingMergeAbsorbsIt() {
        var cells: [String: SavedCell] = [:]
        cells = apply(MergeEngine.merge(range("B2", "C2"), cells: cells), to: cells)

        let merged = apply(MergeEngine.merge(range("A1", "C3"), cells: cells), to: cells)

        XCTAssertEqual(merged["A1"]?.colSpan, 3)
        XCTAssertEqual(merged["A1"]?.rowSpan, 3)
        XCTAssertNil(merged["B2"]?.colSpan)
        XCTAssertEqual(merged["B2"]?.mergeAnchor, "A1")
    }

    // MARK: - Origins

    func testMergeOriginReportsTheBlockOnlyForTheAnchor() {
        var cells: [String: SavedCell] = [:]
        cells = apply(MergeEngine.merge(range("B2", "D3"), cells: cells), to: cells)

        XCTAssertEqual(MergeEngine.mergeOrigin(at: address("B2"), cells: cells),
                       range("B2", "D3"))
        // A covered cell is not an origin: it is where the *tap* lands, but the grid resolves that
        // to the anchor before anything asks this.
        XCTAssertNil(MergeEngine.mergeOrigin(at: address("C2"), cells: cells))
        XCTAssertNil(MergeEngine.mergeOrigin(at: address("Z9"), cells: cells))
    }

    // MARK: - Unmerging

    func testUnmergeRestoresEveryCoveredCell() {
        var cells = ["A1": SavedCell(id: "A1", raw: "Head", value: "Head"),
                     "B1": SavedCell(id: "B1", raw: "Kept", value: "Kept")]
        cells = apply(MergeEngine.merge(range("A1", "B1"), cells: cells), to: cells)

        let split = apply(MergeEngine.unmerge(range("A1", "B1"), cells: cells), to: cells)

        XCTAssertNil(split["A1"]?.colSpan)
        XCTAssertNil(split["A1"]?.rowSpan)
        XCTAssertEqual(split["A1"]?.value, "Head")
        XCTAssertNil(split["B1"]?.mergeAnchor)
        XCTAssertEqual(split["B1"]?.value, "Kept")
    }

    /// A covered cell that held nothing goes back to not existing, rather than being stored as an
    /// id and nothing else — which is what the web app's serialiser drops anyway.
    func testUnmergeRemovesCellsThatHeldNothingOfTheirOwn() {
        var cells = ["A1": SavedCell(id: "A1", raw: "Head", value: "Head")]
        cells = apply(MergeEngine.merge(range("A1", "B2"), cells: cells), to: cells)
        XCTAssertNotNil(cells["B2"])

        let split = apply(MergeEngine.unmerge(range("A1", "B2"), cells: cells), to: cells)

        XCTAssertNil(split["B2"])
        XCTAssertNil(split["A1"]?.colSpan)
    }

    func testMergeThenUnmergeIsLossless() {
        let original = [
            "A1": SavedCell(id: "A1", raw: "1", value: "1"),
            "B1": SavedCell(id: "B1", raw: "2", value: "2"),
            "A2": SavedCell(id: "A2", raw: "3", value: "3"),
            "B2": SavedCell(id: "B2", raw: "4", value: "4"),
        ]

        let merged = apply(MergeEngine.merge(range("A1", "B2"), cells: original), to: original)
        let split = apply(MergeEngine.unmerge(range("A1", "B2"), cells: merged), to: merged)

        XCTAssertEqual(split, original)
    }
}
