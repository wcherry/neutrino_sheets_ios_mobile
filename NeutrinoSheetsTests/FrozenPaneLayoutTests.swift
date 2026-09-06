import XCTest
@testable import NeutrinoSheets

/// Epic 10 — freeze panes.
///
/// The whole feature is a coordinate mapping, and every way of getting it wrong is visual: cells
/// that draw in one place and select in another, a band that scrolls when it should not, a first
/// unfrozen row that slides under the band and cannot be reached. None of that is catchable by
/// reading the code, so the arithmetic lives in its own type and is asserted here.
final class FrozenPaneLayoutTests: XCTestCase {

    private let metrics = GridMetrics(defaultColumnWidth: 100, defaultRowHeight: 28,
                                      rowHeaderWidth: 50, columnHeaderHeight: 26, zoom: 1)

    private let viewport = CGSize(width: 400, height: 300)

    private func layout(rows: Int = 0, columns: Int = 0,
                        offset: CGPoint = .zero,
                        viewport: CGSize? = nil) -> FrozenPaneLayout {
        FrozenPaneLayout(frozen: FrozenPanes(rows: rows, columns: columns),
                         geometry: GridGeometry(sheet: nil, metrics: metrics),
                         viewport: viewport ?? self.viewport,
                         contentOffset: offset)
    }

    // MARK: - Extent

    func testNothingFrozenIsAnEmptyLayout() {
        let layout = self.layout()
        XCTAssertTrue(layout.isEmpty)
        XCTAssertEqual(layout.frozenSize, .zero)
        // And the main canvas is the whole viewport, exactly as it was before Epic 10.
        XCTAssertEqual(layout.mainFrame, CGRect(origin: .zero, size: viewport))
    }

    func testTheFrozenExtentIsTheSizeOfTheFrozenRowsAndColumns() {
        let layout = self.layout(rows: 2, columns: 1)
        XCTAssertEqual(layout.frozenSize, CGSize(width: 100, height: 56))
    }

    func testFreezingMoreThanTheScreenHoldsIsClamped() {
        // Otherwise the scrolling region has no room left and the grid reads as broken.
        let layout = self.layout(rows: 20, columns: 20)
        XCTAssertEqual(layout.frozenSize.width, 200)
        XCTAssertEqual(layout.frozenSize.height, 150)
    }

    // MARK: - Panes

    func testThePanesAndTheMainCanvasTileTheViewport() {
        let layout = self.layout(rows: 2, columns: 1)
        let corner = layout.corner.frame
        let rowBand = layout.rowBand.frame
        let columnBand = layout.columnBand.frame

        XCTAssertEqual(corner, CGRect(x: 0, y: 0, width: 100, height: 56))
        XCTAssertEqual(rowBand, CGRect(x: 100, y: 0, width: 300, height: 56))
        XCTAssertEqual(columnBand, CGRect(x: 0, y: 56, width: 100, height: 244))
        // The main canvas lives in the scroll view's content coordinates, so it moves with the
        // offset; at rest it starts where the two bands end.
        XCTAssertEqual(layout.mainFrame, CGRect(x: 100, y: 56, width: 300, height: 244))
    }

    func testTheCornerNeverMoves() {
        let scrolled = self.layout(rows: 2, columns: 1, offset: CGPoint(x: 250, y: 400))
        XCTAssertEqual(scrolled.corner.frame, CGRect(x: 0, y: 0, width: 100, height: 56))
        XCTAssertEqual(scrolled.corner.contentOrigin, .zero)
    }

    func testEachBandFollowsExactlyOneAxis() {
        let scrolled = self.layout(rows: 2, columns: 1, offset: CGPoint(x: 250, y: 400))

        // The row band tracks horizontal scrolling and stays on the frozen rows.
        XCTAssertEqual(scrolled.rowBand.contentOrigin, CGPoint(x: 350, y: 0))
        // The column band does the opposite.
        XCTAssertEqual(scrolled.columnBand.contentOrigin, CGPoint(x: 0, y: 456))
    }

    func testTheMainCanvasStartsPastTheFrozenExtent() {
        // This is the line the whole feature rests on: at offset 0 the first unfrozen cell is
        // showing immediately below the band, so scrolling can never strand it underneath.
        let atRest = self.layout(rows: 2, columns: 1)
        XCTAssertEqual(atRest.mainContentOrigin, CGPoint(x: 100, y: 56))

        let scrolled = self.layout(rows: 2, columns: 1, offset: CGPoint(x: 250, y: 400))
        XCTAssertEqual(scrolled.mainContentOrigin, CGPoint(x: 350, y: 456))
    }

    // MARK: - Touches

    func testATouchInAFrozenPaneIgnoresTheScrollOffset() {
        let scrolled = self.layout(rows: 2, columns: 1, offset: CGPoint(x: 250, y: 400))

        // Inside the corner: the point is already a content position.
        XCTAssertEqual(scrolled.contentPoint(fromViewportPoint: CGPoint(x: 40, y: 20)),
                       CGPoint(x: 40, y: 20))
        // Inside the row band: frozen vertically, scrolled horizontally.
        XCTAssertEqual(scrolled.contentPoint(fromViewportPoint: CGPoint(x: 150, y: 20)),
                       CGPoint(x: 400, y: 20))
        // Inside the column band: the other way round.
        XCTAssertEqual(scrolled.contentPoint(fromViewportPoint: CGPoint(x: 40, y: 100)),
                       CGPoint(x: 40, y: 500))
    }

    func testATouchOnTheMainCanvasCarriesBothOffsets() {
        let scrolled = self.layout(rows: 2, columns: 1, offset: CGPoint(x: 250, y: 400))
        XCTAssertEqual(scrolled.contentPoint(fromViewportPoint: CGPoint(x: 150, y: 100)),
                       CGPoint(x: 400, y: 500))
    }

    func testTouchMappingIsUnchangedWithNothingFrozen() {
        let scrolled = self.layout(offset: CGPoint(x: 250, y: 400))
        XCTAssertEqual(scrolled.contentPoint(fromViewportPoint: CGPoint(x: 10, y: 10)),
                       CGPoint(x: 260, y: 410))
    }

    // MARK: - The inverse

    func testAContentPointMapsBackToWhereItIsDrawn() {
        let scrolled = self.layout(rows: 2, columns: 1, offset: CGPoint(x: 250, y: 400))
        XCTAssertEqual(scrolled.viewportPoint(fromContentPoint: CGPoint(x: 400, y: 500)),
                       CGPoint(x: 150, y: 100))
        XCTAssertEqual(scrolled.viewportPoint(fromContentPoint: CGPoint(x: 40, y: 20)),
                       CGPoint(x: 40, y: 20))
    }

    func testAContentPointHiddenBehindAFrozenPaneMapsToNothing() {
        // Content that has scrolled under the band is not visible anywhere, so the fill handle
        // must not become grabbable at a point that shows a frozen cell.
        let scrolled = self.layout(rows: 2, columns: 1, offset: CGPoint(x: 250, y: 400))
        XCTAssertNil(scrolled.viewportPoint(fromContentPoint: CGPoint(x: 300, y: 420)))
    }

    func testAContentPointScrolledOffTheTopMapsToNothing() {
        let scrolled = self.layout(offset: CGPoint(x: 0, y: 400))
        XCTAssertNil(scrolled.viewportPoint(fromContentPoint: CGPoint(x: 10, y: 100)))
    }
}
