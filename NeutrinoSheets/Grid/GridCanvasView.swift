import UIKit

// MARK: - GridRenderModel

/// Everything the canvas needs to draw one frame. A value type, so the renderer never reaches back
/// into the editor's mutable state mid-draw.
struct GridRenderModel {
    var sheet: SheetData?
    var geometry: GridGeometry
    var selection: SheetSelection?
    var showGridLines: Bool = true
    /// The range the fill handle is currently being dragged over, drawn as a dashed preview until
    /// the finger lifts.
    var fillPreview: CellRange?
    /// Whether the fill handle is drawn at all — it is an editing affordance, and a read-only
    /// share must not offer one.
    var showsFillHandle: Bool = false
}

// MARK: - GridCanvasView

/// Draws the cells intersecting its own frame, and nothing else.
///
/// This view is deliberately **viewport-sized, not content-sized**. The obvious construction — one
/// view as large as the workbook, added to a scroll view — cannot work: UIKit allocates a backing
/// store for a view's whole bounds, and a 10,000-row sheet is a bitmap measured in gigabytes. So
/// the canvas stays the size of the visible rectangle and is *moved* to follow the scroll offset,
/// redrawing as it goes. `contentOrigin` is the translation between the two coordinate spaces.
///
/// This is the reason Epic 6 commits to UIKit. SwiftUI has no equivalent seam: its layout system
/// wants a view per cell, and 10,000 of those do not lay out in a frame.
final class GridCanvasView: UIView {

    // MARK: - Input

    /// The frame's data. Setting it redraws.
    var model: GridRenderModel? {
        didSet { setNeedsDisplay() }
    }

    /// The content-space point drawn at this view's top-left corner.
    var contentOrigin: CGPoint = .zero {
        didSet {
            guard contentOrigin != oldValue else { return }
            setNeedsDisplay()
        }
    }

    /// Base font size for a cell with no `fontSize` of its own, already zoom-scaled.
    var baseFontSize: CGFloat = 13

    // MARK: - Appearance

    private static let gridLineColor = UIColor.separator
    private static let selectionColor = UIColor.tintColor
    private static let defaultTextColor = UIColor.label

    /// Inset from the cell edge to its text, matching the web app's cell padding.
    private static let textInset: CGFloat = 4

    /// Diameter of the fill handle. Small on purpose — its *touch* target is much larger, and lives
    /// in ``GridHostView``.
    private static let fillHandleSize: CGFloat = 11

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .systemBackground
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let model, let context = UIGraphicsGetCurrentContext() else { return }

        backgroundColor?.setFill()
        context.fill(rect)

        // Everything below is in content coordinates; this is the only place the two spaces meet.
        context.saveGState()
        context.translateBy(x: -contentOrigin.x, y: -contentOrigin.y)
        let contentRect = rect.offsetBy(dx: contentOrigin.x, dy: contentOrigin.y)
        let visible = model.geometry.visibleRange(in: contentRect)

        if model.showGridLines {
            drawGridLines(model: model, visible: visible, in: context)
        }
        drawCells(model: model, visible: visible, clip: contentRect, in: context)
        drawSelection(model: model, in: context)
        drawFillPreview(model: model, in: context)

        context.restoreGState()
    }

    // MARK: - Grid lines

    private func drawGridLines(model: GridRenderModel,
                               visible: (columns: ClosedRange<Int>, rows: ClosedRange<Int>),
                               in context: CGContext) {
        let geometry = model.geometry
        // A hairline, so the lines stay one device pixel at any scale rather than thickening with
        // zoom the way a scaled 1pt line would.
        context.setLineWidth(1 / (window?.screen.scale ?? 2))
        context.setStrokeColor(Self.gridLineColor.cgColor)
        context.beginPath()

        let top = geometry.y(ofRow: visible.rows.lowerBound)
        let bottom = geometry.y(ofRow: visible.rows.upperBound + 1)
        for column in visible.columns.lowerBound...(visible.columns.upperBound + 1) {
            let x = geometry.x(ofColumn: column)
            context.move(to: CGPoint(x: x, y: top))
            context.addLine(to: CGPoint(x: x, y: bottom))
        }
        let left = geometry.x(ofColumn: visible.columns.lowerBound)
        let right = geometry.x(ofColumn: visible.columns.upperBound + 1)
        for row in visible.rows.lowerBound...(visible.rows.upperBound + 1) {
            let y = geometry.y(ofRow: row)
            context.move(to: CGPoint(x: left, y: y))
            context.addLine(to: CGPoint(x: right, y: y))
        }
        context.strokePath()
    }

    // MARK: - Cells

    private func drawCells(model: GridRenderModel,
                           visible: (columns: ClosedRange<Int>, rows: ClosedRange<Int>),
                           clip: CGRect, in context: CGContext) {
        guard let sheet = model.sheet else { return }

        // A merge anchor can sit above or left of the visible range while its merged area reaches
        // into it, so anchors are collected first and drawn after the plain cells — otherwise a
        // merged block would flicker in and out as its anchor scrolled off screen.
        var pendingMerges: [(CellAddress, SavedCell)] = []

        for row in visible.rows {
            for column in visible.columns {
                let address = CellAddress(column: column, row: row)
                guard let cell = sheet.cells[address.id] else { continue }
                if let anchorID = cell.mergeAnchor {
                    // Covered by another cell's merge: draw nothing, and let the anchor cover it.
                    if let anchorAddress = CellAddress(anchorID), let anchor = sheet.cells[anchorID],
                       !visible.columns.contains(anchorAddress.column)
                        || !visible.rows.contains(anchorAddress.row) {
                        pendingMerges.append((anchorAddress, anchor))
                    }
                    continue
                }
                if (cell.colSpan ?? 1) > 1 || (cell.rowSpan ?? 1) > 1 {
                    pendingMerges.append((address, cell))
                    continue
                }
                draw(cell: cell, at: address, model: model, clip: clip, in: context)
            }
        }

        var drawnAnchors = Set<String>()
        for (address, cell) in pendingMerges where drawnAnchors.insert(address.id).inserted {
            draw(cell: cell, at: address, model: model, clip: clip, in: context)
        }
    }

    private func draw(cell: SavedCell, at address: CellAddress, model: GridRenderModel,
                      clip: CGRect, in context: CGContext) {
        let frame = model.geometry.rect(for: address,
                                        colSpan: cell.colSpan ?? 1,
                                        rowSpan: cell.rowSpan ?? 1)
        guard frame.intersects(clip) else { return }
        let style = cell.cellStyle

        if let fill = GridStyleResolver.color(style?.backgroundColor) {
            context.setFillColor(fill.cgColor)
            context.fill(frame)
            // The fill covers the grid lines it overlaps, so a merged or shaded cell would lose its
            // outline entirely. Redrawn here at the same weight rather than reordering the passes,
            // which would put every fill behind every line and hide the borders instead.
            if model.showGridLines {
                context.setStrokeColor(Self.gridLineColor.cgColor)
                context.setLineWidth(1 / (window?.screen.scale ?? 2))
                context.stroke(frame)
            }
        }

        drawText(of: cell, in: frame, style: style, model: model, context: context)
        drawBorders(of: style, in: frame, context: context)
    }

    // MARK: - Text

    private func drawText(of cell: SavedCell, in frame: CGRect, style: CellStyle?,
                          model: GridRenderModel, context: CGContext) {
        let text = CellFormatter.display(cell.value ?? cell.raw, style: style)
        guard !text.isEmpty else { return }

        let font = GridStyleResolver.font(for: style, defaultSize: baseFontSize)
        let isNumeric = CellFormatter.parseNumber(text) != nil
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = GridStyleResolver.alignment(style, isNumeric: isNumeric)

        let wrapMode = GridStyleResolver.wrapMode(style)
        paragraph.lineBreakMode = wrapMode == .wrap ? .byWordWrapping : .byClipping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: GridStyleResolver.color(style?.color) ?? Self.defaultTextColor,
            .paragraphStyle: paragraph,
        ]
        if style?.isStrikethrough == true {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        let attributed = NSAttributedString(string: text, attributes: attributes)
        let inset = Self.textInset
        var box = frame.insetBy(dx: inset, dy: 2)
        guard box.width > 0, box.height > 0 else { return }

        // `overflow` lets long text spill past its own cell, which is what a spreadsheet does and
        // what makes a wide label in a narrow column readable. It is only allowed to spill into
        // *empty* neighbours: running text under a populated cell would produce two overlapping
        // strings and neither would be legible.
        if wrapMode == .overflow {
            let needed = attributed.boundingRect(
                with: CGSize(width: .greatestFiniteMagnitude, height: box.height),
                options: [.usesLineFragmentOrigin], context: nil
            ).width
            if needed > box.width {
                box = overflowBox(from: box, needed: needed, cell: cell, model: model,
                                  alignment: paragraph.alignment)
            }
        }

        let measured = attributed.boundingRect(
            with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], context: nil
        ).height
        switch GridStyleResolver.verticalAlignment(style) {
        case .top:    break
        case .middle: box.origin.y += max(0, (box.height - measured) / 2)
        case .bottom: box.origin.y += max(0, box.height - measured)
        }

        context.saveGState()
        // Clipped even in overflow mode: the box has already been widened to whatever the text is
        // allowed to occupy, and text must never escape *that*.
        context.clip(to: box.insetBy(dx: -inset, dy: 0))
        attributed.draw(with: box, options: [.usesLineFragmentOrigin], context: nil)
        context.restoreGState()
    }

    /// Widens `box` into the empty cells beside it, in whichever direction the text is aligned.
    private func overflowBox(from box: CGRect, needed: CGFloat, cell: SavedCell,
                             model: GridRenderModel, alignment: NSTextAlignment) -> CGRect {
        guard let sheet = model.sheet, let address = CellAddress(cell.id) else { return box }

        func isEmpty(column: Int) -> Bool {
            guard column >= 1, column <= model.geometry.extent.columns else { return true }
            let neighbour = CellAddress(column: column, row: address.row)
            guard let occupant = sheet.cells[neighbour.id] else { return true }
            return occupant.isEmpty
        }

        var box = box
        // Right-aligned text grows leftwards, everything else rightwards — the direction the text
        // is running away from its anchor.
        if alignment == .right {
            var column = address.column - 1
            while box.width < needed, isEmpty(column: column), column >= 1 {
                let extra = model.geometry.width(ofColumn: column)
                box.origin.x -= extra
                box.size.width += extra
                column -= 1
            }
        } else {
            var column = address.column + max(1, cell.colSpan ?? 1)
            while box.width < needed, isEmpty(column: column) {
                box.size.width += model.geometry.width(ofColumn: column)
                column += 1
            }
        }
        return box
    }

    // MARK: - Borders

    private func drawBorders(of style: CellStyle?, in frame: CGRect, context: CGContext) {
        guard let style else { return }
        let color = GridStyleResolver.color(style.color) ?? UIColor.label
        for side in CellStyle.BorderSide.allCases {
            guard let width = GridStyleResolver.borderWidth(style.border(side)) else { continue }
            let line: (CGPoint, CGPoint)
            switch side {
            case .top:    line = (CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY))
            case .right:  line = (CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.maxY))
            case .bottom: line = (CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY))
            case .left:   line = (CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.minX, y: frame.maxY))
            }
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.beginPath()
            context.move(to: line.0)
            context.addLine(to: line.1)
            context.strokePath()
        }
    }

    // MARK: - Selection

    /// Draws the selected block: a wash over the range, the outline around it, a clear active cell,
    /// and the fill handle at the bottom-right corner.
    ///
    /// The active cell is left unwashed so a range still says *where typing would go* — without it
    /// a 30-cell selection is a rectangle with no reference point, and the formula bar's contents
    /// belong to a cell the user cannot pick out.
    private func drawSelection(model: GridRenderModel, in context: CGContext) {
        guard let selection = model.selection else { return }
        let range = selection.range
        let frame = self.frame(for: range, model: model)

        if !selection.isSingleCell {
            context.setFillColor(Self.selectionColor.withAlphaComponent(0.12).cgColor)
            context.fill(frame)
            let active = self.frame(for: CellRange(selection.active, selection.active), model: model)
            context.setFillColor(backgroundColor?.cgColor ?? UIColor.systemBackground.cgColor)
            context.fill(active)
            redrawCells(covering: active, model: model, clip: active, in: context)
        }

        context.setStrokeColor(Self.selectionColor.cgColor)
        context.setLineWidth(2)
        context.stroke(frame.insetBy(dx: 1, dy: 1))

        guard model.showsFillHandle else { return }
        let handle = CGRect(x: frame.maxX - Self.fillHandleSize / 2,
                            y: frame.maxY - Self.fillHandleSize / 2,
                            width: Self.fillHandleSize, height: Self.fillHandleSize)
        context.setFillColor(Self.selectionColor.cgColor)
        context.fillEllipse(in: handle)
        context.setStrokeColor((backgroundColor ?? .systemBackground).cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: handle)
    }

    /// The dashed outline of a fill in progress. Drawn over everything, because the point of it is
    /// to say how far the fill will reach before the finger lifts.
    private func drawFillPreview(model: GridRenderModel, in context: CGContext) {
        guard let preview = model.fillPreview else { return }
        let frame = self.frame(for: preview, model: model)
        context.saveGState()
        context.setStrokeColor(Self.selectionColor.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [5, 3])
        context.stroke(frame.insetBy(dx: 1, dy: 1))
        context.restoreGState()
    }

    /// The rectangle a range occupies, widened to cover any merge that reaches out of it — a
    /// selection that stopped halfway across a merged block would highlight cells that draw
    /// nothing.
    private func frame(for range: CellRange, model: GridRenderModel) -> CGRect {
        model.geometry.rect(for: range, cells: model.sheet?.cells)
    }

    /// Repaints the cells under a rectangle that was just filled over — the active cell's cutout in
    /// a range selection. Cheaper and simpler than drawing the wash as a nine-patch around it.
    private func redrawCells(covering rect: CGRect, model: GridRenderModel, clip: CGRect,
                             in context: CGContext) {
        let visible = model.geometry.visibleRange(in: rect)
        drawCells(model: model, visible: visible, clip: clip, in: context)
    }
}
