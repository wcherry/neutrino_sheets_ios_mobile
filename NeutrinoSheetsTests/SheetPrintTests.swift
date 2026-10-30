import PDFKit
import UIKit
import XCTest
import NeutrinoPrint
@testable import NeutrinoSheets

/// Printing a sheet: which cells are printed, how they are cut into pages, and what repeats on each
/// one. The header, page numbers and dialog are NeutrinoPrint's and tested there.
@MainActor
final class SheetPrintTests: XCTestCase {

    // MARK: - Helpers

    /// A portrait Letter page's content area: the paper less an 18pt hardware margin on each side,
    /// NeutrinoPrint's default margins, and the header and footer bands.
    private let page = CGSize(width: 612 - 36 - 72, height: 792 - 36 - 36 - 56)

    /// A sheet `columns` wide and `rows` tall, every cell holding its own address.
    private func sheet(columns: Int, rows: Int) -> SheetData {
        var cells: [String: SavedCell] = [:]
        for row in 1...rows {
            for column in 1...columns {
                let id = CellAddress(column: column, row: row).id
                cells[id] = SavedCell(id: id, raw: id, value: id)
            }
        }
        return SheetData(name: "Data", cells: cells)
    }

    private func source(_ sheet: SheetData, range: CellRange? = nil,
                        frozen: FrozenPanes = FrozenPanes()) -> SheetPrintPageSource {
        SheetPrintPageSource(sheet: sheet, range: range ?? SheetPrint.usedRange(of: sheet),
                             frozen: frozen, hiddenRows: [], showGridLines: true)
    }

    private func pageTexts(_ job: PrintJob) -> [String] {
        let pdf = NeutrinoPrintPageRenderer(job: job).pdfData()
        guard let document = PDFDocument(data: pdf) else { return [] }
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    private func range(_ a: String, _ b: String) -> CellRange {
        CellRange(CellAddress(a)!, CellAddress(b)!)
    }

    // MARK: - Range

    func testTheUsedRangeRunsFromA1ToTheLastPopulatedCell() {
        XCTAssertEqual(SheetPrint.usedRange(of: sheet(columns: 4, rows: 7)), range("A1", "D7"))
    }

    func testAnEmptySheetStillPrintsAPage() {
        let empty = SheetData(name: "Empty")
        XCTAssertEqual(SheetPrint.usedRange(of: empty), range("A1", "A1"))
        XCTAssertEqual(source(empty).pageCount(for: page), 1)
    }

    // MARK: - Fitting

    func testASmallSheetIsOnePageAtFullSize() {
        let layout = source(sheet(columns: 3, rows: 10)).layout(for: page)
        XCTAssertEqual(layout.pageCount, 1)
        XCTAssertEqual(layout.scale, 1)
    }

    /// Seven default columns are 700pt against a 504pt page: shrinking to 72% fits them on one page
    /// rather than stranding two columns on a second.
    func testASlightlyWideSheetShrinksToFitTheWidth() {
        let layout = source(sheet(columns: 7, rows: 5)).layout(for: page)
        XCTAssertEqual(layout.columnBands, [1...7])
        XCTAssertEqual(layout.scale, page.width / 700, accuracy: 0.001)
    }

    /// Thirty columns would need 17% — unreadable — so the sheet is split at the minimum scale.
    func testAVeryWideSheetIsSplitIntoColumnBands() {
        let source = source(sheet(columns: 30, rows: 5))
        let layout = source.layout(for: page)

        XCTAssertEqual(layout.scale, SheetPrintPageSource.minimumScale)
        XCTAssertGreaterThan(layout.columnBands.count, 1)
        XCTAssertEqual(layout.columnBands.first?.lowerBound, 1)
        XCTAssertEqual(layout.columnBands.last?.upperBound, 30)
        XCTAssertTrue(source.prefersLandscape)
    }

    func testANarrowSheetPrefersPortrait() {
        XCTAssertFalse(source(sheet(columns: 4, rows: 200)).prefersLandscape)
    }

    func testATallSheetIsSplitIntoRowBands() {
        let layout = source(sheet(columns: 2, rows: 200)).layout(for: page)
        XCTAssertGreaterThan(layout.rowBands.count, 1)
        XCTAssertEqual(layout.rowBands.last?.upperBound, 200)
        XCTAssertEqual(layout.pageCount, layout.rowBands.count)
    }

    func testBandsAreConsecutiveAndFit() {
        let widths: [Int: CGFloat] = [1: 100, 2: 100, 3: 300, 4: 50, 5: 600, 6: 10]
        let bands = SheetPrintPageSource.bands(of: 1...6, available: 250) { widths[$0]! }
        // 1+2 fit; 3 alone; 4 alone (5 would overflow); 5 is wider than a page and gets its own;
        // 6 follows on its own band.
        XCTAssertEqual(bands, [1...2, 3...3, 4...4, 5...5, 6...6])
    }

    // MARK: - Page order and titles

    /// Down, then across: the first pages are the left-hand columns all the way down.
    func testPagesRunDownThenAcross() {
        let source = source(sheet(columns: 30, rows: 120))
        let layout = source.layout(for: page)
        XCTAssertGreaterThan(layout.rowBands.count, 1)
        XCTAssertGreaterThan(layout.columnBands.count, 1)

        let texts = pageTexts(PrintJob(name: "a", content: .pages(source)))
        let secondRowBand = layout.rowBands[1].lowerBound
        let secondColumnBand = layout.columnBands[1].lowerBound
        let firstColumnLetter = String(CellAddress(column: 1, row: 1).id.dropLast())
        let laterColumnLetter = String(CellAddress(column: secondColumnBand, row: 1).id.dropLast())

        XCTAssertEqual(texts.count, layout.pageCount)
        // Page 2 is the first columns again, further down the sheet...
        XCTAssertTrue(texts[1].contains("\(firstColumnLetter)\(secondRowBand)"), texts[1])
        XCTAssertFalse(texts[1].contains("\(laterColumnLetter)\(secondRowBand)"))
        // ...and the next band of columns starts at the top once the first band has run out.
        let acrossPage = layout.rowBands.count
        XCTAssertTrue(texts[acrossPage].contains("\(laterColumnLetter)1"), texts[acrossPage])
    }

    func testFrozenRowsRepeatOnEveryPage() {
        var data = sheet(columns: 2, rows: 200)
        data.cells["A1"] = SavedCell(id: "A1", raw: "Region", value: "Region")
        let source = source(data, frozen: FrozenPanes(rows: 1, columns: 0))
        let texts = pageTexts(PrintJob(name: "a", content: .pages(source)))

        XCTAssertGreaterThan(texts.count, 1)
        for (index, text) in texts.enumerated() {
            XCTAssertTrue(text.contains("Region"), "page \(index + 1) lost the title row")
        }
        XCTAssertEqual(source.layout(for: page).rowBands.first?.lowerBound, 2,
                       "the title row is not printed a second time as body")
    }

    func testASelectionInsideTheFrozenRowsPrintsAsItself() {
        let source = source(sheet(columns: 3, rows: 10), range: range("A1", "C2"),
                            frozen: FrozenPanes(rows: 3, columns: 0))
        let layout = source.layout(for: page)
        XCTAssertEqual(layout.rowBands, [1...2])
        XCTAssertFalse(layout.showsTitleRows)
    }

    func testOnlyTheSelectionIsPrinted() {
        let job = SheetPrint.job(title: "Budget", sheetName: nil, sheet: sheet(columns: 5, rows: 5),
                                 range: range("B2", "C3"))
        let text = pageTexts(job).joined()

        XCTAssertTrue(text.contains("B2"))
        XCTAssertTrue(text.contains("C3"))
        XCTAssertFalse(text.contains("A1"))
        XCTAssertFalse(text.contains("D4"))
    }

    // MARK: - The job

    func testTheHeaderNamesTheTabAndTheSelection() {
        let job = SheetPrint.job(title: "Budget", sheetName: "Q3", sheet: sheet(columns: 2, rows: 2),
                                 range: range("A1", "B2"))
        XCTAssertEqual(job.name, "Budget")
        XCTAssertEqual(job.header, "Budget \u{2014} Q3 (A1:B2)")
    }

    func testAOneTabWorkbookIsHeadedWithItsTitleAlone() {
        let job = SheetPrint.job(title: "Budget", sheetName: nil, sheet: sheet(columns: 2, rows: 2))
        XCTAssertEqual(job.header, "Budget")
        XCTAssertEqual(job.orientation, .portrait)
    }

    // MARK: - Threading

    /// The print system may draw a page off the main thread, and every cell goes through the
    /// style resolver's memo tables.
    nonisolated func testTheStyleResolverCanBeUsedOffTheMainThread() {
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            _ = GridStyleResolver.color("#\(String(format: "%06x", index * 997))")
            _ = GridStyleResolver.font(for: nil, defaultSize: CGFloat(10 + index % 5))
        }
        XCTAssertNotNil(GridStyleResolver.color("#ff0000"))
    }
}
