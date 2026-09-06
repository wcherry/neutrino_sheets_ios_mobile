import CoreGraphics
import Foundation

// MARK: - GridMetrics

/// The fixed measurements of the grid, before any per-column or per-row override is applied.
///
/// The defaults come from the web app's `editor/constants.ts` so a workbook with no stored widths
/// lays out the same in both clients.
struct GridMetrics: Equatable {

    /// Width for a column with no `colWidths` entry. `CELL_W`.
    var defaultColumnWidth: Double = 100
    /// Height for a row with no `rowHeights` entry. `CELL_H`.
    var defaultRowHeight: Double = 28
    /// Width of the frozen row-number gutter. `ROW_HDR_W`.
    var rowHeaderWidth: Double = 50
    /// Height of the frozen column-letter bar. `COL_HDR_H`.
    var columnHeaderHeight: Double = 26

    /// Pinch zoom, applied on top of every measurement above.
    var zoom: Double = 1

    static let zoomRange: ClosedRange<Double> = 0.5...3.0

    /// The metrics with `zoom` folded into the sizes, for the chrome around the grid — the frozen
    /// headers and the canvas's base font size.
    ///
    /// `GridGeometry` deliberately does **not** take these: it applies zoom itself, so that the
    /// workbook's own column widths are scaled too. Handing it pre-scaled metrics would leave
    /// `zoom` at 1 and quietly skip every stored width.
    var scaled: GridMetrics {
        GridMetrics(defaultColumnWidth: defaultColumnWidth * zoom,
                    defaultRowHeight: defaultRowHeight * zoom,
                    rowHeaderWidth: rowHeaderWidth * zoom,
                    columnHeaderHeight: columnHeaderHeight * zoom,
                    zoom: 1)
    }
}

// MARK: - FrozenPanes

/// Epic 10 — "Freeze panes": how many rows off the top and columns off the left stay put while the
/// rest of the grid scrolls under them.
///
/// A view setting, not a workbook one — the file format has no field for it. See
/// ``SheetEditorModel/frozen``.
struct FrozenPanes: Equatable, CustomStringConvertible {

    /// Rows frozen at the top, 0 for none.
    var rows: Int = 0
    /// Columns frozen at the left.
    var columns: Int = 0

    var isEmpty: Bool { rows <= 0 && columns <= 0 }

    /// What the confirmation says: "2 rows", "1 column", "2 rows and 1 column".
    var description: String {
        let parts = [
            rows > 0 ? "\(rows) row\(rows == 1 ? "" : "s")" : nil,
            columns > 0 ? "\(columns) column\(columns == 1 ? "" : "s")" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? "nothing" : parts.joined(separator: " and ")
    }
}

// MARK: - GridGeometry

/// Maps between cell addresses and points, and answers "what is on screen right now".
///
/// Column and row positions are held as **cumulative offset tables** rather than recomputed per
/// lookup. A workbook can override any column's width, so the position of column 400 is the sum of
/// 399 widths — doing that per cell while scrolling is what turns a grid into a slideshow. The
/// tables are built once per layout pass and then every lookup is a binary search.
///
/// The tables cover a bounded *extent*, not the format's 65,536 × 65,536 maximum: a table with
/// 65,536 entries per axis would cost more to build than the scrolling it saves. Beyond the extent
/// every column is the default width, which is true by construction — a column with an override is
/// inside the used bounds by definition.
struct GridGeometry {

    // MARK: - Configuration

    let metrics: GridMetrics

    /// The last column and row that get their own table entry, 1-based.
    let extent: (columns: Int, rows: Int)

    // MARK: - Tables

    /// `columnOffsets[i]` is the x of column `i + 1`'s left edge, relative to the content origin.
    /// One longer than the extent so the last column's right edge is readable without a special case.
    private let columnOffsets: [Double]
    private let rowOffsets: [Double]

    /// The default sizes with zoom already applied, so nothing downstream has to remember to.
    private let defaultColumnWidth: Double
    private let defaultRowHeight: Double

    // MARK: - Init

    /// Builds the tables for one sheet.
    ///
    /// - Parameters:
    ///   - sheet: supplies `colWidths` / `rowHeights`, both keyed by *0-based* stringified index.
    ///   - metrics: **unscaled**. Zoom is applied here, to the workbook's own widths as well as to
    ///     the defaults — scaling only the defaults would leave every column the user (or the web
    ///     app) had resized stuck at its unzoomed width while the rest of the grid grew around it.
    ///   - hiddenRows: **1-based** rows a column filter is hiding, laid out at zero height. Epic 10
    ///     keeps them in the grid rather than removing them from the workbook, which is what makes a
    ///     filter something you can take off again — and it is what the web app does (it sets those
    ///     rows to height 0 too).
    ///   - minimumExtent: how much empty grid to lay out past the populated cells, so a user can
    ///     scroll into blank space and start typing rather than hitting a wall at the last cell.
    init(sheet: SheetData?, metrics: GridMetrics, hiddenRows: Set<Int> = [],
         minimumExtent: (columns: Int, rows: Int) = (26, 100)) {
        self.metrics = metrics
        defaultColumnWidth = metrics.defaultColumnWidth * metrics.zoom
        defaultRowHeight = metrics.defaultRowHeight * metrics.zoom

        let used = sheet?.usedBounds
        let columns = min(max(minimumExtent.columns, (used?.columns ?? 0) + 5), CellAddress.maxColumn)
        let rows = min(max(minimumExtent.rows, (used?.rows ?? 0) + 20), CellAddress.maxRow)
        extent = (columns, rows)

        var columnOffsets = [Double](repeating: 0, count: columns + 1)
        for index in 0..<columns {
            // `colWidths` is 0-based, cell addresses are 1-based. The conversion happens here and
            // nowhere else.
            let width = (sheet?.width(ofColumn: index) ?? metrics.defaultColumnWidth) * metrics.zoom
            columnOffsets[index + 1] = columnOffsets[index] + max(0, width)
        }
        var rowOffsets = [Double](repeating: 0, count: rows + 1)
        for index in 0..<rows {
            // A filtered row collapses to nothing, exactly as a row hidden by storing height 0
            // does. The two are deliberately indistinguishable to everything downstream — hit
            // testing, the renderer and the selection all only ever ask how tall a row is.
            let height = hiddenRows.contains(index + 1)
                ? 0
                : (sheet?.height(ofRow: index) ?? metrics.defaultRowHeight) * metrics.zoom
            rowOffsets[index + 1] = rowOffsets[index] + max(0, height)
        }
        self.columnOffsets = columnOffsets
        self.rowOffsets = rowOffsets
    }

    // MARK: - Sizes

    /// The full scrollable content size, excluding the frozen headers.
    var contentSize: CGSize {
        CGSize(width: columnOffsets[extent.columns], height: rowOffsets[extent.rows])
    }

    /// The x of a 1-based column's left edge.
    func x(ofColumn column: Int) -> Double {
        guard column >= 1 else { return 0 }
        if column <= extent.columns { return columnOffsets[column - 1] }
        // Past the table, every column is the default width.
        return columnOffsets[extent.columns]
            + Double(column - 1 - extent.columns) * defaultColumnWidth
    }

    func y(ofRow row: Int) -> Double {
        guard row >= 1 else { return 0 }
        if row <= extent.rows { return rowOffsets[row - 1] }
        return rowOffsets[extent.rows] + Double(row - 1 - extent.rows) * defaultRowHeight
    }

    func width(ofColumn column: Int) -> Double {
        guard column >= 1, column <= extent.columns else { return defaultColumnWidth }
        return columnOffsets[column] - columnOffsets[column - 1]
    }

    func height(ofRow row: Int) -> Double {
        guard row >= 1, row <= extent.rows else { return defaultRowHeight }
        return rowOffsets[row] - rowOffsets[row - 1]
    }

    /// The rectangle a single cell occupies in content coordinates.
    func rect(for address: CellAddress) -> CGRect {
        CGRect(x: x(ofColumn: address.column), y: y(ofRow: address.row),
               width: width(ofColumn: address.column), height: height(ofRow: address.row))
    }

    /// The rectangle a cell occupies once its merge span is taken into account.
    func rect(for address: CellAddress, colSpan: Int, rowSpan: Int) -> CGRect {
        let origin = CGPoint(x: x(ofColumn: address.column), y: y(ofRow: address.row))
        let right = x(ofColumn: address.column + max(1, colSpan))
        let bottom = y(ofRow: address.row + max(1, rowSpan))
        return CGRect(x: origin.x, y: origin.y, width: right - origin.x, height: bottom - origin.y)
    }

    /// How many cells of a selection are scanned for merges reaching out of it.
    ///
    /// The scan runs inside `draw(_:)`, so it is on the frame loop. A selection of a few hundred
    /// cells costs a few hundred dictionary lookups and is free at this scale; a selection of a
    /// whole column is 65,536 of them *per frame* and would turn scrolling into a slideshow. Past
    /// the limit the outline is drawn on the plain rectangle — a merge straddling the edge of a
    /// selection that large is a pixel nobody can see.
    private static let mergeScanLimit = 1024

    /// The rectangle a whole range occupies, widened to cover any merge that reaches out of it.
    ///
    /// Shared by the renderer and by the fill handle's hit testing, which have to agree: a handle
    /// drawn at one corner and grabbable at another is a handle that does not work.
    func rect(for range: CellRange, cells: [String: SavedCell]?) -> CGRect {
        var rect = self.rect(for: range.start,
                             colSpan: range.columnCount, rowSpan: range.rowCount)
        guard let cells, !cells.isEmpty, range.cellCount <= Self.mergeScanLimit else { return rect }
        for address in range.addresses {
            guard let cell = cells[address.id],
                  (cell.colSpan ?? 1) > 1 || (cell.rowSpan ?? 1) > 1 else { continue }
            rect = rect.union(self.rect(for: address,
                                        colSpan: cell.colSpan ?? 1, rowSpan: cell.rowSpan ?? 1))
        }
        return rect
    }

    // MARK: - Hit testing

    /// The cell containing a point in content coordinates. Points above or left of the grid clamp
    /// to the first row / column, which is what a tap on a border should do.
    func address(at point: CGPoint) -> CellAddress {
        CellAddress(column: column(atX: point.x), row: row(atY: point.y))
    }

    func column(atX x: Double) -> Int {
        index(for: x, in: columnOffsets, extent: extent.columns,
              defaultSize: defaultColumnWidth, limit: CellAddress.maxColumn)
    }

    func row(atY y: Double) -> Int {
        index(for: y, in: rowOffsets, extent: extent.rows,
              defaultSize: defaultRowHeight, limit: CellAddress.maxRow)
    }

    // MARK: - Visible range

    /// The 1-based, inclusive span of columns and rows intersecting `rect` in content coordinates.
    ///
    /// This is the whole of the virtualisation: the renderer draws exactly this span and nothing
    /// else, so the cost of a frame is bounded by the size of the screen rather than the size of
    /// the workbook.
    func visibleRange(in rect: CGRect) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
        let firstColumn = column(atX: max(0, rect.minX))
        let lastColumn = max(firstColumn, column(atX: max(0, rect.maxX)))
        let firstRow = row(atY: max(0, rect.minY))
        let lastRow = max(firstRow, row(atY: max(0, rect.maxY)))
        return (firstColumn...lastColumn, firstRow...lastRow)
    }

    // MARK: - Private

    /// Binary search for the last offset at or before `position`, falling through to fixed-size
    /// arithmetic past the table.
    private func index(for position: Double, in offsets: [Double], extent: Int,
                       defaultSize: Double, limit: Int) -> Int {
        guard position > 0 else { return 1 }
        let end = offsets[extent]
        if position >= end {
            guard defaultSize > 0 else { return limit }
            let beyond = Int((position - end) / defaultSize)
            return min(extent + 1 + beyond, limit)
        }
        var low = 0
        var high = extent
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= position {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low + 1
    }
}
