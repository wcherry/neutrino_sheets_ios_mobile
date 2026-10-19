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

    private static let selectionColor = UIColor.tintColor

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

        let painter = painter(for: model)
        if model.showGridLines {
            painter.drawGridLines(visible: visible, in: context)
        }
        painter.drawCells(visible: visible, clip: contentRect, in: context)
        drawSelection(model: model, in: context)
        drawFillPreview(model: model, in: context)

        context.restoreGState()
    }

    // MARK: - Cells

    /// Grid lines, fills, text and borders — the same drawing a printed page uses.
    private func painter(for model: GridRenderModel) -> GridPainter {
        // A hairline, so the lines stay one device pixel at any scale rather than thickening with
        // zoom the way a scaled 1pt line would.
        GridPainter(model: model, baseFontSize: baseFontSize,
                    hairline: 1 / (window?.screen.scale ?? 2))
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
        painter(for: model).drawCells(visible: visible, clip: clip, in: context)
    }
}
