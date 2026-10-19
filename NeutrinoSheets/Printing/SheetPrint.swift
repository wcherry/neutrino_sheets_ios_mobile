import UIKit
import NeutrinoPrint

// MARK: - SheetPrint

/// Turns a sheet, or a selection on it, into the ``PrintJob`` NeutrinoPrint sends to the printer.
///
/// The pages, running header, page numbers and the print dialog are NeutrinoPrint's and the same in
/// every Neutrino app. What is a spreadsheet's own lives here and in ``SheetPrintPageSource``:
/// which cells are printed, how they are cut into pages, and which rows repeat on each one.
@MainActor
enum SheetPrint {

    /// The print job for `range` of `sheet` — the sheet's used range when `range` is nil.
    ///
    /// - Parameters:
    ///   - sheetName: Added to the running header when the workbook has more than one tab, so a
    ///     printed page says which one it came from.
    ///   - frozen: Frozen rows and columns repeat on every page, as print titles — the same reason
    ///     they are frozen on screen: a page of figures under no header is unreadable.
    ///   - hiddenRows: Rows a filter is hiding. A filtered sheet prints filtered.
    static func job(title: String,
                    sheetName: String?,
                    sheet: SheetData,
                    range: CellRange? = nil,
                    frozen: FrozenPanes = FrozenPanes(),
                    hiddenRows: Set<Int> = [],
                    showGridLines: Bool = true) -> PrintJob {
        let source = SheetPrintPageSource(sheet: sheet,
                                          range: range ?? usedRange(of: sheet),
                                          frozen: frozen,
                                          hiddenRows: hiddenRows,
                                          showGridLines: showGridLines)

        var header = title
        if let sheetName { header += " \u{2014} \(sheetName)" }
        if let range { header += " (\(range.address))" }

        return PrintJob(name: title,
                        content: .pages(source),
                        header: header,
                        orientation: source.prefersLandscape ? .landscape : .portrait)
    }

    /// `A1` to the last populated cell, or just `A1` for an empty sheet — which still prints, as a
    /// page with its header on it, rather than refusing.
    nonisolated static func usedRange(of sheet: SheetData) -> CellRange {
        let bounds = sheet.usedBounds ?? (rows: 1, columns: 1)
        return CellRange(CellAddress(column: 1, row: 1),
                         CellAddress(column: bounds.columns, row: bounds.rows))
    }
}

// MARK: - SheetPrintPageSource

/// Cuts a range of cells into pages: shrunk to fit the paper's width where that keeps the text
/// readable, otherwise split into bands of columns and rows and printed down, then across — the
/// order every spreadsheet prints in.
///
/// Frozen rows and columns are drawn at the top and left of every page.
final class SheetPrintPageSource: PrintPageSource {

    /// The furthest a sheet is shrunk to fit the page width. Below this the default 13pt cell text
    /// is under 8pt, and splitting across pages reads better than squinting.
    static let minimumScale: CGFloat = 0.6

    /// Grid lines on paper: visible, but well under the weight of a cell border.
    static let printedHairline: CGFloat = 0.5

    // MARK: - Input

    private let painter: GridPainter
    private let titleColumns: ClosedRange<Int>?
    private let titleRows: ClosedRange<Int>?
    private let bodyColumns: ClosedRange<Int>
    private let bodyRows: ClosedRange<Int>

    // MARK: - Layout

    struct Layout: Equatable {
        var scale: CGFloat
        /// Bands of body columns and rows; page `i` is column band `i / rowBands.count` and row band
        /// `i % rowBands.count`.
        var columnBands: [ClosedRange<Int>]
        var rowBands: [ClosedRange<Int>]
        /// Whether the frozen columns and rows fit alongside the body; dropped when they would
        /// take most of the page.
        var showsTitleColumns: Bool
        var showsTitleRows: Bool

        var pageCount: Int { max(1, columnBands.count * rowBands.count) }
    }

    private var cached: (size: CGSize, layout: Layout)?
    private let lock = NSLock()

    // MARK: - Init

    init(sheet: SheetData, range: CellRange, frozen: FrozenPanes, hiddenRows: Set<Int>,
         showGridLines: Bool) {
        let geometry = GridGeometry(sheet: sheet, metrics: GridMetrics(), hiddenRows: hiddenRows,
                                    minimumExtent: (range.end.column, range.end.row))
        painter = GridPainter(
            model: GridRenderModel(sheet: sheet, geometry: geometry, showGridLines: showGridLines),
            baseFontSize: 13,
            hairline: Self.printedHairline
        )

        // A title band is only worth repeating when there is body left to print beneath it: a
        // selection that lies wholly inside the frozen rows simply prints as itself.
        let titleRowEnd = frozen.rows
        if titleRowEnd > 0, range.end.row > titleRowEnd {
            titleRows = 1...titleRowEnd
            bodyRows = max(range.start.row, titleRowEnd + 1)...range.end.row
        } else {
            titleRows = nil
            bodyRows = range.rows
        }

        let titleColumnEnd = frozen.columns
        if titleColumnEnd > 0, range.end.column > titleColumnEnd {
            titleColumns = 1...titleColumnEnd
            bodyColumns = max(range.start.column, titleColumnEnd + 1)...range.end.column
        } else {
            titleColumns = nil
            bodyColumns = range.columns
        }
    }

    // MARK: - Measurements

    private var geometry: GridGeometry { painter.model.geometry }

    private func width(of columns: ClosedRange<Int>?) -> CGFloat {
        guard let columns else { return 0 }
        return geometry.x(ofColumn: columns.upperBound + 1) - geometry.x(ofColumn: columns.lowerBound)
    }

    private func height(of rows: ClosedRange<Int>?) -> CGFloat {
        guard let rows else { return 0 }
        return geometry.y(ofRow: rows.upperBound + 1) - geometry.y(ofRow: rows.lowerBound)
    }

    /// Wide enough that landscape paper suits it better — more than a portrait Letter page can
    /// hold without splitting, even at the minimum scale.
    var prefersLandscape: Bool {
        let portraitWidth = NeutrinoPrintPageRenderer.letter.width - 2 * 18
            - PrintJob.defaultMargins.left - PrintJob.defaultMargins.right
        return width(of: titleColumns) + width(of: bodyColumns) > portraitWidth / Self.minimumScale
    }

    // MARK: - PrintPageSource

    func pageCount(for contentSize: CGSize) -> Int {
        layout(for: contentSize).pageCount
    }

    func drawPage(at index: Int, in rect: CGRect) {
        let layout = layout(for: rect.size)
        guard index >= 0, index < layout.pageCount,
              let context = UIGraphicsGetCurrentContext() else { return }

        let columns = layout.columnBands[index / layout.rowBands.count]
        let rows = layout.rowBands[index % layout.rowBands.count]
        let titleColumns = layout.showsTitleColumns ? self.titleColumns : nil
        let titleRows = layout.showsTitleRows ? self.titleRows : nil
        let left = width(of: titleColumns)
        let top = height(of: titleRows)

        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: layout.scale, y: layout.scale)

        if let titleColumns, let titleRows {
            drawRegion(columns: titleColumns, rows: titleRows, at: .zero, in: context)
        }
        if let titleRows {
            drawRegion(columns: columns, rows: titleRows, at: CGPoint(x: left, y: 0), in: context)
        }
        if let titleColumns {
            drawRegion(columns: titleColumns, rows: rows, at: CGPoint(x: 0, y: top), in: context)
        }
        drawRegion(columns: columns, rows: rows, at: CGPoint(x: left, y: top), in: context)

        context.restoreGState()
    }

    /// Draws one block of cells with its top-left corner at `origin`, clipped to the block so text
    /// overflowing from it does not run over its neighbours on the page.
    private func drawRegion(columns: ClosedRange<Int>, rows: ClosedRange<Int>, at origin: CGPoint,
                            in context: CGContext) {
        let region = CGRect(x: geometry.x(ofColumn: columns.lowerBound),
                            y: geometry.y(ofRow: rows.lowerBound),
                            width: width(of: columns), height: height(of: rows))
        guard region.width > 0, region.height > 0 else { return }

        context.saveGState()
        context.translateBy(x: origin.x - region.minX, y: origin.y - region.minY)
        context.clip(to: region)
        let visible = (columns: columns, rows: rows)
        if painter.model.showGridLines {
            painter.drawGridLines(visible: visible, in: context)
        }
        painter.drawCells(visible: visible, clip: region, in: context)
        context.restoreGState()
    }

    // MARK: - Pagination

    func layout(for size: CGSize) -> Layout {
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.size == size { return cached.layout }
        let layout = computeLayout(for: size)
        cached = (size, layout)
        return layout
    }

    private func computeLayout(for size: CGSize) -> Layout {
        guard size.width > 0, size.height > 0 else {
            return Layout(scale: 1, columnBands: [bodyColumns], rowBands: [bodyRows],
                          showsTitleColumns: false, showsTitleRows: false)
        }

        // Shrink to the page width when that alone makes it fit, down to the minimum scale.
        let fullWidth = width(of: titleColumns) + width(of: bodyColumns)
        let scale = fullWidth > 0
            ? min(1, max(Self.minimumScale, size.width / fullWidth))
            : 1
        let pageWidth = size.width / scale
        let pageHeight = size.height / scale

        // Titles that would take more than half the page leave too little for the body.
        let showsTitleColumns = titleColumns != nil && width(of: titleColumns) < pageWidth / 2
        let showsTitleRows = titleRows != nil && height(of: titleRows) < pageHeight / 2

        let columnBands = Self.bands(of: bodyColumns,
                                     available: pageWidth - (showsTitleColumns ? width(of: titleColumns) : 0),
                                     size: { CGFloat(self.geometry.width(ofColumn: $0)) })
        let rowBands = Self.bands(of: bodyRows,
                                  available: pageHeight - (showsTitleRows ? height(of: titleRows) : 0),
                                  size: { CGFloat(self.geometry.height(ofRow: $0)) })

        return Layout(scale: scale, columnBands: columnBands, rowBands: rowBands,
                      showsTitleColumns: showsTitleColumns, showsTitleRows: showsTitleRows)
    }

    /// Cuts `indices` into consecutive runs that each fit in `available` points. A single column or
    /// row wider than the page gets a page to itself and is clipped, rather than never fitting.
    static func bands(of indices: ClosedRange<Int>, available: CGFloat,
                      size: (Int) -> CGFloat) -> [ClosedRange<Int>] {
        var bands: [ClosedRange<Int>] = []
        var start = indices.lowerBound
        var used: CGFloat = 0

        for index in indices {
            let extent = size(index)
            if index > start, used + extent > available {
                bands.append(start...(index - 1))
                start = index
                used = 0
            }
            used += extent
        }
        bands.append(start...indices.upperBound)
        return bands
    }
}
