import XCTest
@testable import NeutrinoSheets

/// Epic 10 — the structural shift, asserted against the rules in the web app's
/// `structuralShift.ts`.
///
/// This is the suite that matters most in the epic. A structural edit rewrites the id of nearly
/// every cell in a tab, and every way of getting it slightly wrong is silent: a merge that loses its
/// anchor draws a blank, a conditional format left pointing at the old range colours the wrong
/// cells, a column width that did not move makes one column the wrong size. None of them fail
/// anywhere — they are simply wrong the next time the workbook is opened, on either client.
final class StructuralShiftTests: XCTestCase {

    // MARK: - Helpers

    private func cells(_ entries: [String: SavedCell]) -> [String: SavedCell] { entries }

    private func cell(_ id: String, _ value: String) -> SavedCell {
        SavedCell(id: id, raw: value, value: value)
    }

    // MARK: - Ids

    func testInsertMovesEverythingAtOrAfterTheIndex() {
        XCTAssertEqual(StructuralShift.shiftedID("A3", axis: .row, operation: .insert, index: 3), "A4")
        XCTAssertEqual(StructuralShift.shiftedID("A4", axis: .row, operation: .insert, index: 3), "A5")
        // Before the index, nothing moves.
        XCTAssertEqual(StructuralShift.shiftedID("A2", axis: .row, operation: .insert, index: 3), "A2")
    }

    func testDeleteDropsTheIndexAndPullsTheRestBack() {
        XCTAssertNil(StructuralShift.shiftedID("A3", axis: .row, operation: .delete, index: 3))
        XCTAssertEqual(StructuralShift.shiftedID("A4", axis: .row, operation: .delete, index: 3), "A3")
        XCTAssertEqual(StructuralShift.shiftedID("A2", axis: .row, operation: .delete, index: 3), "A2")
    }

    func testColumnsShiftOnTheirOwnAxis() {
        XCTAssertEqual(StructuralShift.shiftedID("B2", axis: .column, operation: .insert, index: 2), "C2")
        XCTAssertEqual(StructuralShift.shiftedID("B2", axis: .column, operation: .delete, index: 1), "A2")
        // Past Z, so the bijective base-26 conversion is exercised rather than assumed.
        XCTAssertEqual(StructuralShift.shiftedID("Z1", axis: .column, operation: .insert, index: 1), "AA1")
    }

    func testAnUnparseableIdIsKeptRatherThanDropped() {
        // A key a future web release invents is still somebody's data.
        XCTAssertEqual(StructuralShift.shiftedID("meta", axis: .row, operation: .delete, index: 1),
                       "meta")
    }

    // MARK: - Cells

    func testEveryCellBelowAnInsertedRowMovesDown() {
        let shifted = StructuralShift.shift(cells: cells([
            "A1": cell("A1", "top"),
            "A2": cell("A2", "middle"),
            "A3": cell("A3", "bottom"),
        ]), axis: .row, operation: .insert, index: 2)

        XCTAssertEqual(shifted["A1"]?.value, "top")
        XCTAssertNil(shifted["A2"])
        XCTAssertEqual(shifted["A3"]?.value, "middle")
        XCTAssertEqual(shifted["A4"]?.value, "bottom")
    }

    func testAShiftedCellCarriesItsNewId() {
        // `SavedCell.id` is redundant with the key, and the web app rewrites it. A cell whose id
        // disagreed with its key would round-trip a lie into the file.
        let shifted = StructuralShift.shift(cells: cells(["A2": cell("A2", "x")]),
                                            axis: .row, operation: .insert, index: 1)
        XCTAssertEqual(shifted["A3"]?.id, "A3")
    }

    func testDeletingARowRemovesItsCells() {
        let shifted = StructuralShift.shift(cells: cells([
            "A1": cell("A1", "keep"),
            "A2": cell("A2", "gone"),
            "A3": cell("A3", "up"),
        ]), axis: .row, operation: .delete, index: 2)

        XCTAssertEqual(shifted.count, 2)
        XCTAssertEqual(shifted["A1"]?.value, "keep")
        XCTAssertEqual(shifted["A2"]?.value, "up")
    }

    // MARK: - Merges

    func testAMergeGrowsWhenARowIsInsertedInsideIt() {
        var anchor = cell("A1", "merged")
        anchor.rowSpan = 3
        var covered = SavedCell(id: "A2")
        covered.mergeAnchor = "A1"
        var covered3 = SavedCell(id: "A3")
        covered3.mergeAnchor = "A1"

        let shifted = StructuralShift.shift(cells: ["A1": anchor, "A2": covered, "A3": covered3],
                                            axis: .row, operation: .insert, index: 2)

        XCTAssertEqual(shifted["A1"]?.rowSpan, 4)
        // The two cells that were covered moved down and still point at the anchor.
        XCTAssertEqual(shifted["A3"]?.mergeAnchor, "A1")
        XCTAssertEqual(shifted["A4"]?.mergeAnchor, "A1")
        // The inserted row is covered by the grown span without a record of its own, which is what
        // the web app produces as well: a cell nobody has written holds nothing, and the anchor's
        // `rowSpan` is what draws over it. Manufacturing a `{"mergeAnchor":"A1"}` here would put a
        // key in the file the browser never writes.
        XCTAssertNil(shifted["A2"])
    }

    func testAMergeShrinksWhenARowInsideItIsDeleted() {
        var anchor = cell("A1", "merged")
        anchor.rowSpan = 3
        var covered2 = SavedCell(id: "A2")
        covered2.mergeAnchor = "A1"
        var covered3 = SavedCell(id: "A3")
        covered3.mergeAnchor = "A1"

        let shifted = StructuralShift.shift(cells: ["A1": anchor, "A2": covered2, "A3": covered3],
                                            axis: .row, operation: .delete, index: 2)

        XCTAssertEqual(shifted["A1"]?.rowSpan, 2)
        XCTAssertEqual(shifted["A2"]?.mergeAnchor, "A1")
    }

    func testAMergeThatShrinksToOneStopsBeingAMerge() {
        var anchor = cell("A1", "merged")
        anchor.rowSpan = 2
        var covered = SavedCell(id: "A2")
        covered.mergeAnchor = "A1"

        let shifted = StructuralShift.shift(cells: ["A1": anchor, "A2": covered],
                                            axis: .row, operation: .delete, index: 2)

        XCTAssertNil(shifted["A1"]?.rowSpan)
        // And nothing is left claiming to be covered by it — a cell pointing at an anchor that no
        // longer spans it draws nothing and cannot be edited.
        XCTAssertNil(shifted["A2"])
    }

    func testAnEditOutsideAMergeMovesItWholeRatherThanResizingIt() {
        var anchor = cell("A5", "merged")
        anchor.rowSpan = 2
        var covered = SavedCell(id: "A6")
        covered.mergeAnchor = "A5"

        let shifted = StructuralShift.shift(cells: ["A5": anchor, "A6": covered],
                                            axis: .row, operation: .insert, index: 2)

        XCTAssertEqual(shifted["A6"]?.rowSpan, 2)
        XCTAssertEqual(shifted["A7"]?.mergeAnchor, "A6")
    }

    func testAnEditOnAMergesFirstRowMovesItRatherThanResizingIt() {
        // `index == anchorMin` is *not* strictly inside, so the anchor rides along with the generic
        // shift. This is the boundary the web app's `anchorMin < index` picks, and getting it wrong
        // in either direction changes a merge's height by one.
        var anchor = cell("A2", "merged")
        anchor.rowSpan = 2
        var covered = SavedCell(id: "A3")
        covered.mergeAnchor = "A2"

        let shifted = StructuralShift.shift(cells: ["A2": anchor, "A3": covered],
                                            axis: .row, operation: .insert, index: 2)

        XCTAssertEqual(shifted["A3"]?.rowSpan, 2)
        XCTAssertEqual(shifted["A4"]?.mergeAnchor, "A3")
    }

    func testAMergeKeepsItsOtherAxisWhenThisOneCollapses() {
        // A 2×2 merge losing a row is still a 2-wide merge, so its members keep pointing at it.
        var anchor = cell("A1", "merged")
        anchor.rowSpan = 2
        anchor.colSpan = 2
        var b1 = SavedCell(id: "B1"); b1.mergeAnchor = "A1"
        var a2 = SavedCell(id: "A2"); a2.mergeAnchor = "A1"
        var b2 = SavedCell(id: "B2"); b2.mergeAnchor = "A1"

        let shifted = StructuralShift.shift(cells: ["A1": anchor, "B1": b1, "A2": a2, "B2": b2],
                                            axis: .row, operation: .delete, index: 2)

        XCTAssertNil(shifted["A1"]?.rowSpan)
        XCTAssertEqual(shifted["A1"]?.colSpan, 2)
        XCTAssertEqual(shifted["B1"]?.mergeAnchor, "A1")
    }

    func testDeletingTheRowAMergeAnchorSitsOnOrphansNothing() {
        var anchor = cell("A2", "merged")
        anchor.colSpan = 2
        var covered = SavedCell(id: "B2")
        covered.mergeAnchor = "A2"

        let shifted = StructuralShift.shift(cells: ["A2": anchor, "B2": covered],
                                            axis: .row, operation: .delete, index: 2)

        XCTAssertTrue(shifted.isEmpty)
    }

    // MARK: - Ranges

    func testARangeStretchesWhenSomethingIsInsertedInsideIt() {
        let range = CellRange(CellAddress("B2")!, CellAddress("D5")!)
        let shifted = StructuralShift.shift(range: range, axis: .row, operation: .insert, index: 3)
        XCTAssertEqual(shifted?.address, "B2:D6")
    }

    func testARangeMovesWholeWhenSomethingIsInsertedBeforeIt() {
        let range = CellRange(CellAddress("B2")!, CellAddress("D5")!)
        let shifted = StructuralShift.shift(range: range, axis: .row, operation: .insert, index: 1)
        XCTAssertEqual(shifted?.address, "B3:D6")
    }

    func testARangeDisappearsWhenItsLastRowIsDeleted() {
        let range = CellRange(CellAddress("B2")!, CellAddress("D2")!)
        XCTAssertNil(StructuralShift.shift(range: range, axis: .row, operation: .delete, index: 2))
    }

    // MARK: - Sizes

    func testColumnWidthsMoveWithTheirColumns() {
        // The keys are 0-based and the index is 1-based; inserting column B (index 2) moves the
        // entry under key "1" to key "2".
        let shifted = StructuralShift.shift(sizes: ["0": 80, "1": 140, "2": 60],
                                            operation: .insert, index: 2)
        XCTAssertEqual(shifted["0"], 80)
        XCTAssertEqual(shifted["2"], 140)
        XCTAssertEqual(shifted["3"], 60)
        XCTAssertNil(shifted["1"])
    }

    func testADeletedColumnsWidthGoesWithIt() {
        let shifted = StructuralShift.shift(sizes: ["0": 80, "1": 140, "2": 60],
                                            operation: .delete, index: 2)
        XCTAssertEqual(shifted, ["0": 80, "1": 60])
    }

    // MARK: - Conditional formats

    func testConditionalFormatRangesFollowTheCellsTheyDescribe() {
        let rules = JSONValue.array([
            .object(["id": .string("r1"), "range": .string("A2:A9"),
                     "rule": .object(["kind": .string("colorScale")])]),
        ])
        let shifted = StructuralShift.shiftConditionalFormats(rules, axis: .row,
                                                              operation: .insert, index: 1)
        XCTAssertEqual(shifted.arrayValue?.first?.objectValue?["range"]?.stringValue, "A3:A10")
    }

    func testARuleWhoseRangeIsDeletedGoesWithIt() {
        let rules = JSONValue.array([
            .object(["id": .string("r1"), "range": .string("A2")]),
            .object(["id": .string("r2"), "range": .string("B5:B9")]),
        ])
        let shifted = StructuralShift.shiftConditionalFormats(rules, axis: .row,
                                                              operation: .delete, index: 2)
        XCTAssertEqual(shifted.arrayValue?.count, 1)
        XCTAssertEqual(shifted.arrayValue?.first?.objectValue?["id"]?.stringValue, "r2")
    }

    func testARuleThisAppCannotReadIsLeftExactlyAsItArrived() {
        let rules = JSONValue.array([
            .object(["id": .string("r1"), "range": .string("SomeNamedRange"),
                     "future": .bool(true)]),
        ])
        let shifted = StructuralShift.shiftConditionalFormats(rules, axis: .row,
                                                              operation: .insert, index: 1)
        XCTAssertEqual(shifted, rules)
    }

    // MARK: - Whole sheet

    func testInsertingARowMovesCellsHeightsFormatsAndTables() {
        var sheet = SheetData(name: "Q3", cells: [
            "A1": cell("A1", "Header"),
            "A2": cell("A2", "One"),
        ], rowHeights: ["1": 44])
        sheet.tables = [TableRegion(id: "t1", styleId: "blue-banded", minR: 1, maxR: 2,
                                    minC: 1, maxC: 1)]
        sheet.unknownFields["conditionalFormats"] = .array([
            .object(["id": .string("r1"), "range": .string("A2")]),
        ])

        let shifted = StructuralShift.apply(to: sheet, axis: .row, operation: .insert, index: 2)

        XCTAssertEqual(shifted.cells["A3"]?.value, "One")
        XCTAssertEqual(shifted.rowHeights?["2"], 44)
        XCTAssertEqual(shifted.tables?.first?.maxR, 3)
        XCTAssertEqual(shifted.unknownFields["conditionalFormats"]?
            .arrayValue?.first?.objectValue?["range"]?.stringValue, "A3")
    }

    func testAnInsertedRowInsideATableIsBandedRatherThanLeftBlank() {
        // Without the re-banding pass this is the visible failure: a new row in the middle of a
        // styled table that has no fill while every row around it does.
        var sheet = SheetData(name: "Q3", cells: [:])
        sheet.tables = [TableRegion(id: "t1", styleId: "blue-banded", minR: 1, maxR: 4,
                                    minC: 1, maxC: 2)]

        let shifted = StructuralShift.apply(to: sheet, axis: .row, operation: .insert, index: 3)

        XCTAssertEqual(shifted.tables?.first?.maxR, 5)
        XCTAssertNotNil(shifted.cells["A3"]?.cellStyle?.backgroundColor)
        XCTAssertNotNil(shifted.cells["B3"]?.cellStyle?.backgroundColor)
    }

    func testColumnWidthsAreUntouchedByARowEdit() {
        let sheet = SheetData(name: "Q3", cells: [:], colWidths: ["0": 200], rowHeights: ["0": 40])
        let shifted = StructuralShift.apply(to: sheet, axis: .row, operation: .insert, index: 1)
        XCTAssertEqual(shifted.colWidths?["0"], 200)
        XCTAssertEqual(shifted.rowHeights?["1"], 40)
    }

    func testChartsAreCarriedThroughUntouched() {
        // The web app's `computeStructuralShift` does not move charts either. Inventing a rule here
        // would put the two clients in disagreement about where a chart is anchored.
        var sheet = SheetData(name: "Q3", cells: [:])
        sheet.unknownFields["charts"] = .array([.object(["id": .string("c1"),
                                                         "range": .string("A1:B4")])])
        let shifted = StructuralShift.apply(to: sheet, axis: .row, operation: .insert, index: 1)
        XCTAssertEqual(shifted.unknownFields["charts"], sheet.unknownFields["charts"])
    }

    // MARK: - Chained edits

    func testDeletingSeveralRowsDescendingRemovesExactlyThose() {
        let sheet = SheetData(name: "Q3", cells: [
            "A1": cell("A1", "1"), "A2": cell("A2", "2"), "A3": cell("A3", "3"),
            "A4": cell("A4", "4"), "A5": cell("A5", "5"),
        ])
        let shifted = StructuralShift.apply(to: sheet, axis: .row, operation: .delete,
                                            indices: [4, 2])

        XCTAssertEqual(shifted.cells.count, 3)
        XCTAssertEqual(shifted.cells["A1"]?.value, "1")
        XCTAssertEqual(shifted.cells["A2"]?.value, "3")
        XCTAssertEqual(shifted.cells["A3"]?.value, "5")
    }

    func testInsertingSeveralRowsAtOneIndexPutsThemInAsABlock() {
        let sheet = SheetData(name: "Q3", cells: ["A1": cell("A1", "1"), "A2": cell("A2", "2")])
        let shifted = StructuralShift.apply(to: sheet, axis: .row, operation: .insert,
                                            indices: [2, 2, 2])

        XCTAssertEqual(shifted.cells["A1"]?.value, "1")
        XCTAssertEqual(shifted.cells["A5"]?.value, "2")
        XCTAssertNil(shifted.cells["A2"])
    }
}
