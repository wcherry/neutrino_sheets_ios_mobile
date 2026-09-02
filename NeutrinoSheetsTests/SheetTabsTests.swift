import XCTest
@testable import NeutrinoSheets

/// Epic 10 — the tab list on its own: naming, ordering, and where the active tab ends up.
final class SheetTabsTests: XCTestCase {

    private func sheets(_ names: [String]) -> [SheetData] {
        names.map { SheetData(name: $0) }
    }

    // MARK: - Naming

    func testANewTabTakesTheFirstUnusedNumber() {
        // The web app writes `Sheet ${count + 1}`, which repeats a name as soon as a tab has been
        // deleted. Names are what cross-sheet formulas will address in Epic 15.
        let outcome = SheetTabs.add(to: sheets(["Sheet 1", "Sheet 3"]))
        XCTAssertEqual(outcome.sheets.map(\.name), ["Sheet 1", "Sheet 3", "Sheet 4"])
        XCTAssertEqual(outcome.activeIndex, 2)
    }

    func testACopyIsNamedAfterItsSource() {
        let outcome = SheetTabs.duplicate(sheets(["Budget", "Notes"]), at: 0)
        XCTAssertEqual(outcome.sheets.map(\.name), ["Budget", "Budget (copy)", "Notes"])
    }

    func testASecondCopyIsNumberedRatherThanRepeated() {
        let outcome = SheetTabs.duplicate(sheets(["Budget", "Budget (copy)"]), at: 0)
        XCTAssertEqual(outcome.sheets[1].name, "Budget (copy) 2")
    }

    // MARK: - Renaming

    func testRenamingTrimsWhitespace() {
        let renamed = SheetTabs.rename(sheets(["Sheet 1"]), at: 0, to: "  Summary ")
        XCTAssertEqual(renamed.first?.name, "Summary")
    }

    func testABlankNameIsRefused() {
        let renamed = SheetTabs.rename(sheets(["Sheet 1"]), at: 0, to: "   ")
        XCTAssertEqual(renamed.first?.name, "Sheet 1")
    }

    // MARK: - Duplicating

    func testACopyCarriesTheCellsAndTheColour() {
        var source = SheetData(name: "Budget", cells: ["A1": SavedCell(id: "A1", raw: "x", value: "x")])
        source.color = "#ef4444"

        let outcome = SheetTabs.duplicate([source], at: 0)

        XCTAssertEqual(outcome.sheets[1].cells["A1"]?.value, "x")
        XCTAssertEqual(outcome.sheets[1].color, "#ef4444")
        XCTAssertEqual(outcome.activeIndex, 1)
    }

    // MARK: - Deleting

    func testDeletingTheActiveTabLandsOnTheOneBeforeIt() {
        let outcome = SheetTabs.delete(sheets(["A", "B", "C"]), at: 1, activeIndex: 1)
        XCTAssertEqual(outcome?.sheets.map(\.name), ["A", "C"])
        XCTAssertEqual(outcome?.activeIndex, 0)
    }

    func testDeletingTheFirstTabLandsOnTheNewFirstOne() {
        let outcome = SheetTabs.delete(sheets(["A", "B"]), at: 0, activeIndex: 0)
        XCTAssertEqual(outcome?.activeIndex, 0)
        XCTAssertEqual(outcome?.sheets.map(\.name), ["B"])
    }

    func testDeletingATabBeforeTheActiveOneKeepsYouWhereYouWere() {
        let outcome = SheetTabs.delete(sheets(["A", "B", "C"]), at: 0, activeIndex: 2)
        XCTAssertEqual(outcome?.activeIndex, 1)
        XCTAssertEqual(outcome?.sheets[1].name, "C")
    }

    func testTheLastTabIsRefused() {
        XCTAssertNil(SheetTabs.delete(sheets(["Only"]), at: 0, activeIndex: 0))
    }

    // MARK: - Moving

    func testMovingSwapsWithTheNeighbour() {
        let outcome = SheetTabs.move(sheets(["A", "B", "C"]), from: 1, by: 1, activeIndex: 1)
        XCTAssertEqual(outcome?.sheets.map(\.name), ["A", "C", "B"])
        XCTAssertEqual(outcome?.activeIndex, 2)
    }

    func testMovingATabTheUserIsNotOnRenumbersTheActiveOne() {
        let outcome = SheetTabs.move(sheets(["A", "B"]), from: 0, by: 1, activeIndex: 1)
        XCTAssertEqual(outcome?.activeIndex, 0)
    }

    func testMovingPastTheEndIsRefused() {
        XCTAssertNil(SheetTabs.move(sheets(["A", "B"]), from: 1, by: 1, activeIndex: 0))
        XCTAssertNil(SheetTabs.move(sheets(["A", "B"]), from: 0, by: -1, activeIndex: 0))
    }
}

// MARK: - ColumnFiltersTests

/// Epic 10 — per-column filters.
final class ColumnFiltersTests: XCTestCase {

    private func cells(_ column: String, _ values: [String]) -> [String: SavedCell] {
        var result: [String: SavedCell] = [:]
        for (index, value) in values.enumerated() where !value.isEmpty {
            let id = "\(column)\(index + 1)"
            result[id] = SavedCell(id: id, raw: value, value: value)
        }
        return result
    }

    func testARowIsHiddenWhenItsValueIsNotAllowed() {
        var filters = ColumnFilters()
        filters.set(["a"], forColumn: 1)
        XCTAssertEqual(filters.hiddenRows(in: cells("A", ["a", "b", "a"]), rows: 3), [2])
    }

    func testABlankCellIsFilteredAsTheEmptyString() {
        var filters = ColumnFilters()
        filters.set([""], forColumn: 1)
        // Row 2 holds nothing, so it is the one row that survives a filter on blanks.
        XCTAssertEqual(filters.hiddenRows(in: cells("A", ["a", "", "b"]), rows: 3), [1, 3])
    }

    func testFiltersOnTwoColumnsBothHaveToPass() {
        var filters = ColumnFilters()
        var sheet = cells("A", ["keep", "keep"])
        sheet.merge(cells("B", ["yes", "no"])) { current, _ in current }
        filters.set(["keep"], forColumn: 1)
        filters.set(["yes"], forColumn: 2)

        XCTAssertEqual(filters.hiddenRows(in: sheet, rows: 2), [2])
    }

    func testNoFilterHidesNothing() {
        XCTAssertTrue(ColumnFilters().hiddenRows(in: cells("A", ["a"]), rows: 1).isEmpty)
    }

    func testClearingAColumnUnfiltersIt() {
        var filters = ColumnFilters()
        filters.set(["a"], forColumn: 1)
        filters.set(nil, forColumn: 1)
        XCTAssertFalse(filters.isFiltered(column: 1))
        XCTAssertTrue(filters.isEmpty)
    }

    func testTheValueListIsSortedWithBlanksLast() {
        let values = ColumnFilters.values(inColumn: 1, cells: cells("A", ["10", "9", "b", ""]),
                                          rows: 4)
        XCTAssertEqual(values, ["9", "10", "b", ""])
    }
}
