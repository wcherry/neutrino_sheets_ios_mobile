import XCTest
@testable import NeutrinoSheets

/// Epic 9 — the table-style gallery and the regions it records.
///
/// The ids are asserted as literals rather than derived, because a `TableStyle.id` is written into
/// every workbook that has a table in it. A generated id that drifted from the web app's would not
/// fail here or there — the browser would simply stop recognising a range as a table.
final class TableStylesTests: XCTestCase {

    // MARK: - The gallery

    func testTheGalleryIsFourteenHuesByTwoLayoutsByThreeBorders() {
        XCTAssertEqual(TableStyles.all.count, 14 * 2 * 3 + 1)
        XCTAssertEqual(TableStyles.all.filter { $0.regular != nil }.count, 84)
        XCTAssertEqual(TableStyles.all.last?.id, "blank")
    }

    func testTheUniformBorderVariantKeepsTheIdsAlreadyInSavedWorkbooks() {
        // No suffix, deliberately: `blue-banded` is spelled this way inside files the web app has
        // already written.
        let blue = TableStyles.style(withID: "blue-banded")
        XCTAssertEqual(blue?.name, "Blue Banded")
        XCTAssertEqual(blue?.regular?.headerBackground, "#1e40af")
        XCTAssertEqual(blue?.regular?.bandColorB, "#dbeafe")
        XCTAssertEqual(blue?.regular?.border.borderStyle, .set("thin"))
    }

    func testTheSuffixedBorderVariantsExistUnderTheirOwnIds() {
        XCTAssertEqual(TableStyles.style(withID: "slate-header-totals-no-border")?.name,
                       "Slate Header & Totals \u{2014} No Border")
        XCTAssertEqual(TableStyles.style(withID: "rose-banded-horizontal")?.name,
                       "Rose Banded \u{2014} Horizontal Lines")
    }

    func testEveryStyleIdIsUnique() {
        XCTAssertEqual(Set(TableStyles.all.map(\.id)).count, TableStyles.all.count)
    }

    // MARK: - Patches

    private func range(_ start: String, _ end: String) -> CellRange {
        CellRange(CellAddress(start)!, CellAddress(end)!)
    }

    func testABandedStyleColoursTheHeaderAndAlternatesTheBody() throws {
        let style = try XCTUnwrap(TableStyles.style(withID: "blue-banded")?.regular)

        let patches = TableStyles.patches(for: style, in: range("A1", "B4"))

        XCTAssertEqual(patches.count, 8)
        XCTAssertEqual(patches["A1"]?.backgroundColor, .set("#1e40af"))
        XCTAssertEqual(patches["A1"]?.color, .set("#ffffff"))
        XCTAssertEqual(patches["A1"]?.fontWeight, .set("bold"))
        // Banding is counted from the first body row, so row 2 is band A and row 3 is band B.
        XCTAssertEqual(patches["A2"]?.backgroundColor, .set("#ffffff"))
        XCTAssertEqual(patches["A3"]?.backgroundColor, .set("#dbeafe"))
        XCTAssertEqual(patches["A4"]?.backgroundColor, .set("#ffffff"))
        XCTAssertEqual(patches["A2"]?.fontWeight, .set("normal"))
    }

    /// A body cell has to *lose* the header's white text, not merely not gain it — a cell that was
    /// a header a moment ago would otherwise be white on white.
    func testBodyCellsClearTheTextColourRatherThanLeavingIt() throws {
        let style = try XCTUnwrap(TableStyles.style(withID: "blue-banded")?.regular)

        let patches = TableStyles.patches(for: style, in: range("A1", "A3"))

        XCTAssertEqual(patches["A2"]?.color, .clear)

        var wasHeader = CellStyle()
        wasHeader.color = "#ffffff"
        XCTAssertNil(patches["A2"]?.applied(to: wasHeader)?.color)
    }

    func testHeaderColumnAndTotalRowGetTheHeaderLook() throws {
        let style = try XCTUnwrap(TableStyles.style(withID: "green-header-totals")?.regular)
        XCTAssertTrue(style.headerColumn)
        XCTAssertTrue(style.totalRow)

        let patches = TableStyles.patches(for: style, in: range("B2", "D5"))

        XCTAssertEqual(patches["B3"]?.backgroundColor, .set(style.headerBackground), "header column")
        XCTAssertEqual(patches["C5"]?.backgroundColor, .set(style.headerBackground), "total row")
        XCTAssertEqual(patches["C3"]?.backgroundColor, .set(style.bandColorA), "body")
    }

    /// A one-row range has no separate total row — the header would otherwise be overwritten by a
    /// total that is the same cell.
    func testASingleRowRangeHasNoTotalRow() throws {
        let style = try XCTUnwrap(TableStyles.style(withID: "green-header-totals")?.regular)

        let patches = TableStyles.patches(for: style, in: range("A1", "C1"))

        XCTAssertEqual(patches["B1"]?.backgroundColor, .set(style.headerBackground))
        XCTAssertEqual(patches.count, 3)
    }

    func testTheHorizontalBorderVariantWritesTopAndBottomOnly() throws {
        let style = try XCTUnwrap(TableStyles.style(withID: "blue-banded-horizontal")?.regular)

        let patch = try XCTUnwrap(TableStyles.patches(for: style, in: range("A1", "A2"))["A2"])
        let applied = try XCTUnwrap(patch.applied(to: nil))

        XCTAssertEqual(applied.border(.top), "thin")
        XCTAssertEqual(applied.border(.bottom), "thin")
        XCTAssertNil(applied.border(.left))
        XCTAssertNil(applied.border(.right))
    }

    // MARK: - Regions

    func testRegionsOverlapTheWayRectanglesDo() {
        let table = TableRegion(id: "t1", styleId: "blue-banded", minR: 2, maxR: 5, minC: 1, maxC: 3)

        XCTAssertTrue(table.overlaps(range("C5", "E7")))
        XCTAssertFalse(table.overlaps(range("D1", "F9")), "column D is outside A…C")
        XCTAssertFalse(table.overlaps(range("A6", "C9")), "row 6 is below row 5")
    }

    func testRegisteringAStyleReplacesWhateverItOverlaps() {
        let existing = [
            TableRegion(id: "t1", styleId: "blue-banded", minR: 1, maxR: 4, minC: 1, maxC: 2),
            TableRegion(id: "t2", styleId: "rose-banded", minR: 10, maxR: 12, minC: 1, maxC: 2),
        ]
        let replacement = TableRegion(id: "t3", styleId: "green-banded", range: range("A2", "B6"))

        let result = existing.registering(replacement)

        XCTAssertEqual(result.map(\.id), ["t2", "t3"])
    }

    func testRemovingOverlapsLeavesTablesElsewhereAlone() {
        let existing = [
            TableRegion(id: "t1", styleId: "blue-banded", minR: 1, maxR: 4, minC: 1, maxC: 2),
            TableRegion(id: "t2", styleId: "rose-banded", minR: 10, maxR: 12, minC: 1, maxC: 2),
        ]

        XCTAssertEqual(existing.removingOverlaps(with: range("A1", "A1")).map(\.id), ["t2"])
        XCTAssertEqual(existing.removingOverlaps(with: range("Z1", "Z9")).map(\.id), ["t1", "t2"])
    }

    func testARegionRoundTripsThroughItsRange() {
        let region = TableRegion(id: "t1", styleId: "blue-banded", range: range("B3", "E9"))

        XCTAssertEqual(region.minC, 2)
        XCTAssertEqual(region.minR, 3)
        XCTAssertEqual(region.maxC, 5)
        XCTAssertEqual(region.maxR, 9)
        XCTAssertEqual(region.range, range("B3", "E9"))
        XCTAssertTrue(region.isValid)
    }
}
