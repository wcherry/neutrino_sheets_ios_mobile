import UIKit

// MARK: - GridHeaderView

/// The frozen column-letter bar or row-number gutter.
///
/// Separate views rather than part of ``GridCanvasView`` because they freeze on one axis each: the
/// column header scrolls horizontally with the content but stays pinned vertically, and the row
/// header does the opposite. Drawing them in the canvas would mean undoing one axis of the
/// translation per header, which is the same work with the reasoning hidden inside a draw call.
final class GridHeaderView: UIView {

    // MARK: - Axis

    enum Axis {
        case columns
        case rows
    }

    // MARK: - Input

    let axis: Axis

    var geometry: GridGeometry? {
        didSet { setNeedsDisplay() }
    }

    /// The content-space offset along this header's scrolling axis.
    var contentOffset: CGFloat = 0 {
        didSet {
            guard contentOffset != oldValue else { return }
            setNeedsDisplay()
        }
    }

    /// The selection, so the rows and columns it spans can be emphasised — the cheapest way to keep
    /// the current address findable when the selection has scrolled out of view, and the only thing
    /// that says how wide a range reaches once its far edge is off screen.
    var selection: SheetSelection? {
        didSet { setNeedsDisplay() }
    }

    /// Whether this header's index falls inside the selection along its own axis.
    private func isSelected(_ index: Int) -> Bool {
        guard let range = selection?.range else { return false }
        return axis == .columns ? range.columns.contains(index) : range.rows.contains(index)
    }

    var labelFontSize: CGFloat = 11 {
        didSet { setNeedsDisplay() }
    }

    // MARK: - Init

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = .secondarySystemBackground
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let geometry, let context = UIGraphicsGetCurrentContext() else { return }
        backgroundColor?.setFill()
        context.fill(rect)

        context.setStrokeColor(UIColor.separator.cgColor)
        context.setLineWidth(1 / (window?.screen.scale ?? 2))

        let font = UIFont.systemFont(ofSize: labelFontSize, weight: .medium)
        let selectedFont = UIFont.systemFont(ofSize: labelFontSize, weight: .bold)

        switch axis {
        case .columns:
            let range = geometry.visibleRange(
                in: CGRect(x: contentOffset, y: 0, width: bounds.width, height: 1)
            ).columns
            for column in range {
                let x = geometry.x(ofColumn: column) - contentOffset
                let width = geometry.width(ofColumn: column)
                let cell = CGRect(x: x, y: 0, width: width, height: bounds.height)
                let isSelected = isSelected(column)
                draw(label: CellAddress.columnLetters(column), in: cell,
                     font: isSelected ? selectedFont : font, highlighted: isSelected, context: context)
                context.beginPath()
                context.move(to: CGPoint(x: cell.maxX, y: 0))
                context.addLine(to: CGPoint(x: cell.maxX, y: bounds.height))
                context.strokePath()
            }
            context.beginPath()
            context.move(to: CGPoint(x: 0, y: bounds.maxY))
            context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
            context.strokePath()

        case .rows:
            let range = geometry.visibleRange(
                in: CGRect(x: 0, y: contentOffset, width: 1, height: bounds.height)
            ).rows
            for row in range {
                let y = geometry.y(ofRow: row) - contentOffset
                let height = geometry.height(ofRow: row)
                let cell = CGRect(x: 0, y: y, width: bounds.width, height: height)
                let isSelected = isSelected(row)
                draw(label: String(row), in: cell,
                     font: isSelected ? selectedFont : font, highlighted: isSelected, context: context)
                context.beginPath()
                context.move(to: CGPoint(x: 0, y: cell.maxY))
                context.addLine(to: CGPoint(x: bounds.width, y: cell.maxY))
                context.strokePath()
            }
            context.beginPath()
            context.move(to: CGPoint(x: bounds.maxX, y: 0))
            context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
            context.strokePath()
        }
    }

    private func draw(label: String, in cell: CGRect, font: UIFont, highlighted: Bool,
                      context: CGContext) {
        guard cell.intersects(bounds) else { return }
        if highlighted {
            context.setFillColor(UIColor.tintColor.withAlphaComponent(0.18).cgColor)
            context.fill(cell)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        let attributed = NSAttributedString(string: label, attributes: [
            .font: font,
            .foregroundColor: highlighted ? UIColor.tintColor : UIColor.secondaryLabel,
            .paragraphStyle: paragraph,
        ])
        let size = attributed.size()
        attributed.draw(in: CGRect(x: cell.minX, y: cell.midY - size.height / 2,
                                   width: cell.width, height: size.height))
    }
}
