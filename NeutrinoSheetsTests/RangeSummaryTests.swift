import XCTest
@testable import NeutrinoSheets

/// Epic 8 — the live sum / count / average under a range selection.
final class RangeSummaryTests: XCTestCase {

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

    func testNumbersAreSummedCountedAndAveraged() {
        let summary = RangeSummary(range: range("A1:A3"),
                                   cells: cells(["A1": "1", "A2": "2", "A3": "6"]))

        XCTAssertEqual(summary.sum, 9)
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.numericCount, 3)
        XCTAssertEqual(summary.average, 3)
    }

    /// Text is counted but not averaged. Dividing the sum by *every* selected cell would report a
    /// mean that is wrong by however many labels are in the block — which is exactly the mistake a
    /// user is using this readout to avoid.
    func testTextCountsButDoesNotDragTheAverageDown() {
        let summary = RangeSummary(range: range("A1:A3"),
                                   cells: cells(["A1": "10", "A2": "20", "A3": "Total"]))

        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.numericCount, 2)
        XCTAssertEqual(summary.average, 15)
    }

    func testEmptyCellsAreNotCounted() {
        let summary = RangeSummary(range: range("A1:C3"), cells: cells(["A1": "5"]))

        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.sum, 5)
    }

    func testASelectionOfNothingHasNoSummary() {
        XCTAssertTrue(RangeSummary(range: range("A1:C3"), cells: [:]).isEmpty)
    }

    /// A merged block's value is drawn once, by its anchor. Counting the covered cells too would
    /// double every merged entry in the selection.
    func testMergedAwayCellsAreNotCountedTwice() {
        var cells = self.cells(["A1": "4"])
        cells["A1"]?.colSpan = 2
        cells["B1"] = SavedCell(id: "B1", raw: "4", value: "4", mergeAnchor: "A1")

        let summary = RangeSummary(range: range("A1:B1"), cells: cells)

        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.sum, 4)
    }

    func testTextWithoutNumbersReportsOnlyACount() {
        let summary = RangeSummary(range: range("A1:A2"), cells: cells(["A1": "x", "A2": "y"]))

        XCTAssertNil(summary.average)
        XCTAssertEqual(summary.statusText, "Count 2")
    }

    func testTheStatusLineIsGroupedAndRounded() {
        let summary = RangeSummary(range: range("A1:A2"),
                                   cells: cells(["A1": "1000", "A2": "234.5"]))

        XCTAssertEqual(summary.statusText, "Sum 1,234.50  \u{00B7}  Avg 617.25  \u{00B7}  Count 2")
    }
}
