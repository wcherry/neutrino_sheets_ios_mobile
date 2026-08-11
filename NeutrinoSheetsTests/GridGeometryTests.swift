import XCTest
@testable import NeutrinoSheets

/// The grid's coordinate maths. Epic 6's performance target rests on `visibleRange` being right:
/// a range that is too small drops cells off the screen, and one that is too large quietly undoes
/// the virtualisation.
final class GridGeometryTests: XCTestCase {

    private let metrics = GridMetrics(defaultColumnWidth: 100, defaultRowHeight: 28,
                                      rowHeaderWidth: 50, columnHeaderHeight: 26, zoom: 1)

    private func sheet(colWidths: [String: Double]? = nil,
                       rowHeights: [String: Double]? = nil,
                       cells: [String: SavedCell] = [:]) -> SheetData {
        SheetData(name: "Sheet1", cells: cells, colWidths: colWidths, rowHeights: rowHeights)
    }

    // MARK: - Default geometry

    func testUniformColumnsAndRows() {
        let geometry = GridGeometry(sheet: sheet(), metrics: metrics)

        XCTAssertEqual(geometry.x(ofColumn: 1), 0)
        XCTAssertEqual(geometry.x(ofColumn: 2), 100)
        XCTAssertEqual(geometry.x(ofColumn: 5), 400)
        XCTAssertEqual(geometry.y(ofRow: 1), 0)
        XCTAssertEqual(geometry.y(ofRow: 3), 56)
        XCTAssertEqual(geometry.width(ofColumn: 1), 100)
        XCTAssertEqual(geometry.height(ofRow: 1), 28)
    }

    // MARK: - Overrides

    /// `colWidths` is keyed by **0-based** index while addresses are 1-based. Confusing the two
    /// would shift every override one column over, which looks like a rendering bug rather than a
    /// units bug.
    func testPerColumnWidthsAreZeroBased() {
        let geometry = GridGeometry(sheet: sheet(colWidths: ["0": 200, "2": 50]), metrics: metrics)

        XCTAssertEqual(geometry.width(ofColumn: 1), 200)   // key "0" -> column A
        XCTAssertEqual(geometry.width(ofColumn: 2), 100)   // no override
        XCTAssertEqual(geometry.width(ofColumn: 3), 50)    // key "2" -> column C

        // Offsets accumulate the overrides.
        XCTAssertEqual(geometry.x(ofColumn: 2), 200)
        XCTAssertEqual(geometry.x(ofColumn: 3), 300)
        XCTAssertEqual(geometry.x(ofColumn: 4), 350)
    }

    func testPerRowHeightsAreZeroBased() {
        let geometry = GridGeometry(sheet: sheet(rowHeights: ["0": 60]), metrics: metrics)

        XCTAssertEqual(geometry.height(ofRow: 1), 60)
        XCTAssertEqual(geometry.y(ofRow: 2), 60)
        XCTAssertEqual(geometry.y(ofRow: 3), 88)
    }

    func testZoomScalesOverridesAsWellAsDefaults() {
        var zoomed = metrics
        zoomed.zoom = 2
        // Unscaled metrics: the geometry applies zoom itself, precisely so a stored width is
        // scaled along with the defaults rather than being left behind at its unzoomed size.
        let geometry = GridGeometry(sheet: sheet(colWidths: ["0": 200]), metrics: zoomed)

        XCTAssertEqual(geometry.width(ofColumn: 1), 400)
        XCTAssertEqual(geometry.width(ofColumn: 2), 200)
    }

    // MARK: - Hit testing

    func testAddressAtPoint() {
        let geometry = GridGeometry(sheet: sheet(colWidths: ["0": 200]), metrics: metrics)

        XCTAssertEqual(geometry.address(at: CGPoint(x: 0, y: 0)), CellAddress(column: 1, row: 1))
        XCTAssertEqual(geometry.address(at: CGPoint(x: 199, y: 27)), CellAddress(column: 1, row: 1))
        // The boundary belongs to the *next* cell, which is what makes a drag across a border
        // land where the finger is.
        XCTAssertEqual(geometry.address(at: CGPoint(x: 200, y: 28)), CellAddress(column: 2, row: 2))
        XCTAssertEqual(geometry.address(at: CGPoint(x: 305, y: 0)), CellAddress(column: 3, row: 1))
    }

    func testNegativePointsClampToTheFirstCell() {
        let geometry = GridGeometry(sheet: sheet(), metrics: metrics)
        XCTAssertEqual(geometry.address(at: CGPoint(x: -10, y: -10)), CellAddress(column: 1, row: 1))
    }

    /// Past the table's extent every column is the default width, and the arithmetic has to keep
    /// working — a user can scroll a long way into empty grid.
    func testHitTestingBeyondTheExtent() {
        let geometry = GridGeometry(sheet: sheet(), metrics: metrics,
                                    minimumExtent: (columns: 5, rows: 5))
        // The table covers 5 columns (0…500pt); 650pt is two columns past its end.
        XCTAssertEqual(geometry.column(atX: 650), 7)
        XCTAssertEqual(geometry.x(ofColumn: 7), 600)
    }

    // MARK: - Visible range (the virtualisation)

    func testVisibleRangeCoversExactlyTheRectangle() {
        let geometry = GridGeometry(sheet: sheet(), metrics: metrics)
        let visible = geometry.visibleRange(
            in: CGRect(x: 250, y: 50, width: 300, height: 100)
        )

        // x 250…550 spans columns 3…6; y 50…150 spans rows 2…6.
        XCTAssertEqual(visible.columns, 3...6)
        XCTAssertEqual(visible.rows, 2...6)
    }

    func testVisibleRangeIsBoundedByTheViewportNotTheWorkbook() {
        // A sheet with a cell 10,000 rows down must not make a screenful of work any bigger.
        let far = ["A10000": SavedCell(id: "A10000", value: "x")]
        let geometry = GridGeometry(sheet: sheet(cells: far), metrics: metrics)

        let visible = geometry.visibleRange(in: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertEqual(visible.columns.count, 5)
        XCTAssertLessThanOrEqual(visible.rows.count, 30)
    }

    // MARK: - Content size

    func testContentSizeCoversTheUsedAreaPlusHeadroom() {
        let cells = ["A1": SavedCell(id: "A1", value: "x"),
                     "C4": SavedCell(id: "C4", value: "y")]
        let geometry = GridGeometry(sheet: sheet(cells: cells), metrics: metrics,
                                    minimumExtent: (columns: 5, rows: 5))

        // Used bounds are 3 × 4, padded to at least the minimum extent — so the user can scroll
        // into blank space rather than hitting a wall at the last populated cell.
        XCTAssertGreaterThanOrEqual(geometry.extent.columns, 5)
        XCTAssertGreaterThanOrEqual(geometry.extent.rows, 5)
        XCTAssertEqual(geometry.contentSize.width,
                       Double(geometry.extent.columns) * 100)
    }

    func testEmptySheetStillHasAScrollableGrid() {
        let geometry = GridGeometry(sheet: nil, metrics: metrics)
        XCTAssertGreaterThan(geometry.contentSize.width, 0)
        XCTAssertGreaterThan(geometry.contentSize.height, 0)
    }

    // MARK: - Merges

    func testMergedCellRectSpansItsBlock() {
        let geometry = GridGeometry(sheet: sheet(), metrics: metrics)
        let rect = geometry.rect(for: CellAddress(column: 1, row: 1), colSpan: 2, rowSpan: 3)

        XCTAssertEqual(rect.origin, .zero)
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.height, 84)
    }

    func testSingleCellRect() {
        let geometry = GridGeometry(sheet: sheet(), metrics: metrics)
        let rect = geometry.rect(for: CellAddress(column: 2, row: 2))

        XCTAssertEqual(rect, CGRect(x: 100, y: 28, width: 100, height: 28))
    }
}
