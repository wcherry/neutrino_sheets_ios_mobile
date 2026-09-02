import XCTest
@testable import NeutrinoSheets

/// Epic 10 — sorting: the comparison rules, and the thing a sort must never do, which is move one
/// column out of step with the row it belongs to.
final class SortEngineTests: XCTestCase {

    // MARK: - Helpers

    private func sheet(_ rows: [[String]]) -> [String: SavedCell] {
        var cells: [String: SavedCell] = [:]
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, value) in row.enumerated() where !value.isEmpty {
                let id = CellAddress(column: columnIndex + 1, row: rowIndex + 1).id
                cells[id] = SavedCell(id: id, raw: value, value: value)
            }
        }
        return cells
    }

    private func apply(_ changes: CellChanges, to cells: [String: SavedCell]) -> [String: SavedCell] {
        var result = cells
        for (id, cell) in changes {
            if let cell { result[id] = cell } else { result.removeValue(forKey: id) }
        }
        return result
    }

    private func column(_ letter: String, of cells: [String: SavedCell], rows: Int) -> [String] {
        (1...rows).map { cells["\(letter)\($0)"]?.value ?? "" }
    }

    // MARK: - Comparing

    func testNumbersSortNumericallyRatherThanAsText() {
        XCTAssertEqual(SortEngine.compare("9", "10", ascending: true), .orderedAscending)
        XCTAssertEqual(SortEngine.compare("10", "9", ascending: true), .orderedDescending)
    }

    func testTextSortsCaseInsensitively() {
        XCTAssertEqual(SortEngine.compare("apple", "Banana", ascending: true), .orderedAscending)
        XCTAssertEqual(SortEngine.compare("Apple", "apple", ascending: true), .orderedSame)
    }

    func testALeadingNumberIsWhatCounts() {
        // `parseFloat` semantics, matching the browser: "12kg" is 12 to both clients, so a column
        // of measurements sorts the same in each.
        XCTAssertEqual(SortEngine.compare("12kg", "9kg", ascending: true), .orderedDescending)
    }

    func testBlanksSortLastInBothDirections() {
        XCTAssertEqual(SortEngine.compare("", "a", ascending: true), .orderedDescending)
        XCTAssertEqual(SortEngine.compare("", "a", ascending: false), .orderedDescending)
    }

    // MARK: - Sorting

    func testSortingByAColumnCarriesTheWholeRow() {
        let cells = sheet([
            ["Name", "Score"],
            ["Chris", "30"],
            ["Ada", "10"],
            ["Bo", "20"],
        ])
        let range = CellRange(CellAddress("A2")!, CellAddress("B4")!)
        guard case .success(let changes) = SortEngine.sortRows(in: range, by: 1, ascending: true,
                                                               cells: cells) else {
            return XCTFail("sort was refused")
        }
        let sorted = apply(changes, to: cells)

        XCTAssertEqual(column("A", of: sorted, rows: 4), ["Name", "Ada", "Bo", "Chris"])
        // The scores moved with their names. This is the whole assertion of the epic's sort: a
        // score left behind is a wrong number in a shared file.
        XCTAssertEqual(column("B", of: sorted, rows: 4), ["Score", "10", "20", "30"])
    }

    func testSortingDescendingReversesIt() {
        let cells = sheet([["3"], ["1"], ["2"]])
        let range = CellRange(CellAddress("A1")!, CellAddress("A3")!)
        guard case .success(let changes) = SortEngine.sortRows(in: range, by: 1, ascending: false,
                                                               cells: cells) else {
            return XCTFail("sort was refused")
        }
        XCTAssertEqual(column("A", of: apply(changes, to: cells), rows: 3), ["3", "2", "1"])
    }

    func testARowThatIsEmptyInAColumnDoesNotLeaveTheOldValueBehind() {
        let cells = sheet([
            ["b", "x"],
            ["a", ""],
        ])
        let range = CellRange(CellAddress("A1")!, CellAddress("B2")!)
        guard case .success(let changes) = SortEngine.sortRows(in: range, by: 1, ascending: true,
                                                               cells: cells) else {
            return XCTFail("sort was refused")
        }
        let sorted = apply(changes, to: cells)

        XCTAssertEqual(sorted["A1"]?.value, "a")
        // "x" belonged to the row that moved down, so B1 has to be emptied rather than left holding
        // a value that is now beside the wrong name.
        XCTAssertNil(sorted["B1"])
        XCTAssertEqual(sorted["B2"]?.value, "x")
    }

    func testACellCarriesItsStyleAndItsNewId() {
        var cells = sheet([["b"], ["a"]])
        cells["A1"]?.cellStyle = CellStyle(fontWeight: "bold")
        let range = CellRange(CellAddress("A1")!, CellAddress("A2")!)
        guard case .success(let changes) = SortEngine.sortRows(in: range, by: 1, ascending: true,
                                                               cells: cells) else {
            return XCTFail("sort was refused")
        }
        let sorted = apply(changes, to: cells)

        XCTAssertEqual(sorted["A2"]?.value, "b")
        XCTAssertEqual(sorted["A2"]?.cellStyle?.fontWeight, "bold")
        XCTAssertEqual(sorted["A2"]?.id, "A2")
    }

    func testRowsSharingAKeyKeepTheOrderTheyWereIn() {
        let cells = sheet([
            ["a", "first"],
            ["a", "second"],
            ["a", "third"],
        ])
        let range = CellRange(CellAddress("A1")!, CellAddress("B3")!)
        guard case .success(let changes) = SortEngine.sortRows(in: range, by: 1, ascending: true,
                                                               cells: cells) else {
            return XCTFail("sort was refused")
        }
        XCTAssertEqual(column("B", of: apply(changes, to: cells), rows: 3),
                       ["first", "second", "third"])
    }

    func testSortingAnAlreadySortedRangeChangesNothing() {
        let cells = sheet([["a"], ["b"]])
        let range = CellRange(CellAddress("A1")!, CellAddress("A2")!)
        guard case .success(let changes) = SortEngine.sortRows(in: range, by: 1, ascending: true,
                                                               cells: cells) else {
            return XCTFail("sort was refused")
        }
        // No edit, so no undo entry and no save.
        XCTAssertTrue(changes.isEmpty)
    }

    // MARK: - Refusals

    func testSortingIsRefusedWhenTheRangeHoldsAMerge() {
        var cells = sheet([["b"], ["a"]])
        cells["A1"]?.rowSpan = 2
        let range = CellRange(CellAddress("A1")!, CellAddress("A2")!)

        guard case .failure(let reason) = SortEngine.sortRows(in: range, by: 1, ascending: true,
                                                              cells: cells) else {
            return XCTFail("a merged range must not be sorted")
        }
        XCTAssertEqual(reason, .containsMergedCells)
    }

    func testASingleRowHasNothingToSort() {
        let cells = sheet([["a"]])
        let range = CellRange(CellAddress("A1")!, CellAddress("A1")!)
        guard case .failure(let reason) = SortEngine.sortRows(in: range, by: 1, ascending: true,
                                                              cells: cells) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(reason, .nothingToSort)
    }
}
