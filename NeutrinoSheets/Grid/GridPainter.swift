import UIKit

// MARK: - GridPainter

/// Draws a block of cells — grid lines, fills, text and borders — onto the current context, in
/// content coordinates.
///
/// Shared by the on-screen canvas and by printing, so a printed sheet formats, aligns, overflows
/// and merges exactly as the grid does. The canvas adds the selection and the fill handle on top;
/// a printed page adds nothing.
///
/// Holds only values, and reaches nothing bound to the main actor, so a page can be drawn on
/// whichever thread the print system chooses.
struct GridPainter {

    typealias VisibleRange = (columns: ClosedRange<Int>, rows: ClosedRange<Int>)

    var model: GridRenderModel

    /// Base font size for a cell with no `fontSize` of its own, already zoom-scaled.
    var baseFontSize: CGFloat

    /// The width of a grid line — one device pixel on screen, a fine rule on paper.
    var hairline: CGFloat

    // MARK: - Appearance

    static let gridLineColor = UIColor.separator
    static let defaultTextColor = UIColor.label

    /// Inset from the cell edge to its text, matching the web app's cell padding.
    static let textInset: CGFloat = 4

    // MARK: - Grid lines

    func drawGridLines(visible: VisibleRange, in context: CGContext) {
        let geometry = model.geometry
        context.setLineWidth(hairline)
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

    func drawCells(visible: VisibleRange, clip: CGRect, in context: CGContext) {
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
                draw(cell: cell, at: address, clip: clip, in: context)
            }
        }

        var drawnAnchors = Set<String>()
        for (address, cell) in pendingMerges where drawnAnchors.insert(address.id).inserted {
            draw(cell: cell, at: address, clip: clip, in: context)
        }
    }

    private func draw(cell: SavedCell, at address: CellAddress, clip: CGRect,
                      in context: CGContext) {
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
                context.setLineWidth(hairline)
                context.stroke(frame)
            }
        }

        drawText(of: cell, in: frame, style: style, context: context)
        drawBorders(of: style, in: frame, context: context)
    }

    // MARK: - Text

    private func drawText(of cell: SavedCell, in frame: CGRect, style: CellStyle?,
                          context: CGContext) {
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
                box = overflowBox(from: box, needed: needed, cell: cell,
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
                             alignment: NSTextAlignment) -> CGRect {
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
}
