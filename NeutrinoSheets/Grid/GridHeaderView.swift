import UIKit

// MARK: - GridHeaderView

/// The frozen column-letter bar or row-number gutter.
///
/// Separate views rather than part of ``GridCanvasView`` because they freeze on one axis each: the
/// column header scrolls horizontally with the content but stays pinned vertically, and the row
/// header does the opposite. Drawing them in the canvas would mean undoing one axis of the
/// translation per header, which is the same work with the reasoning hidden inside a draw call.
///
/// Epic 10 turns them into controls as well as labels. A header is where a spreadsheet keeps its
/// structural commands, so this view owns three gestures — tap to select the whole row or column,
/// drag from the edge to resize it, and press to raise the menu — and reports them upwards. It does
/// not act on any of them: the grid does not own the workbook.
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

    /// Epic 10 — how many headers at the near end are frozen, and how much room they take.
    ///
    /// The frozen ones are drawn at their own positions and the rest are pushed past them, so the
    /// bar stays in step with the panes the canvas draws. See ``GridHostView``.
    var frozen: (count: Int, extent: CGFloat) = (0, 0) {
        didSet {
            guard frozen != oldValue else { return }
            setNeedsDisplay()
        }
    }

    /// The selection, so the rows and columns it spans can be emphasised — the cheapest way to keep
    /// the current address findable when the selection has scrolled out of view, and the only thing
    /// that says how wide a range reaches once its far edge is off screen.
    var selection: SheetSelection? {
        didSet { setNeedsDisplay() }
    }

    /// Epic 10 — the columns a filter is active on, marked so a user who has scrolled away from the
    /// dialog can still see why rows are missing.
    var filteredColumns: Set<Int> = [] {
        didSet {
            guard filteredColumns != oldValue else { return }
            setNeedsDisplay()
        }
    }

    var labelFontSize: CGFloat = 11 {
        didSet { setNeedsDisplay() }
    }

    // MARK: - Callbacks

    /// A tap: select this whole row or column.
    var onSelect: (Int) -> Void = { _ in }
    /// A drag across headers: extend the selection to this one.
    var onExtend: (Int) -> Void = { _ in }
    /// A press: raise the structural menu for this header, at a point in this view's coordinates.
    var onMenu: (Int, CGPoint) -> Void = { _, _ in }
    /// A resize drag in progress, reported live so the grid can show it.
    var onResizePreview: (Int, Double) -> Void = { _, _ in }
    /// The resize drag finished at this size. Only this one is an edit.
    var onResizeCommit: (Int, Double) -> Void = { _, _ in }

    /// Whether the resize and structural gestures are offered. A read-only share gets labels.
    var isEditable = false

    // MARK: - Gesture state

    private enum Drag {
        case selecting
        /// The 1-based header being resized and the size it started at.
        case resizing(index: Int, startSize: Double, origin: CGFloat)
    }

    private var drag: Drag?
    private var pressGesture: UILongPressGestureRecognizer?

    /// How close to a header's far edge a drag has to start to be a resize rather than a selection.
    /// Wider than the web app's 4px handle: this one is grabbed with a fingertip.
    private static let resizeGrabWidth: CGFloat = 16
    /// The smallest a drag can make a row or column. The web app's floors, so a column narrowed on
    /// a phone is one the browser can still grab.
    private static let minimumColumnWidth: Double = 20
    private static let minimumRowHeight: Double = 12

    // MARK: - Init

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = .secondarySystemBackground
        contentMode = .redraw
        installGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.4
        addGestureRecognizer(press)
        pressGesture = press
    }

    // MARK: - Geometry

    /// The 1-based header under a point in this view's coordinates.
    private func index(at point: CGPoint) -> Int? {
        guard let geometry else { return nil }
        let position = self.position(at: point)
        guard position >= 0 else { return nil }
        return axis == .columns ? geometry.column(atX: position) : geometry.row(atY: position)
    }

    /// A point in this view's coordinates as a content-space position along this header's axis.
    ///
    /// The frozen headers are the near end of the bar and do not move, so a point inside them is
    /// already a content position; past them, the scroll offset applies.
    private func position(at point: CGPoint) -> Double {
        let along = axis == .columns ? point.x : point.y
        return along < frozen.extent ? Double(along) : Double(along + contentOffset)
    }

    /// The screen position of a content-space coordinate — the inverse of ``position(at:)``.
    private func screenPosition(of contentPosition: Double) -> CGFloat {
        contentPosition < Double(frozen.extent)
            ? CGFloat(contentPosition)
            : CGFloat(contentPosition) - contentOffset
    }

    /// The size of one header, and where its far edge sits on screen.
    private func extent(of index: Int) -> (size: Double, farEdge: CGFloat)? {
        guard let geometry else { return nil }
        if axis == .columns {
            let size = geometry.width(ofColumn: index)
            return (size, screenPosition(of: geometry.x(ofColumn: index) + size))
        }
        let size = geometry.height(ofRow: index)
        return (size, screenPosition(of: geometry.y(ofRow: index) + size))
    }

    /// The header whose far edge is within grabbing distance of `point`, if any.
    ///
    /// The header *before* the one under the finger is offered as well, because the natural place to
    /// grab column C's edge is a couple of points into column D.
    private func resizeTarget(at point: CGPoint) -> (index: Int, size: Double, origin: CGFloat)? {
        guard isEditable, let index = index(at: point) else { return nil }
        let along = axis == .columns ? point.x : point.y
        for candidate in [index, index - 1] where candidate >= 1 {
            guard let extent = extent(of: candidate) else { continue }
            if abs(extent.farEdge - along) <= Self.resizeGrabWidth / 2 {
                return (candidate, extent.size, along)
            }
        }
        return nil
    }

    // MARK: - Gestures

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let index = index(at: recognizer.location(in: self)) else { return }
        onSelect(index)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)

        switch recognizer.state {
        case .began:
            // A drag has started, so the press that was counting down towards the menu is not one.
            // Toggling `isEnabled` is how UIKit is told to abandon a recognizer mid-gesture.
            pressGesture?.isEnabled = false
            pressGesture?.isEnabled = true

            if let target = resizeTarget(at: point) {
                drag = .resizing(index: target.index, startSize: target.size, origin: target.origin)
            } else {
                drag = .selecting
                if let index = index(at: point) { onSelect(index) }
            }

        case .changed:
            switch drag {
            case .selecting:
                if let index = index(at: point) { onExtend(index) }
            case .resizing(let index, let startSize, let origin):
                onResizePreview(index, size(from: startSize, origin: origin, point: point))
            case nil:
                break
            }

        case .ended:
            if case .resizing(let index, let startSize, let origin) = drag {
                onResizeCommit(index, size(from: startSize, origin: origin, point: point))
            }
            drag = nil

        case .cancelled, .failed:
            // A cancelled resize still has to be told to stop, or the preview stays on screen at
            // whatever size the finger left it.
            if case .resizing(let index, let startSize, _) = drag {
                onResizeCommit(index, startSize)
            }
            drag = nil

        default:
            break
        }
    }

    /// The size a resize drag has reached, floored so a column cannot be dragged to nothing.
    ///
    /// Zero *is* reachable — it is how a column is hidden — but only through the Hide command,
    /// never by a drag that slipped: a column dragged to nothing by accident is one the user then
    /// has no edge left to grab.
    private func size(from startSize: Double, origin: CGFloat, point: CGPoint) -> Double {
        let along = axis == .columns ? point.x : point.y
        let minimum = axis == .columns ? Self.minimumColumnWidth : Self.minimumRowHeight
        return max(minimum, startSize + Double(along - origin))
    }

    @objc private func handlePress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let point = recognizer.location(in: self)
        guard let index = index(at: point) else { return }
        // Selecting first means the menu's commands act on what the user just pressed, which is what
        // they would expect even though the previous selection may have been elsewhere.
        if selectionCovers(index) == false { onSelect(index) }
        onMenu(index, point)
    }

    /// Whether the current selection already spans this header, so pressing inside a multi-header
    /// selection keeps it rather than collapsing it to one.
    private func selectionCovers(_ index: Int) -> Bool {
        guard let range = selection?.range else { return false }
        return axis == .columns ? range.columns.contains(index) : range.rows.contains(index)
    }

    /// Whether this header's index falls inside the selection along its own axis.
    private func isSelected(_ index: Int) -> Bool {
        guard let range = selection?.range else { return false }
        return axis == .columns ? range.columns.contains(index) : range.rows.contains(index)
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let geometry, let context = UIGraphicsGetCurrentContext() else { return }
        backgroundColor?.setFill()
        context.fill(rect)

        context.setStrokeColor(UIColor.separator.cgColor)
        context.setLineWidth(1 / (window?.screen.scale ?? 2))

        let font = UIFont.systemFont(ofSize: labelFontSize, weight: .medium)
        let selectedFont = UIFont.systemFont(ofSize: labelFontSize, weight: .bold)

        // The frozen headers first, then the scrolling ones — drawn in that order so a scrolling
        // header cannot paint over the frozen band it is passing under.
        for index in indicesToDraw() {
            let cell = self.cell(for: index, geometry: geometry)
            guard cell.intersects(bounds) else { continue }
            let isSelected = isSelected(index)
            let label = axis == .columns ? CellAddress.columnLetters(index) : String(index)
            draw(label: label, in: cell, font: isSelected ? selectedFont : font,
                 highlighted: isSelected,
                 filtered: axis == .columns && filteredColumns.contains(index),
                 context: context)

            context.beginPath()
            if axis == .columns {
                context.move(to: CGPoint(x: cell.maxX, y: 0))
                context.addLine(to: CGPoint(x: cell.maxX, y: bounds.height))
            } else {
                context.move(to: CGPoint(x: 0, y: cell.maxY))
                context.addLine(to: CGPoint(x: bounds.width, y: cell.maxY))
            }
            context.strokePath()
        }

        context.beginPath()
        if axis == .columns {
            context.move(to: CGPoint(x: 0, y: bounds.maxY))
            context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        } else {
            context.move(to: CGPoint(x: bounds.maxX, y: 0))
            context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        }
        context.strokePath()
    }

    /// The headers on screen: the frozen ones, and the scrolling ones showing past them.
    private func indicesToDraw() -> [Int] {
        guard let geometry else { return [] }
        let length = axis == .columns ? bounds.width : bounds.height
        let start = Double(contentOffset + frozen.extent)
        let end = start + Double(max(0, length - frozen.extent))

        let scrolling: ClosedRange<Int>
        if axis == .columns {
            let first = geometry.column(atX: start)
            scrolling = first...max(first, geometry.column(atX: end))
        } else {
            let first = geometry.row(atY: start)
            scrolling = first...max(first, geometry.row(atY: end))
        }
        let frozenIndices = frozen.count >= 1 ? Array(1...frozen.count) : []
        return frozenIndices + scrolling.filter { $0 > frozen.count }
    }

    /// One header's rectangle in this view's coordinates.
    private func cell(for index: Int, geometry: GridGeometry) -> CGRect {
        if axis == .columns {
            let x = screenPosition(of: geometry.x(ofColumn: index))
            return CGRect(x: x, y: 0, width: geometry.width(ofColumn: index), height: bounds.height)
        }
        let y = screenPosition(of: geometry.y(ofRow: index))
        return CGRect(x: 0, y: y, width: bounds.width, height: geometry.height(ofRow: index))
    }

    private func draw(label: String, in cell: CGRect, font: UIFont, highlighted: Bool,
                      filtered: Bool, context: CGContext) {
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

        // A filter mark, drawn as a small triangle in the corner rather than as an icon: the header
        // is 26pt tall at 1× zoom and anything with detail in it is a smudge.
        guard filtered, cell.width > 14 else { return }
        context.setFillColor(UIColor.tintColor.cgColor)
        context.beginPath()
        context.move(to: CGPoint(x: cell.maxX - 9, y: cell.midY - 3))
        context.addLine(to: CGPoint(x: cell.maxX - 3, y: cell.midY - 3))
        context.addLine(to: CGPoint(x: cell.maxX - 6, y: cell.midY + 3))
        context.closePath()
        context.fillPath()
    }
}
