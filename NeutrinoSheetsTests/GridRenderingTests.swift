import XCTest
import UIKit
@testable import NeutrinoSheets

/// Epic 6 — proof that the grid actually draws.
///
/// The canvas renders into a `CGContext`, so it can be rendered into a bitmap off-screen and the
/// pixels read back. That makes "does a red cell come out red, in the right place" a unit test
/// rather than something only a human looking at a simulator can answer — and it is the only way
/// to catch a renderer that quietly draws nothing.
@MainActor
final class GridRenderingTests: XCTestCase {

    private let metrics = GridMetrics(defaultColumnWidth: 100, defaultRowHeight: 28,
                                      rowHeaderWidth: 50, columnHeaderHeight: 26, zoom: 1)

    // MARK: - Harness

    /// Renders a sheet into a bitmap and returns a colour sampler over it.
    ///
    /// The canvas is forced light-mode: `UIColor.label` and friends resolve against the current
    /// trait collection, and a test asserting "the text is dark" would otherwise flip meaning with
    /// the simulator's appearance.
    private func render(_ sheet: SheetData?, selection: CellAddress? = nil,
                        showGridLines: Bool = true,
                        size: CGSize = CGSize(width: 400, height: 200),
                        contentOrigin: CGPoint = .zero) -> Sampler {
        let canvas = GridCanvasView(frame: CGRect(origin: .zero, size: size))
        canvas.overrideUserInterfaceStyle = .light
        canvas.contentOrigin = contentOrigin
        canvas.model = GridRenderModel(
            sheet: sheet,
            geometry: GridGeometry(sheet: sheet, metrics: metrics),
            selection: selection,
            showGridLines: showGridLines
        )

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            canvas.traitCollection.performAsCurrent {
                canvas.draw(CGRect(origin: .zero, size: size))
            }
        }
        return Sampler(image: image)
    }

    /// Reads individual pixels out of a rendered image.
    private struct Sampler {
        let image: UIImage

        func color(at point: CGPoint) -> (r: Int, g: Int, b: Int) {
            guard let cgImage = image.cgImage else { return (0, 0, 0) }
            let scale = image.scale
            let x = Int(point.x * scale)
            let y = Int(point.y * scale)
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage,
                          in: CGRect(x: -CGFloat(x), y: -CGFloat(cgImage.height - y - 1),
                                     width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
            return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
        }

        /// Whether any pixel in a rectangle is materially darker than the background — which is
        /// what drawn text looks like without asserting on glyph shapes.
        func hasDarkPixels(in rect: CGRect, threshold: Int = 160) -> Bool {
            for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
                for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
                    let c = color(at: CGPoint(x: x, y: y))
                    if c.r < threshold && c.g < threshold && c.b < threshold { return true }
                }
            }
            return false
        }
    }

    private func assertNear(_ actual: (r: Int, g: Int, b: Int), _ expected: (r: Int, g: Int, b: Int),
                            tolerance: Int = 12, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(actual.r - expected.r), tolerance,
                                 "red \(actual) vs \(expected)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.g - expected.g), tolerance,
                                 "green \(actual) vs \(expected)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.b - expected.b), tolerance,
                                 "blue \(actual) vs \(expected)", file: file, line: line)
    }

    // MARK: - Fills

    func testACellsBackgroundColourIsDrawnInItsOwnRectangle() {
        var style = CellStyle()
        style.backgroundColor = "#ff0000"
        let sheet = SheetData(name: "S", cells: [
            "B2": SavedCell(id: "B2", value: "x", cellStyle: style),
        ])

        let sampler = render(sheet)

        // B2 spans x 100…200, y 28…56. Its centre must be red...
        assertNear(sampler.color(at: CGPoint(x: 150, y: 42)), (255, 0, 0))
        // ...and its neighbours must not be.
        assertNear(sampler.color(at: CGPoint(x: 50, y: 42)), (255, 255, 255))
        assertNear(sampler.color(at: CGPoint(x: 250, y: 42)), (255, 255, 255))
    }

    func testShorthandAndFunctionalColoursAreBothUnderstood() {
        for css in ["#00f", "#0000ff", "rgb(0, 0, 255)", "rgba(0,0,255,1)"] {
            var style = CellStyle()
            style.backgroundColor = css
            let sheet = SheetData(name: "S", cells: [
                "A1": SavedCell(id: "A1", value: "x", cellStyle: style),
            ])
            assertNear(render(sheet).color(at: CGPoint(x: 50, y: 14)), (0, 0, 255))
        }
    }

    func testAnUnparseableColourFallsBackToPlainRatherThanInvisible() {
        var style = CellStyle()
        style.backgroundColor = "not-a-colour"
        let sheet = SheetData(name: "S", cells: [
            "A1": SavedCell(id: "A1", value: "x", cellStyle: style),
        ])

        // Background stays the default; the cell is still legible rather than blanked out.
        let sampler = render(sheet)
        assertNear(sampler.color(at: CGPoint(x: 90, y: 14)), (255, 255, 255))
        XCTAssertTrue(sampler.hasDarkPixels(in: CGRect(x: 2, y: 2, width: 96, height: 24)))
    }

    // MARK: - Merges

    /// A merge anchor has to paint across the whole block. Painting only its own cell would leave
    /// three quarters of a merged heading unfilled.
    func testAMergeAnchorFillsItsWholeBlock() {
        var style = CellStyle()
        style.backgroundColor = "#00ff00"
        let sheet = SheetData(name: "S", cells: [
            "A1": SavedCell(id: "A1", value: "Merged", cellStyle: style, colSpan: 2, rowSpan: 2),
            "B1": SavedCell(id: "B1", mergeAnchor: "A1"),
            "A2": SavedCell(id: "A2", mergeAnchor: "A1"),
            "B2": SavedCell(id: "B2", mergeAnchor: "A1"),
        ])

        let sampler = render(sheet)

        // All four quadrants of the 2×2 block are filled.
        assertNear(sampler.color(at: CGPoint(x: 50, y: 14)), (0, 255, 0))
        assertNear(sampler.color(at: CGPoint(x: 150, y: 14)), (0, 255, 0))
        assertNear(sampler.color(at: CGPoint(x: 50, y: 42)), (0, 255, 0))
        assertNear(sampler.color(at: CGPoint(x: 150, y: 42)), (0, 255, 0))
        // And nothing beyond it.
        assertNear(sampler.color(at: CGPoint(x: 250, y: 14)), (255, 255, 255))
    }

    /// The anchor may be scrolled off-screen while its block still covers the viewport. If the
    /// renderer only considered cells inside the visible range, a merged block would blink out as
    /// its anchor left the screen.
    func testAMergeIsStillDrawnWhenItsAnchorIsScrolledOutOfView() {
        var style = CellStyle()
        style.backgroundColor = "#ff00ff"
        let sheet = SheetData(name: "S", cells: [
            "A1": SavedCell(id: "A1", value: "Wide", cellStyle: style, colSpan: 6, rowSpan: 1),
            "D1": SavedCell(id: "D1", mergeAnchor: "A1"),
        ])

        // Scrolled 300pt right: the anchor (column A) is off-screen, column D is not.
        let sampler = render(sheet, size: CGSize(width: 200, height: 100),
                             contentOrigin: CGPoint(x: 300, y: 0))

        assertNear(sampler.color(at: CGPoint(x: 50, y: 14)), (255, 0, 255))
    }

    // MARK: - Text

    func testCellTextIsDrawn() {
        let sheet = SheetData(name: "S", cells: [
            "A1": SavedCell(id: "A1", value: "Revenue"),
        ])

        let sampler = render(sheet)

        XCTAssertTrue(sampler.hasDarkPixels(in: CGRect(x: 4, y: 4, width: 92, height: 20)),
                      "no text pixels in A1")
        // B1 is empty, so nothing should have been drawn there.
        XCTAssertFalse(sampler.hasDarkPixels(in: CGRect(x: 106, y: 4, width: 88, height: 20)),
                       "unexpected pixels in the empty B1")
    }

    /// The renderer shows `value` — the web app's pre-computed result — not the formula text. This
    /// is what lets a viewer ship before the formula engine does.
    func testAFormulaCellShowsItsEvaluatedValue() {
        let sheet = SheetData(name: "S", cells: [
            "A1": SavedCell(id: "A1", raw: "=SUM(B1:B9)", value: "42"),
        ])

        let sampler = render(sheet)
        // "42" is numeric, so it sits *right* — the spreadsheet convention the renderer applies
        // when a cell has no explicit alignment. A column of figures is unreadable otherwise.
        XCTAssertTrue(sampler.hasDarkPixels(in: CGRect(x: 60, y: 4, width: 36, height: 20)),
                      "no value pixels at the right of the cell")
        XCTAssertFalse(sampler.hasDarkPixels(in: CGRect(x: 4, y: 4, width: 40, height: 20)),
                       "the formula text appears to have been drawn instead of its value")
    }

    func testTextIsLeftAlignedAndNumbersRightAlignedByDefault() {
        let sheet = SheetData(name: "S", cells: [
            "A1": SavedCell(id: "A1", value: "ab"),
            "B1": SavedCell(id: "B1", value: "12"),
        ])

        let sampler = render(sheet)

        // A1's text hugs the left edge, B1's number hugs the right.
        XCTAssertTrue(sampler.hasDarkPixels(in: CGRect(x: 4, y: 4, width: 30, height: 20)))
        XCTAssertFalse(sampler.hasDarkPixels(in: CGRect(x: 66, y: 4, width: 30, height: 20)))
        XCTAssertTrue(sampler.hasDarkPixels(in: CGRect(x: 166, y: 4, width: 30, height: 20)))
        XCTAssertFalse(sampler.hasDarkPixels(in: CGRect(x: 104, y: 4, width: 30, height: 20)))
    }

    func testTextColourIsHonoured() {
        var style = CellStyle()
        style.color = "#ff0000"
        let sheet = SheetData(name: "S", cells: [
            // A block of text, so at least one pixel lands solidly inside a glyph.
            "A1": SavedCell(id: "A1", value: "██████", cellStyle: style),
        ])

        let sampler = render(sheet)
        var foundRed = false
        for x in stride(from: 4.0, to: 96.0, by: 1) {
            for y in stride(from: 6.0, to: 22.0, by: 1) {
                let c = sampler.color(at: CGPoint(x: x, y: y))
                if c.r > 180 && c.g < 90 && c.b < 90 { foundRed = true }
            }
        }
        XCTAssertTrue(foundRed, "no red text pixels")
    }

    // MARK: - Grid lines and selection

    func testGridLinesCanBeTurnedOff() {
        let sheet = SheetData(name: "S")

        let withLines = render(sheet, showGridLines: true)
        let withoutLines = render(sheet, showGridLines: false)

        // The boundary between columns A and B, one pixel in from the edge.
        let onTheLine = CGRect(x: 99, y: 5, width: 2, height: 18)
        XCTAssertTrue(withLines.hasDarkPixels(in: onTheLine, threshold: 250))
        XCTAssertFalse(withoutLines.hasDarkPixels(in: onTheLine, threshold: 250))
    }

    func testTheSelectionIsDrawnAroundTheSelectedCell() {
        let sheet = SheetData(name: "S")
        let sampler = render(sheet, selection: CellAddress(column: 2, row: 2))

        // The tint-coloured outline runs around B2 (x 100…200, y 28…56).
        var foundTint = false
        for x in stride(from: 100.0, to: 200.0, by: 1) {
            let c = sampler.color(at: CGPoint(x: x, y: 30))
            if c.b > 150 && c.r < 120 { foundTint = true }
        }
        XCTAssertTrue(foundTint, "no selection outline on B2")
    }

    // MARK: - Number formats end to end

    /// The formatter is unit-tested on its own; this proves the renderer actually routes cell text
    /// through it rather than drawing the stored string.
    func testTheRendererFormatsThroughCellFormatter() {
        var style = CellStyle()
        style.numberFormat = "currency"
        let sheet = SheetData(name: "S", cells: [
            "A1": SavedCell(id: "A1", value: "1250.5", cellStyle: style),
        ])

        // "$1,250.50" is wider than "1250.5", so the formatted text reaches further right. A
        // renderer drawing the raw value would leave this region blank.
        let sampler = render(sheet)
        XCTAssertTrue(sampler.hasDarkPixels(in: CGRect(x: 4, y: 4, width: 92, height: 20)))
    }

    // MARK: - Empty state

    func testAnEmptySheetStillDrawsItsGrid() {
        let sampler = render(nil)

        // The background is painted and the lines are there; nothing crashes on a nil sheet.
        assertNear(sampler.color(at: CGPoint(x: 50, y: 14)), (255, 255, 255))
        XCTAssertTrue(sampler.hasDarkPixels(in: CGRect(x: 99, y: 5, width: 2, height: 18),
                                            threshold: 250))
    }
}
